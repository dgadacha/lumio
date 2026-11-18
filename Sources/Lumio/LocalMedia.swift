import SwiftUI
import CryptoKit

// Films et séries présents sur le disque : scan, préparation à la lecture, vignettes, positions.
// Lumio ne fait que LIRE ces fichiers : il ne les déplace, ne les renomme et ne les supprime jamais.

// MARK: - Outils

enum LocalTools {
    static func tool(_ name: String) -> URL? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
            .first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static let caches: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Empreinte stable d'un fichier : change s'il est remplacé (taille ou date différente).
    static func fingerprint(_ path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(path)|\(size)|\(Int(date))".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Analyse d'un fichier (ffprobe)

struct MediaTrack: Hashable {
    let index: Int
    let codec: String
    let language: String?
    let title: String?
}

struct MediaProbe {
    var duration: Double = 0
    var videoCodec: String?
    var audio: [MediaTrack] = []
    var subtitles: [MediaTrack] = []
    /// Flux « image attachée » : une affiche fournie avec le fichier.
    var coverIndex: Int?

    static let textSubtitleCodecs: Set<String> = ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"]
    /// Codecs audio que le lecteur système lit tels quels dans un MP4.
    static let passthroughAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]
}

actor MediaInspector {
    static let shared = MediaInspector()
    private var cache: [String: MediaProbe] = [:]

    func probe(_ path: String) async -> MediaProbe? {
        let key = LocalTools.fingerprint(path)
        if let hit = cache[key] { return hit }
        guard let ffprobe = LocalTools.tool("ffprobe"),
              let result = try? await ProcessRunner.run(ffprobe, [
                  "-v", "error", "-show_entries",
                  "format=duration:stream=index,codec_type,codec_name:stream_tags=language,title:stream_disposition=attached_pic",
                  "-of", "json", path,
              ], env: Engine.environment),
              let root = try? JSONSerialization.jsonObject(with: result.out) as? [String: Any] else { return nil }
        var probe = MediaProbe()
        probe.duration = Double(((root["format"] as? [String: Any])?["duration"] as? String) ?? "") ?? 0
        for stream in (root["streams"] as? [[String: Any]]) ?? [] {
            guard let index = (stream["index"] as? NSNumber)?.intValue, let codec = stream["codec_name"] as? String else { continue }
            let tags = stream["tags"] as? [String: Any]
            let track = MediaTrack(index: index, codec: codec, language: tags?["language"] as? String, title: tags?["title"] as? String)
            let attached = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.intValue == 1
            switch stream["codec_type"] as? String {
            case "video" where attached: probe.coverIndex = index
            case "video" where probe.videoCodec == nil: probe.videoCodec = codec
            case "audio": probe.audio.append(track)
            case "subtitle": probe.subtitles.append(track)
            default: break
            }
        }
        cache[key] = probe
        return probe
    }
}

// MARK: - Préparation à la lecture

enum LocalMediaError: LocalizedError {
    case missingTools
    case missingFile
    case noSpace(needed: Int64)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTools: return "ffmpeg est introuvable. Installez-le avec Homebrew : brew install ffmpeg"
        case .missingFile: return "Le fichier n'existe plus à cet emplacement. Relancez l'analyse des dossiers."
        case .noSpace(let needed): return "Espace disque insuffisant pour préparer la lecture (\(Fmt.bytes(needed)) nécessaires)."
        case .conversionFailed(let message): return "Préparation impossible : \(message)"
        }
    }
}

struct PreparedMedia {
    let playURL: URL
    let duration: Double
    let subtitles: [PlayerSubtitle]
}

/// Rend un fichier lisible par le lecteur système. Les MP4 et MOV sont lus tels quels ; les autres
/// conteneurs (MKV surtout) sont recopiés dans un MP4 temporaire, sans réencoder la vidéo.
enum MediaPreparer {
    private static let remuxDir: URL = {
        let url = LocalTools.caches.appendingPathComponent("remux", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static let directExtensions: Set<String> = ["mp4", "m4v", "mov"]
    /// Nombre de fichiers convertis conservés : chacun pèse autant que l'original.
    private static let keptConversions = 2

    static func prepare(_ path: String, register: @escaping @Sendable (Process) -> Void) async throws -> PreparedMedia {
        guard FileManager.default.fileExists(atPath: path) else { throw LocalMediaError.missingFile }
        guard let ffmpeg = LocalTools.tool("ffmpeg") else { throw LocalMediaError.missingTools }
        let probe = await MediaInspector.shared.probe(path) ?? MediaProbe()
        let key = LocalTools.fingerprint(path)
        let source = URL(fileURLWithPath: path)

        var playURL = source
        if !directExtensions.contains(source.pathExtension.lowercased()) {
            // Le suffixe change quand la recette de conversion change : les anciens fichiers ne sont pas réutilisés.
            let target = remuxDir.appendingPathComponent("\(key)-v2.mp4")
            if !FileManager.default.fileExists(atPath: target.path) {
                let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
                let free = (try? remuxDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? Int64.max
                guard free > size + (1 << 30) else { throw LocalMediaError.noSpace(needed: size + (1 << 30)) }

                let partial = remuxDir.appendingPathComponent("\(key)-v2.partial.mp4")
                var args = ["-v", "error", "-y", "-i", path, "-map", "0:v:0", "-map", "0:a?", "-c:v", "copy"]
                // Le lecteur système n'accepte le HEVC en MP4 que sous l'étiquette hvc1. Le filtre reconstruit
                // l'en-tête du flux : certains MKV n'y mettent pas les paramètres de décodage, et le MP4 obtenu
                // serait alors refusé par le décodage matériel (erreur -8971) alors qu'il paraît valide.
                if probe.videoCodec == "hevc" { args += ["-bsf:v", "hevc_mp4toannexb", "-tag:v", "hvc1"] }
                // L'audio est recopié quand le lecteur sait le lire, sinon converti en AAC (rapide).
                let copyAudio = probe.audio.allSatisfy { MediaProbe.passthroughAudio.contains($0.codec) }
                args += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "256k"]
                args += ["-sn", "-dn", "-map_metadata", "0", "-f", "mp4", partial.path]
                let result = try await ProcessRunner.run(ffmpeg, args, env: Engine.environment, register: register)
                try Task.checkCancellation()
                guard result.status == 0 else {
                    try? FileManager.default.removeItem(at: partial)
                    throw LocalMediaError.conversionFailed(result.err.split(separator: "\n").last.map(String.init) ?? "erreur ffmpeg")
                }
                try? FileManager.default.moveItem(at: partial, to: target)
            } else {
                // Marque le fichier comme récemment utilisé, pour la purge.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            }
            playURL = target
            purge(keeping: target)
        }

        return PreparedMedia(playURL: playURL, duration: probe.duration,
                             subtitles: await subtitles(for: path, key: key, probe: probe, ffmpeg: ffmpeg))
    }

    /// Extrait les pistes de sous-titres texte en WebVTT. Les pistes image (PGS, VobSub) sont ignorées.
    private static func subtitles(for path: String, key: String, probe: MediaProbe, ffmpeg: URL) async -> [PlayerSubtitle] {
        let dir = LocalTools.caches.appendingPathComponent("subs/\(key)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var found: [PlayerSubtitle] = []
        for track in probe.subtitles where MediaProbe.textSubtitleCodecs.contains(track.codec) {
            let file = dir.appendingPathComponent("\(track.index).vtt")
            if !FileManager.default.fileExists(atPath: file.path) {
                let result = try? await ProcessRunner.run(
                    ffmpeg, ["-v", "error", "-y", "-i", path, "-map", "0:\(track.index)", "-f", "webvtt", file.path],
                    env: Engine.environment)
                guard result?.status == 0 else { continue }
            }
            // Plusieurs pistes partagent souvent la même langue : le titre de la piste les distingue.
            let language = track.language.map(Fmt.language) ?? "Piste \(found.count + 1)"
            let label = track.title.map { "\(language) — \($0)" } ?? language
            found.append(PlayerSubtitle(code: "\(track.language ?? "und")-\(track.index)", label: label, url: file))
        }
        return found
    }

    /// Supprime les conversions anciennes ; ne touche qu'au dossier de cache de Lumio.
    static func purge(keeping current: URL? = nil) {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: remuxDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "mp4" }
        // Une conversion interrompue laisse un fichier partiel inutilisable.
        for file in files where file.lastPathComponent.hasSuffix(".partial.mp4") { try? FileManager.default.removeItem(at: file) }
        // Conversions faites avec une ancienne recette : inutilisables.
        for file in files where !file.lastPathComponent.contains("-v2") { try? FileManager.default.removeItem(at: file) }
        let complete = files.filter { $0.lastPathComponent.hasSuffix("-v2.mp4") }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
        for file in complete.dropFirst(keptConversions) where file != current { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Vignettes et affiches

actor LocalArtwork {
    static let shared = LocalArtwork()
    private let dir: URL = {
        let url = LocalTools.caches.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Vignette d'un fichier : l'affiche fournie avec lui si `preferCover`, sinon une image extraite du film.
    func image(for path: String, preferCover: Bool = false) async -> URL? {
        let key = LocalTools.fingerprint(path) + (preferCover ? "-cover" : "")
        let file = dir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let ffmpeg = LocalTools.tool("ffmpeg") else { return nil }

        // Deux extractions à la fois au plus : une grille de vignettes ne doit pas saturer la machine.
        if running >= 2 { await withCheckedContinuation { waiters.append($0) } }
        running += 1
        defer {
            running -= 1
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        if FileManager.default.fileExists(atPath: file.path) { return file }

        let probe = await MediaInspector.shared.probe(path)
        var args: [String]
        if preferCover, let cover = probe?.coverIndex {
            args = ["-v", "error", "-y", "-i", path, "-map", "0:\(cover)", "-frames:v", "1", "-vf", "scale=600:-2"]
        } else {
            // Vers le tiers du film : après le générique, avant la fin.
            let duration = probe?.duration ?? 0
            let moment = duration > 60 ? duration * 0.32 : 20
            args = ["-v", "error", "-y", "-ss", String(format: "%.0f", moment), "-i", path,
                    "-map", "0:v:0", "-frames:v", "1", "-vf", "scale=640:-2"]
        }
        args += ["-q:v", "3", file.path]
        let result = try? await ProcessRunner.run(ffmpeg, args, env: Engine.environment)
        return result?.status == 0 && FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}

/// Vignette d'un fichier local, chargée à la demande.
struct LocalThumb: View {
    let path: String
    var preferCover = false
    @State private var url: URL?

    var body: some View {
        Theme.surface2
            .overlay {
                if let url {
                    RemoteImage(urls: [url])
                } else {
                    Image(systemName: "film").font(.system(size: 26)).foregroundStyle(Theme.faint)
                }
            }
            .clipped()
            .task(id: path) { url = await LocalArtwork.shared.image(for: path, preferCover: preferCover) }
    }
}

// MARK: - Bibliothèque locale

struct LocalPosition: Codable, Hashable {
    var position: Double
    var duration: Double
    var date: Date

    var progress: Double? {
        guard duration > 0, position > 5 else { return nil }
        return min(1, position / duration)
    }
    /// Vu jusqu'au bout (générique de fin compris ou presque).
    var finished: Bool { duration > 0 && position >= duration * 0.94 }
}

@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var catalog = LocalCatalog()
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date?
    /// Dossiers auxquels macOS a refusé l'accès lors de la dernière analyse.
    @Published private(set) var denied: [String] = []
    @Published private(set) var positions: [String: LocalPosition] = [:]
    @Published var folders: [String] {
        didSet { UserDefaults.standard.set(folders, forKey: "scanFolders") }
    }

    /// Fiches rédigées par Claude, par identifiant d'œuvre. Conservées sur disque : un titre n'est demandé qu'une fois.
    @Published private(set) var info: [String: MediaInfo] = [:]
    @Published private(set) var describing = false
    @Published var describeError: String?
    @Published var describeEnabled = UserDefaults.standard.object(forKey: "localDescriptions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(describeEnabled, forKey: "localDescriptions")
            if describeEnabled { Task { await fetchMissingInfo() } }
        }
    }
    private let infoFile = Paths.support.appendingPathComponent("local-metadata.json")
    /// Après un échec, plus d'appel automatique : chaque tentative est facturée. Un clic sur « Réessayer »
    /// ou une relance de l'app lève la suspension.
    private var describeSuspended = false

    private let catalogFile = Paths.support.appendingPathComponent("local-media.json")
    private let positionsFile = Paths.support.appendingPathComponent("local-positions.json")

    private struct Stored: Codable {
        let date: Date
        let catalog: LocalCatalog
    }

    static var defaultFolders: [String] {
        [FileManager.SearchPathDirectory.downloadsDirectory, .moviesDirectory]
            .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first?.path }
    }

    init() {
        folders = UserDefaults.standard.stringArray(forKey: "scanFolders") ?? Self.defaultFolders
        if let data = try? Data(contentsOf: catalogFile), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            catalog = stored.catalog
            lastScan = stored.date
        }
        if let data = try? Data(contentsOf: infoFile), let stored = try? JSONDecoder().decode([String: MediaInfo].self, from: data) {
            info = stored
        }
        if let data = try? Data(contentsOf: positionsFile),
           let stored = try? JSONDecoder().decode([String: LocalPosition].self, from: data) {
            positions = stored
        }
        MediaPreparer.purge()
    }

    // MARK: Analyse des dossiers

    func scan() async {
        guard !scanning else { return }
        scanning = true
        let roots = folders
        let skipped = Paths.downloads.standardizedFileURL.path
        let outcome = await Task.detached(priority: .utility) { Self.collect(roots: roots, skipping: skipped) }.value
        catalog = MediaParser.catalog(files: outcome.files)
        denied = outcome.denied
        lastScan = Date()
        scanning = false
        if let data = try? JSONEncoder().encode(Stored(date: Date(), catalog: catalog)) {
            try? data.write(to: catalogFile, options: .atomic)
        }
        // Sous le pilote de test, pas d'appel automatique : il serait facturé sur la clé de l'utilisateur.
        if ProcessInfo.processInfo.environment["LUMIO_DEBUG"] == nil { await fetchMissingInfo() }
    }

    // MARK: Fiches rédigées par Claude

    static func infoKey(_ movie: LocalMovie) -> String {
        "film-\(MediaParser.normalize(movie.title))-\(movie.year.map(String.init) ?? "x")"
    }

    func info(for series: LocalSeries) -> MediaInfo? { info[series.id] }
    func info(for movie: LocalMovie) -> MediaInfo? { info[Self.infoKey(movie)] }

    /// Demande à Claude les fiches manquantes, en un seul appel par lot de vingt titres.
    /// Seuls le titre, l'année et le type (film ou série) sont envoyés ; jamais les chemins ni les noms de fichiers.
    /// Une fiche obtenue, même vide (œuvre non reconnue), n'est plus redemandée, sauf via `refresh`.
    func fetchMissingInfo(refresh ids: Set<String> = []) async {
        guard describeEnabled, !describing, APIKeyStore.hasKey else { return }
        if ids.isEmpty, describeSuspended { return }
        describeSuspended = false
        var requests: [MediaInfoRequest] = catalog.series.map {
            MediaInfoRequest(id: $0.id, title: $0.title, year: $0.year, isSeries: true)
        }
        requests += catalog.movies.map {
            MediaInfoRequest(id: Self.infoKey($0), title: $0.title, year: $0.year, isSeries: false)
        }
        var seen = Set<String>()
        requests = requests.filter { seen.insert($0.id).inserted && (info[$0.id] == nil || ids.contains($0.id)) }
        guard !requests.isEmpty else { return }

        describing = true
        describeError = nil
        defer { describing = false }
        for start in stride(from: 0, to: requests.count, by: 20) {
            let batch = Array(requests[start..<min(start + 20, requests.count)])
            do {
                let fetched = try await ClaudeClient.describe(batch)
                for request in batch {
                    // Un titre absent de la réponse est noté « non reconnu », pour ne pas le redemander à chaque analyse.
                    info[request.id] = fetched[request.id]
                        ?? MediaInfo(known: false, synopsis: "", genres: [], originalTitle: nil, year: nil, fetchedAt: Date())
                }
                // Sous le pilote de test, les fiches restent en mémoire, sauf essai d'écriture explicite.
                let env = ProcessInfo.processInfo.environment
                if env["LUMIO_DEBUG"] == nil || env["LUMIO_DEBUG_WRITE"] == "1",
                   let data = try? JSONEncoder().encode(info) { try? data.write(to: infoFile, options: .atomic) }
            } catch {
                describeError = error.localizedDescription
                describeSuspended = true
                return
            }
        }
    }

    func clearInfo() {
        info = [:]
        try? FileManager.default.removeItem(at: infoFile)
    }

    /// Parcourt les dossiers en lecture seule. Ignore les paquets (.app…), les fichiers cachés,
    /// les téléchargements incomplets et le dossier où Lumio range ses propres téléchargements.
    nonisolated private static func collect(roots: [String], skipping: String) -> (files: [(path: String, size: Int64)], denied: [String]) {
        var files: [(String, Int64)] = []
        var denied: [String] = []
        let incomplete: Set<String> = ["part", "crdownload", "download", "!qb", "aria2", "tmp"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isPackageKey]
        for root in roots {
            let url = URL(fileURLWithPath: root, isDirectory: true)
            // Un refus d'accès de macOS se manifeste par une erreur à la lecture du dossier.
            do { _ = try FileManager.default.contentsOfDirectory(atPath: root) } catch {
                if FileManager.default.fileExists(atPath: root) { denied.append(root) }
                continue
            }
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let item as URL in walker {
                if item.standardizedFileURL.path == skipping { walker.skipDescendants(); continue }
                let ext = item.pathExtension.lowercased()
                guard MediaParser.videoExtensions.contains(ext), !incomplete.contains(ext),
                      let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append((item.path, Int64(values.fileSize ?? 0)))
            }
        }
        return (files, denied)
    }

    // MARK: Positions de lecture

    func position(for path: String) -> LocalPosition? { positions[path] }

    func record(path: String, position: Double, duration: Double) {
        // Une valeur non finie ne s'encode pas en JSON et rendrait tout le fichier illisible.
        guard position.isFinite, duration.isFinite, position >= 0 else { return }
        positions[path] = LocalPosition(position: position, duration: duration, date: Date())
        // Sous le pilote de test, la position reste en mémoire : rien n'est écrit dans les données réelles.
        let env = ProcessInfo.processInfo.environment
        guard env["LUMIO_DEBUG"] == nil || env["LUMIO_DEBUG_WRITE"] == "1" else { return }
        if let data = try? JSONEncoder().encode(positions) { try? data.write(to: positionsFile, options: .atomic) }
    }

    /// Épisode à proposer pour une série : celui en cours, sinon le premier non vu.
    func nextUp(in series: LocalSeries) -> LocalEpisode? {
        let ordered = series.episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
        let seen = ordered.filter { positions[$0.path] != nil }
        guard let latest = seen.max(by: { (positions[$0.path]?.date ?? .distantPast) < (positions[$1.path]?.date ?? .distantPast) }) else {
            return ordered.first
        }
        if positions[latest.path]?.finished == true, let index = ordered.firstIndex(of: latest), index + 1 < ordered.count {
            return ordered[index + 1]
        }
        return latest
    }

    func episode(after path: String) -> (series: LocalSeries, episode: LocalEpisode)? {
        for series in catalog.series {
            let ordered = series.episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            if let index = ordered.firstIndex(where: { $0.path == path }), index + 1 < ordered.count {
                return (series, ordered[index + 1])
            }
        }
        return nil
    }

    /// Séries et films commencés, du plus récent au plus ancien.
    var inProgress: [(title: String, detail: String, path: String, position: LocalPosition)] {
        var rows: [(String, String, String, LocalPosition)] = []
        for series in catalog.series {
            guard let episode = nextUp(in: series), let latest = series.episodes
                .compactMap({ positions[$0.path] }).max(by: { $0.date < $1.date }) else { continue }
            let shown = positions[episode.path] ?? LocalPosition(position: 0, duration: 0, date: latest.date)
            rows.append((series.title, "S\(episode.season) : É\(episode.number)", episode.path,
                         LocalPosition(position: shown.position, duration: shown.duration, date: latest.date)))
        }
        for movie in catalog.movies {
            if let position = positions[movie.path], !position.finished { rows.append((movie.title, "Film", movie.path, position)) }
        }
        return rows.sorted { $0.3.date > $1.3.date }.map { (title: $0.0, detail: $0.1, path: $0.2, position: $0.3) }
    }
}
