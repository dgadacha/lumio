import Foundation

enum EngineError: LocalizedError {
    case missing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "Moteur de téléchargement introuvable. Installez-le depuis Réglages."
        case .failed(let message):
            return message
        }
    }
}

struct EngineInfo: Equatable {
    var path: String?
    var version: String?
    var managed = false

    /// Vrai si la version a plus de 60 jours : YouTube change souvent, un moteur ancien échoue.
    var outdated: Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").prefix(3).compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return false }
        return Date().timeIntervalSince(date) > 60 * 86_400
    }
}

/// Enveloppe autour de yt-dlp : recherche, métadonnées, mise à jour du moteur.
enum Engine {
    static let managedBinary = Paths.engineDir.appendingPathComponent("bin/yt-dlp")

    static func binary() -> URL? {
        let candidates = [
            managedBinary.path,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Une app lancée depuis le Finder n'hérite pas du PATH du shell :
    /// on le fournit pour que yt-dlp trouve ffmpeg et le moteur JavaScript.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.deno/bin", "\(home)/.local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    static func run(
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil,
        register: (@Sendable (Process) -> Void)? = nil
    ) async throws -> ProcResult {
        guard let binary = binary() else { throw EngineError.missing }
        return try await ProcessRunner.run(binary, arguments, env: environment, onLine: onLine, register: register)
    }

    static func info() async -> EngineInfo {
        guard let binary = binary() else { return EngineInfo() }
        let result = try? await ProcessRunner.run(binary, ["--version"], env: environment)
        let version = result.map { String(decoding: $0.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return EngineInfo(path: binary.path, version: version?.isEmpty == false ? version : nil, managed: binary == managedBinary)
    }

    static func lastError(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let error = lines.last { $0.hasPrefix("ERROR:") } ?? lines.last ?? "Erreur inconnue"
        return error.replacingOccurrences(of: "ERROR: ", with: "")
    }

    // MARK: Recherche

    /// Recherche par mots-clés, ou liste le contenu d'une URL (vidéo, playlist, chaîne).
    static func search(_ query: String, limit: Int) async throws -> [VideoSummary] {
        let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
        let target = isURL ? query : "ytsearch\(limit):\(query)"
        let result = try await run(["--flat-playlist", "-J", "--playlist-end", "\(limit)", "--no-warnings", target])
        guard let root = try? JSONSerialization.jsonObject(with: result.out) as? [String: Any] else {
            throw EngineError.failed(lastError(result.err))
        }
        let entries = (root["entries"] as? [[String: Any]]) ?? [root]
        // La liste d'une chaîne ne répète pas son nom sur chaque vidéo : on le reprend de l'en-tête.
        let listChannel = root["channel"] as? String
        let listChannelID = root["channel_id"] as? String
        var seen = Set<String>()
        return entries.compactMap(summary(from:)).filter { seen.insert($0.id).inserted }.map { video in
            var video = video
            if video.channel == nil { video.channel = listChannel }
            if video.channelID == nil { video.channelID = listChannelID }
            return video
        }
    }

    /// Dernières vidéos d'une chaîne suivie, avec leur date approximative pour pouvoir trier le fil.
    static func channelVideos(_ channel: FollowedChannel, limit: Int) async throws -> [VideoSummary] {
        let result = try await run([
            "--flat-playlist", "-J", "--playlist-end", "\(limit)", "--no-warnings",
            "--extractor-args", "youtubetab:approximate_date", channel.videosURL,
        ])
        guard let root = try? JSONSerialization.jsonObject(with: result.out) as? [String: Any] else {
            throw EngineError.failed(lastError(result.err))
        }
        return ((root["entries"] as? [[String: Any]]) ?? []).compactMap(summary(from:)).map { video in
            var video = video
            video.channel = channel.name
            video.channelID = channel.id
            return video
        }
    }

    private static func summary(from entry: [String: Any]) -> VideoSummary? {
        guard let id = entry["id"] as? String, id.count == 11,
              let title = entry["title"] as? String else { return nil }
        if let url = entry["url"] as? String, url.contains("/shorts/") { return nil }
        guard let duration = number(entry["duration"]), duration > 0 else { return nil }
        let thumbs = (entry["thumbnails"] as? [[String: Any]]) ?? []
        let best = thumbs.max { (number($0["width"]) ?? 0) < (number($1["width"]) ?? 0) }
        return VideoSummary(
            id: id,
            title: title,
            channel: (entry["channel"] as? String) ?? (entry["uploader"] as? String),
            duration: duration,
            viewCount: number(entry["view_count"]).map(Int.init),
            thumbnail: (best?["url"] as? String) ?? (entry["thumbnail"] as? String),
            channelID: entry["channel_id"] as? String,
            publishedAt: number(entry["timestamp"])
        )
    }

    // MARK: Détail

    static func detail(for video: VideoSummary) async throws -> VideoDetail {
        let result = try await run(["-J", "--no-playlist", "--no-warnings", video.url])
        guard let root = try? JSONSerialization.jsonObject(with: result.out) as? [String: Any] else {
            throw EngineError.failed(lastError(result.err))
        }
        let formats: [YTFormat] = ((root["formats"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let id = f["format_id"] as? String else { return nil }
            return YTFormat(
                id: id,
                ext: (f["ext"] as? String) ?? "",
                vcodec: (f["vcodec"] as? String) ?? "none",
                acodec: (f["acodec"] as? String) ?? "none",
                height: number(f["height"]).map(Int.init),
                fps: number(f["fps"]),
                tbr: number(f["tbr"]),
                size: (number(f["filesize"]) ?? number(f["filesize_approx"])).map(Int64.init),
                language: f["language"] as? String,
                note: (f["format_note"] as? String) ?? "",
                proto: (f["protocol"] as? String) ?? ""
            )
        }
        var summary = video
        summary.title = (root["title"] as? String) ?? video.title
        summary.channel = (root["channel"] as? String) ?? video.channel
        summary.channelID = (root["channel_id"] as? String) ?? video.channelID
        summary.duration = number(root["duration"]) ?? video.duration
        summary.viewCount = number(root["view_count"]).map(Int.init) ?? video.viewCount
        return VideoDetail(
            summary: summary,
            description: (root["description"] as? String) ?? "",
            uploadDate: root["upload_date"] as? String,
            likeCount: number(root["like_count"]).map(Int.init),
            formats: formats,
            subtitles: tracks(root["subtitles"], auto: false),
            autoSubtitles: tracks(root["automatic_captions"], auto: true),
            chapterCount: (root["chapters"] as? [Any])?.count ?? 0,
            streamURL: ((root["formats"] as? [[String: Any]]) ?? [])
                .first { ($0["protocol"] as? String)?.hasPrefix("m3u8") == true && $0["manifest_url"] is String }?["manifest_url"] as? String
        )
    }

    private static func tracks(_ raw: Any?, auto: Bool) -> [SubTrack] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.keys
            .filter { $0 != "live_chat" }
            .map { code -> SubTrack in
                let entries = dict[code] as? [[String: Any]]
                let name = (entries?.first?["name"] as? String) ?? Fmt.language(code)
                let vtt = entries?.first { $0["ext"] as? String == "vtt" }?["url"] as? String
                return SubTrack(code: code, name: name, auto: auto, url: vtt)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    // MARK: Mise à jour du moteur

    /// Installe ou met à jour une copie privée de yt-dlp dans le dossier de données de l'app
    /// (environnement Python isolé : rien n'est modifié ailleurs sur le système).
    static func installOrUpdate(log: @escaping @Sendable (String) -> Void) async throws {
        let pythons = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = pythons.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw EngineError.failed("Python 3 est introuvable (requis pour installer le moteur).")
        }
        let venvPython = Paths.engineDir.appendingPathComponent("bin/python3")
        if !FileManager.default.isExecutableFile(atPath: venvPython.path) {
            log("Création de l'environnement…")
            let created = try await ProcessRunner.run(
                URL(fileURLWithPath: python), ["-m", "venv", Paths.engineDir.path], env: environment)
            guard created.status == 0 else { throw EngineError.failed(created.err) }
        }
        log("Téléchargement de la dernière version…")
        let installed = try await ProcessRunner.run(
            venvPython,
            ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "yt-dlp[default,curl-cffi]"],
            env: environment,
            onLine: { line in if !line.isEmpty { log(String(line.prefix(90))) } }
        )
        guard installed.status == 0 else {
            throw EngineError.failed(installed.err.split(separator: "\n").last.map(String.init) ?? "Échec de l'installation")
        }
    }
}

// MARK: - Sous-titres WebVTT

struct Cue {
    let start: Double
    var end: Double
    let text: String
}

enum VTT {
    static func parse(_ source: String) -> [Cue] {
        var cues: [Cue] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.contains("-->") else { continue }
            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0]),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0])
            else { continue }
            var body: [String] = []
            while index < lines.count, !lines[index].isEmpty, !lines[index].contains("-->") {
                body.append(lines[index])
                index += 1
            }
            // Sous-titres automatiques : chaque phrase est répétée dans des blocs de transition
            // de 10 ms. On les écarte, puis on comble le trou qu'ils laissent.
            let text = clean(body.joined(separator: "\n"))
            if !text.isEmpty, end - start >= 0.05 {
                cues.append(Cue(start: start, end: end, text: text))
            }
        }
        for i in cues.indices.dropLast() where cues[i + 1].start - cues[i].end < 0.15 && cues[i + 1].start > cues[i].start {
            cues[i].end = cues[i + 1].start
        }
        return cues
    }

    private static func time(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#39;": "'", "&quot;": "\""] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
