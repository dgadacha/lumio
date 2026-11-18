import SwiftUI
import AVFoundation

// MARK: - Bibliothèque hors ligne

@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    private let file = Paths.support.appendingPathComponent("library.json")

    init() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        // Un fichier supprimé à la main dans le Finder disparaît de la bibliothèque.
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.mediaURL.path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func add(_ item: LibraryItem) {
        items.insert(item, at: 0)
        save()
    }

    func item(forVideo id: String) -> LibraryItem? {
        items.first { $0.videoID == id }
    }

    func updatePosition(_ id: UUID, position: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let duration = items[index].duration ?? 0
        items[index].position = duration > 0 && position > duration * 0.96 ? 0 : position
        items[index].lastPlayedAt = Date()
        save()
    }

    /// Met le dossier à la corbeille (récupérable) et retire l'entrée.
    func remove(_ item: LibraryItem) {
        try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        items.removeAll { $0.id == item.id }
        save()
    }

    var continueWatching: [LibraryItem] {
        items.filter { $0.progress != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

// MARK: - Historique de lecture en streaming

struct HistoryEntry: Codable, Identifiable, Hashable {
    var video: VideoSummary
    var position: Double
    var date: Date
    var id: String { video.id }

    var progress: Double? {
        guard let duration = video.duration, duration > 0, position > 5 else { return nil }
        return min(1, position / duration)
    }
}

/// Ce qui a été regardé sans téléchargement : sert à reprendre la lecture. Reste sur ce Mac.
@MainActor
final class WatchHistory: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let file = Paths.support.appendingPathComponent("history.json")

    init() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }

    func entry(for videoID: String) -> HistoryEntry? {
        entries.first { $0.video.id == videoID }
    }

    func record(_ video: VideoSummary, position: Double, duration: Double) {
        var video = video
        if video.duration == nil, duration > 0 { video.duration = duration }
        let total = video.duration ?? 0
        // Une vidéo vue jusqu'au bout repart du début la fois suivante.
        let kept = total > 0 && position > total * 0.96 ? 0 : position
        entries.removeAll { $0.video.id == video.id }
        entries.insert(HistoryEntry(video: video, position: kept, date: Date()), at: 0)
        entries = Array(entries.prefix(100))
        save()
    }

    func clear() {
        entries = []
        save()
    }
}

// MARK: - Téléchargements

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum State: Equatable { case queued, running, finishing, done, failed(String), cancelled }

    let id = UUID()
    let video: VideoSummary
    let summaryText: String
    let options: DownloadOptions
    let expectedBytes: Int64?
    let folder: URL

    @Published var state: State = .queued
    @Published var fraction: Double = 0
    @Published var speed: Double?
    @Published var eta: Double?
    @Published var stage = "En attente"

    fileprivate var process: Process?
    fileprivate var completedBytes: Double = 0
    fileprivate var lastDownloaded: Double = 0
    fileprivate var lastTotal: Double = 0
    fileprivate var mediaPath: String?
    fileprivate var warnings: [String] = []

    init(video: VideoSummary, summaryText: String, options: DownloadOptions, expectedBytes: Int64?) {
        self.video = video
        self.summaryText = summaryText
        self.options = options
        self.expectedBytes = expectedBytes
        folder = Paths.downloads.appendingPathComponent("\(video.id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    }

    var isActive: Bool { state == .queued || state == .running || state == .finishing }

    fileprivate func handle(line: String) {
        if line.hasPrefix("PROG|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { Double($0) }
            guard parts.count >= 6, let downloaded = parts[1] else { return }
            let total = parts[2] ?? parts[3] ?? 0
            // Vidéo puis audio sont deux fichiers successifs : le compteur repart de zéro.
            if downloaded < lastDownloaded || (total != lastTotal && lastTotal > 0 && downloaded < lastTotal * 0.5) {
                completedBytes += lastTotal
            }
            lastDownloaded = downloaded
            lastTotal = total
            let done = completedBytes + downloaded
            let whole = max(Double(expectedBytes ?? 0), completedBytes + total, 1)
            fraction = min(0.99, done / whole)
            speed = parts[4]
            eta = parts[5]
            stage = "Téléchargement"
        } else if line.hasPrefix("PP|") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count >= 3, parts[2] == "started" else { return }
            let names: [String: String] = [
                "Merger": "Assemblage vidéo et audio",
                "ExtractAudio": "Extraction audio",
                "EmbedSubtitle": "Intégration des sous-titres",
                "EmbedThumbnail": "Intégration de la miniature",
                "Metadata": "Écriture des métadonnées",
                "SponsorBlock": "Analyse des segments sponsorisés",
                "ModifyChapters": "Retrait des segments sponsorisés",
                "SubtitlesConvertor": "Conversion des sous-titres",
            ]
            if let name = names[parts[1]] {
                stage = name
                if parts[1] != "SubtitlesConvertor" { state = .finishing; speed = nil; eta = nil }
            }
        } else if line.hasPrefix("FILE|") {
            mediaPath = String(line.dropFirst(5))
        } else if line.hasPrefix("WARNING:"), line.contains("subtitle") {
            warnings.append(line)
        }
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    private let library: Library
    private let maxConcurrent = 2
    /// Vrai pendant une mise à jour du moteur : aucun téléchargement ne démarre.
    var engineBusy = false

    /// Relance la file, par exemple après une mise à jour du moteur.
    func resume() { pump() }

    init(library: Library) { self.library = library }

    var activeCount: Int { jobs.filter(\.isActive).count }

    func job(forVideo id: String) -> DownloadJob? {
        jobs.first { $0.video.id == id && $0.isActive }
    }

    func enqueue(video: VideoSummary, detail: VideoDetail, options: DownloadOptions) {
        let job = DownloadJob(
            video: detail.summary,
            summaryText: detail.description,
            options: options,
            expectedBytes: detail.estimatedSize(options)
        )
        jobs.insert(job, at: 0)
        pump()
    }

    func cancel(_ job: DownloadJob) {
        guard job.isActive else { return }
        job.state = .cancelled
        job.stage = "Annulé"
        // Le dossier est supprimé par run() une fois le processus réellement arrêté.
        job.process?.terminate()
        pump()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    private func pump() {
        let running = jobs.filter { $0.state == .running || $0.state == .finishing }.count
        if engineBusy {
            for job in jobs where job.state == .queued { job.stage = "En attente de la mise à jour du moteur" }
            objectWillChange.send()
            return
        }
        guard running < maxConcurrent, let next = jobs.last(where: { $0.state == .queued }) else {
            objectWillChange.send()
            return
        }
        next.state = .running
        next.stage = "Préparation"
        Task { await run(next) }
        pump()
    }

    private func run(_ job: DownloadJob) async {
        try? FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
        var args = [
            "--newline", "--progress", "--no-playlist", "--ignore-errors",
            "--progress-template",
            "download:PROG|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:PP|%(progress.postprocessor)s|%(progress.status)s",
            "--print", "after_move:FILE|%(filepath)s", "--no-simulate",
            "--write-thumbnail", "--convert-thumbnails", "jpg",
            "-P", job.folder.path, "-o", "%(title).100B [%(id)s].%(ext)s",
        ]
        args += job.options.arguments()
        args.append(job.video.url)

        let result: ProcResult
        do {
            result = try await Engine.run(
                args,
                onLine: { line in DispatchQueue.main.async { job.handle(line: line) } },
                register: { process in DispatchQueue.main.async {
                    job.process = process
                    if job.state == .cancelled { process.terminate() }
                } }
            )
        } catch {
            job.state = .failed(error.localizedDescription)
            pump()
            return
        }
        // Laisse passer les dernières lignes déjà postées sur le fil principal.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        guard job.state != .cancelled else {
            try? FileManager.default.removeItem(at: job.folder)
            return
        }

        guard let path = job.mediaPath, FileManager.default.fileExists(atPath: path) else {
            job.state = .failed(Engine.lastError(result.err))
            job.stage = "Échec"
            try? FileManager.default.removeItem(at: job.folder)
            pump()
            return
        }
        await retryMissingSubtitles(job)
        guard job.state != .cancelled else {
            try? FileManager.default.removeItem(at: job.folder)
            return
        }
        let item = await makeItem(job: job, mediaPath: path)
        library.add(item)
        job.fraction = 1
        job.state = .done
        let missing = missingSubtitles(job).count
        job.stage = missing > 0 ? "Terminé — \(missing) sous-titre(s) refusé(s) par YouTube" : "Terminé"
        pump()
    }

    private func subtitleCodes(in folder: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".vtt") }.compactMap { $0.dropLast(4).split(separator: ".").last.map(String.init) })
    }

    private func missingSubtitles(_ job: DownloadJob) -> [SubTrack] {
        let present = subtitleCodes(in: job.folder)
        return job.options.subtitles.filter { !present.contains($0.code) }
    }

    /// YouTube limite le débit des sous-titres (HTTP 429) de façon intermittente :
    /// on retente les pistes manquantes, seules, après une pause.
    private func retryMissingSubtitles(_ job: DownloadJob) async {
        for delay in [6.0, 20.0] {
            let missing = missingSubtitles(job)
            guard !missing.isEmpty, job.state != .cancelled else { return }
            job.state = .finishing
            job.stage = "Nouvel essai pour \(missing.count) sous-titre(s)…"
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            var args = ["--skip-download", "--no-playlist", "--ignore-errors"]
            if missing.contains(where: { !$0.auto }) { args.append("--write-subs") }
            if missing.contains(where: { $0.auto }) { args.append("--write-auto-subs") }
            args += [
                "--sub-langs", missing.map(\.code).sorted().joined(separator: ","),
                "--sub-format", "vtt/best", "--convert-subs", "vtt", "--sleep-subtitles", "3",
                "-P", job.folder.path, "-o", "%(title).100B [%(id)s].%(ext)s", job.video.url,
            ]
            _ = try? await Engine.run(args, register: { process in DispatchQueue.main.async { job.process = process } })
        }
    }

    private func makeItem(job: DownloadJob, mediaPath: String) async -> LibraryItem {
        let media = URL(fileURLWithPath: mediaPath)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: job.folder.path)) ?? []
        let subtitles = files.filter { $0.hasSuffix(".vtt") }.sorted().map { name -> LocalSubtitle in
            let code = name.dropLast(4).split(separator: ".").last.map(String.init) ?? "?"
            return LocalSubtitle(code: code, file: name)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: mediaPath))?[.size] as? NSNumber)?.int64Value ?? 0
        let asset = AVURLAsset(url: media)
        var playable = (try? await asset.load(.isPlayable)) ?? false
        if playable, job.options.kind == .video {
            // isPlayable peut être vrai pour un conteneur lisible dont le codec vidéo ne l'est pas.
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if let track = tracks.first {
                playable = (try? await track.load(.isPlayable)) ?? false
            } else {
                playable = false
            }
        }
        return LibraryItem(
            id: UUID(),
            videoID: job.video.id,
            title: job.video.title,
            channel: job.video.channel,
            duration: job.video.duration,
            summaryText: String(job.summaryText.prefix(600)),
            folder: job.folder.path,
            mediaFile: media.lastPathComponent,
            thumbFile: files.first { $0.hasSuffix(".jpg") },
            subtitles: subtitles,
            kind: job.options.kind,
            quality: job.options.qualityLabel,
            size: size,
            addedAt: Date(),
            playable: playable
        )
    }
}

// MARK: - État de l'application

@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable { case home, categories, local, search, library, downloads, settings }

    @Published var tab: Tab = .home
    @Published var rows: [HomeRow] = []
    @Published var featured: VideoSummary?
    @Published var loadingHome = false
    @Published var homeError: String?

    @Published var query = ""
    @Published var results: [VideoSummary] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var searchedQuery = ""

    @Published var detail: VideoSummary?
    @Published var playing: PlayableMedia?
    /// Identifiant de la vidéo dont le flux est en cours de préparation.
    @Published var streamLoading: String?
    @Published var streamError: String?
    /// Série du disque dont la page est ouverte.
    @Published var localSeries: LocalSeries?
    /// Film du disque dont la fiche est ouverte.
    @Published var localMovie: LocalMovie?
    /// Chemin du fichier local en cours de préparation à la lecture.
    @Published var localPreparing: String?
    private var localProcess: Process?
    private var localCancelled = false

    @Published var engine = EngineInfo()
    @Published var engineChecked = false
    @Published var engineBusy = false
    @Published var engineLog = ""
    @Published var engineAutoUpdate = UserDefaults.standard.object(forKey: "engineAutoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(engineAutoUpdate, forKey: "engineAutoUpdate")
            if engineAutoUpdate { Task { await autoUpdateEngineIfDue() } }
        }
    }
    @Published var engineLastCheck: Date? = {
        let stamp = UserDefaults.standard.double(forKey: "engineLastCheck")
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }() {
        didSet { UserDefaults.standard.set(engineLastCheck?.timeIntervalSince1970 ?? 0, forKey: "engineLastCheck") }
    }

    @Published var category: Category?
    @Published var categoryRows: [String: [HomeRow]] = [:]
    @Published var categoryLoading: Set<String> = []
    /// Erreur de chargement par catégorie (clé : identifiant), pour ne pas l'afficher sur une autre.
    @Published var categoryErrors: [String: String] = [:]

    @Published var aiRows: [HomeRow] = []
    @Published var aiBusy = false
    @Published var aiError: String?
    @Published var aiEnabled = UserDefaults.standard.bool(forKey: "aiEnabled") {
        didSet {
            UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled")
            if aiEnabled, ProcessInfo.processInfo.environment["LUMIO_DEBUG"] == nil {
                Task { await refreshSuggestions(force: false) }
            }
        }
    }

    let library: Library
    let downloads: DownloadManager
    let history = WatchHistory()
    let local = LocalLibrary()
    private let aiCacheFile = Paths.support.appendingPathComponent("suggestions.json")
    private var detailCache: [String: VideoDetail] = [:]
    private var searchToken = 0
    private let homeCache = Paths.support.appendingPathComponent("home.json")

    static let defaultRows = """
    Documentaires à couper le souffle | documentaire nature 4k
    Science et espace | documentaire espace univers
    Concerts et sessions live | concert live complet
    Bandes-annonces | bande annonce officielle vf
    Tech et gadgets | test high-tech
    En cuisine | recette de chef
    Évasion | voyage 4k drone
    """

    init() {
        let library = Library()
        self.library = library
        downloads = DownloadManager(library: library)
        loadCachedHome()
        Task {
            await refreshEngine()
            // Sans moteur, l'accueil ne peut pas charger : on l'installe d'abord. Sinon la
            // vérification passe après, en arrière-plan.
            if engine.path == nil { await autoUpdateEngineIfDue() }
            await loadHome(force: false)
            await autoUpdateEngineIfDue()
            // Sous le pilote de test, pas d'appel automatique : il serait facturé sur la clé de l'utilisateur.
            if ProcessInfo.processInfo.environment["LUMIO_DEBUG"] == nil {
                await refreshSuggestions(force: false)
            }
        }
        scheduleEngineChecks()
        loadCachedSuggestions()
        DebugDriver.startIfRequested(self)
    }

    // MARK: Moteur

    func refreshEngine() async {
        engine = await Engine.info()
        engineChecked = true
    }

    func updateEngine() {
        Task { await runEngineUpdate() }
    }

    /// Installe ou met à jour la copie privée de yt-dlp. Les téléchargements en attente
    /// patientent pendant l'opération, pour ne pas lancer un moteur en cours de remplacement.
    @discardableResult
    func runEngineUpdate() async -> Bool {
        guard !engineBusy else { return false }
        engineBusy = true
        downloads.engineBusy = true
        engineLog = "Préparation…"
        let before = engine.managed ? engine.version : nil
        var succeeded = false
        do {
            try await Engine.installOrUpdate { line in
                DispatchQueue.main.async { if self.engineBusy { self.engineLog = line } }
            }
            await refreshEngine()
            engineLastCheck = Date()
            let version = engine.version ?? "?"
            engineLog = before == nil || before == engine.version
                ? "Moteur à jour (\(version))"
                : "Moteur mis à jour : \(before ?? "?") → \(version)"
            succeeded = true
        } catch {
            engineLog = "Échec de la mise à jour : \(error.localizedDescription)"
        }
        engineBusy = false
        downloads.engineBusy = false
        downloads.resume()
        if succeeded, rows.isEmpty { await loadHome(force: true) }
        return succeeded
    }

    /// Vérification quotidienne, silencieuse, quand aucun téléchargement n'est en cours.
    /// Sans copie privée du moteur, elle l'installe : YouTube refuse vite les versions anciennes.
    func autoUpdateEngineIfDue() async {
        guard engineAutoUpdate, engineChecked, !engineBusy, downloads.activeCount == 0 else { return }
        let due = engineLastCheck.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
        guard due || !engine.managed else { return }
        await runEngineUpdate()
    }

    private func scheduleEngineChecks() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                await autoUpdateEngineIfDue()
            }
        }
    }

    // MARK: Accueil

    private struct HomeCache: Codable {
        let date: Date
        let config: String
        let rows: [HomeRow]
    }

    var rowsConfig: String {
        UserDefaults.standard.string(forKey: "homeRows") ?? Self.defaultRows
    }

    private func configuredRows() -> [(title: String, query: String)] {
        var list: [(String, String)] = []
        if let last = recentSearches.first {
            list.append(("Parce que vous avez cherché « \(last) »", last))
        }
        for line in rowsConfig.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let title = parts.first, !title.isEmpty else { continue }
            list.append((title, parts.count > 1 && !parts[1].isEmpty ? parts[1] : title))
        }
        return list
    }

    private func loadCachedHome() {
        guard let data = try? Data(contentsOf: homeCache),
              let cache = try? JSONDecoder().decode(HomeCache.self, from: data) else { return }
        rows = cache.rows
        pickFeatured()
    }

    private func pickFeatured() {
        featured = rows.first(where: { !$0.title.hasPrefix("Parce que") })?.items.prefix(6).randomElement()
            ?? rows.first?.items.first
    }

    func loadHome(force: Bool) async {
        guard !loadingHome else { return }
        if !force,
           let data = try? Data(contentsOf: homeCache),
           let cache = try? JSONDecoder().decode(HomeCache.self, from: data),
           cache.config == rowsConfig, Date().timeIntervalSince(cache.date) < 4 * 3600, !cache.rows.isEmpty {
            return
        }
        guard engine.path != nil else { return }
        loadingHome = true
        homeError = nil
        let wanted = configuredRows()
        var loaded: [Int: HomeRow] = [:]
        var firstError: String?
        // Trois recherches de front : assez rapide sans bousculer YouTube.
        for chunk in stride(from: 0, to: wanted.count, by: 3) {
            await withTaskGroup(of: (Int, HomeRow?, String?).self) { group in
                for index in chunk..<min(chunk + 3, wanted.count) {
                    let (title, query) = wanted[index]
                    group.addTask {
                        do {
                            let items = try await Engine.search(query, limit: 18)
                            return (index, HomeRow(title: title, query: query, items: items), nil)
                        } catch {
                            return (index, nil, error.localizedDescription)
                        }
                    }
                }
                for await (index, row, error) in group {
                    if let row, !row.items.isEmpty { loaded[index] = row }
                    if let error, firstError == nil { firstError = error }
                }
            }
            let ordered = loaded.keys.sorted().compactMap { loaded[$0] }
            if !ordered.isEmpty {
                rows = ordered
                if featured == nil || force { pickFeatured() }
            }
        }
        loadingHome = false
        if loaded.isEmpty {
            homeError = firstError ?? "Aucun résultat"
        } else if let data = try? JSONEncoder().encode(HomeCache(date: Date(), config: rowsConfig, rows: rows)) {
            try? data.write(to: homeCache, options: .atomic)
        }
    }

    // MARK: Lecture sans téléchargement

    /// Lit une vidéo en streaming. Si elle est déjà dans la bibliothèque, on lit le fichier local.
    func watch(_ video: VideoSummary) async {
        if let owned = library.item(forVideo: video.id), owned.playable {
            play(owned)
            return
        }
        guard streamLoading == nil else { return }
        streamLoading = video.id
        streamError = nil
        defer { streamLoading = nil }
        do {
            let loaded = try await loadDetail(video)
            guard let raw = loaded.streamURL, let url = URL(string: raw) else {
                streamError = "YouTube ne propose pas de flux lisible directement pour cette vidéo. Vous pouvez la télécharger."
                return
            }
            let resume = history.entry(for: video.id)?.position ?? 0
            detail = nil
            playing = PlayableMedia(stream: loaded, url: url, startPosition: resume)
        } catch {
            streamError = error.localizedDescription
        }
    }

    // MARK: Films et séries du disque

    /// Lit un film ou un épisode trouvé sur le disque. Un fichier que le lecteur système ne lit pas
    /// tel quel (MKV) est d'abord recopié dans un MP4 temporaire, sans réencodage : une à deux secondes.
    func playLocal(path: String) async {
        guard localPreparing == nil else { return }
        localPreparing = path
        localCancelled = false
        streamError = nil
        defer { localPreparing = nil; localProcess = nil }

        var title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var detailLine = "Fichier local"
        if let series = local.catalog.series.first(where: { $0.episodes.contains { $0.path == path } }),
           let episode = series.episodes.first(where: { $0.path == path }) {
            title = series.title
            detailLine = "S\(episode.season) : É\(episode.number)" + (episode.title.map { " · \($0)" } ?? "")
        } else if let movie = local.catalog.movies.first(where: { $0.path == path }) {
            title = movie.title
            detailLine = movie.year.map(String.init) ?? "Film"
        }
        do {
            let prepared = try await MediaPreparer.prepare(path) { process in
                DispatchQueue.main.async { self.localProcess = process }
            }
            guard !localCancelled else { return }
            let saved = local.position(for: path)
            let resume = saved.map { $0.finished ? 0 : $0.position } ?? 0
            detail = nil
            localSeries = nil
            localMovie = nil
            playing = PlayableMedia(localPath: path, title: title, detailLine: detailLine, prepared: prepared,
                                    startPosition: resume, nextPath: local.episode(after: path)?.episode.path)
        } catch {
            // Une annulation arrête ffmpeg, qui renvoie alors une erreur : ce n'en est pas une pour l'utilisateur.
            if !localCancelled { streamError = error.localizedDescription }
        }
    }

    func cancelLocalPreparation() {
        guard localPreparing != nil else { return }
        localCancelled = true
        localProcess?.terminate()
    }

    // MARK: Catégories

    private struct CategoryCache: Codable {
        var entries: [String: Entry] = [:]
        struct Entry: Codable {
            let date: Date
            let rows: [HomeRow]
        }
    }

    private var categoryCacheFile: URL { Paths.support.appendingPathComponent("categories.json") }

    private func readCategoryCache() -> CategoryCache {
        guard let data = try? Data(contentsOf: categoryCacheFile),
              let cache = try? JSONDecoder().decode(CategoryCache.self, from: data) else { return CategoryCache() }
        return cache
    }

    func open(_ category: Category) {
        tab = .categories
        categoryErrors[category.id] = nil
        self.category = category
    }

    /// Charge les rangées d'une catégorie : cache disque de 6 h, sinon recherches en parallèle.
    func loadCategory(_ category: Category, force: Bool) async {
        guard !categoryLoading.contains(category.id) else { return }
        let cached = readCategoryCache().entries[category.id]
        if let cached, categoryRows[category.id] == nil { categoryRows[category.id] = cached.rows }
        if !force, let cached, Date().timeIntervalSince(cached.date) < 6 * 3600, !cached.rows.isEmpty { return }
        guard engine.path != nil else {
            if categoryRows[category.id] == nil { categoryErrors[category.id] = EngineError.missing.localizedDescription }
            return
        }
        categoryLoading.insert(category.id)
        categoryErrors[category.id] = nil
        let limit = category.rows.count == 1 ? 36 : 18
        var loaded: [Int: HomeRow] = [:]
        var firstError: String?
        await withTaskGroup(of: (Int, HomeRow?, String?).self) { group in
            for (index, row) in category.rows.enumerated() {
                group.addTask {
                    do {
                        let items = try await Engine.search(row.query, limit: limit)
                        return (index, HomeRow(title: row.title, query: row.query, items: items), nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            for await (index, row, error) in group {
                if let row, !row.items.isEmpty {
                    loaded[index] = row
                    categoryRows[category.id] = loaded.keys.sorted().compactMap { loaded[$0] }
                }
                if let error, firstError == nil { firstError = error }
            }
        }
        categoryLoading.remove(category.id)
        guard !loaded.isEmpty else {
            if categoryRows[category.id] == nil { categoryErrors[category.id] = firstError ?? "Aucune vidéo trouvée." }
            return
        }
        var cache = readCategoryCache()
        cache.entries[category.id] = .init(date: Date(), rows: categoryRows[category.id] ?? [])
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: categoryCacheFile, options: .atomic) }
    }

    // MARK: Suggestions par Claude

    private struct SuggestionCache: Codable {
        let date: Date
        let fingerprint: String
        let rows: [HomeRow]
    }

    /// Ce qui est envoyé à l'API : titres et chaînes de la bibliothèque, avancement, recherches récentes.
    var tasteProfile: TasteProfile {
        struct Seen { let title: String; let channel: String?; let percent: Int?; let date: Date }
        var seen = library.items.map {
            Seen(title: $0.title, channel: $0.channel, percent: $0.progress.map { Int($0 * 100) }, date: $0.lastPlayedAt ?? $0.addedAt)
        }
        let owned = Set(library.items.map(\.videoID))
        seen += history.entries.filter { !owned.contains($0.video.id) }.map {
            Seen(title: $0.video.title, channel: $0.video.channel, percent: $0.progress.map { Int($0 * 100) }, date: $0.date)
        }
        return TasteProfile(
            watched: seen.sorted { $0.date > $1.date }.prefix(30).map {
                TasteProfile.Watched(title: $0.title, channel: $0.channel, percent: $0.percent)
            },
            searches: recentSearches
        )
    }

    private func readSuggestionCache() -> SuggestionCache? {
        guard let data = try? Data(contentsOf: aiCacheFile) else { return nil }
        return try? JSONDecoder().decode(SuggestionCache.self, from: data)
    }

    private func loadCachedSuggestions() {
        guard aiEnabled, let cache = readSuggestionCache() else { return }
        aiRows = cache.rows
    }

    /// Interroge Claude seulement si l'historique a changé (et au plus une fois par heure),
    /// sauf demande explicite : chaque appel est facturé sur la clé de l'utilisateur.
    func refreshSuggestions(force: Bool) async {
        guard aiEnabled, !aiBusy, APIKeyStore.hasKey, engine.path != nil else { return }
        let profile = tasteProfile
        guard !profile.isEmpty else {
            aiError = "Téléchargez ou cherchez quelques vidéos d'abord : Claude n'a encore rien pour vous connaître."
            return
        }
        if !force, let cache = readSuggestionCache(),
           cache.fingerprint == profile.fingerprint || Date().timeIntervalSince(cache.date) < 3600 {
            // Rien de neuf : on réaffiche les suggestions déjà obtenues, sans appel.
            if aiRows.isEmpty { aiRows = cache.rows }
            aiError = nil
            return
        }
        aiBusy = true
        aiError = nil
        defer { aiBusy = false }
        do {
            let suggestions = try await ClaudeClient.suggest(for: profile)
            var rows: [HomeRow] = []
            for suggestion in suggestions {
                guard let items = try? await Engine.search(suggestion.query, limit: 18), !items.isEmpty else { continue }
                rows.append(HomeRow(title: suggestion.title, query: suggestion.query, items: items, reason: suggestion.reason))
                aiRows = rows
            }
            guard !rows.isEmpty else {
                aiError = "Les suggestions de Claude n'ont donné aucun résultat."
                return
            }
            let cache = SuggestionCache(date: Date(), fingerprint: profile.fingerprint, rows: rows)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: aiCacheFile, options: .atomic) }
        } catch {
            aiError = error.localizedDescription
        }
    }

    func clearSuggestions() {
        aiRows = []
        aiError = nil
        try? FileManager.default.removeItem(at: aiCacheFile)
    }

    // MARK: Recherche

    var recentSearches: [String] {
        UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    }

    func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        tab = .search
        searching = true
        searchError = nil
        searchedQuery = text
        searchToken += 1
        let token = searchToken
        if !text.hasPrefix("http") {
            var recent = recentSearches.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
            recent.insert(text, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(8)), forKey: "recentSearches")
        }
        Task {
            do {
                let found = try await Engine.search(text, limit: 40)
                guard token == searchToken else { return }
                results = found
                // Une URL de vidéo unique ouvre directement sa fiche.
                if text.hasPrefix("http"), found.count == 1 { detail = found[0] }
            } catch {
                guard token == searchToken else { return }
                results = []
                searchError = error.localizedDescription
            }
            searching = false
        }
    }

    // MARK: Détail et lecture

    func loadDetail(_ video: VideoSummary) async throws -> VideoDetail {
        // Les liens de flux expirent : au-delà de trois heures, on redemande la fiche.
        if let cached = detailCache[video.id], Date().timeIntervalSince(cached.fetchedAt) < 3 * 3600 { return cached }
        let detail = try await Engine.detail(for: video)
        detailCache[video.id] = detail
        return detail
    }

    func play(_ item: LibraryItem) {
        if item.playable {
            detail = nil
            playing = PlayableMedia(item: item)
        } else {
            NSWorkspace.shared.open(item.mediaURL)
        }
    }
}
