import Foundation

// MARK: - Catalogue

struct VideoSummary: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var channel: String?
    var duration: Double?
    var viewCount: Int?
    var thumbnail: String?
    /// Identifiant de la chaîne, quand la source le donne. Optionnel : absent des fichiers plus anciens.
    var channelID: String? = nil
    /// Date de publication approximative (secondes depuis 1970), connue pour les fils d'abonnements.
    var publishedAt: Double? = nil

    var url: String { "https://www.youtube.com/watch?v=\(id)" }

    var cardImages: [URL] {
        [thumbnail, "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"]
            .compactMap { $0 }.compactMap(URL.init(string:))
    }

    var heroImages: [URL] {
        ["https://i.ytimg.com/vi/\(id)/maxresdefault.jpg", thumbnail, "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"]
            .compactMap { $0 }.compactMap(URL.init(string:))
    }

    var subtitleLine: String {
        [channel, Fmt.views(viewCount)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct HomeRow: Codable, Identifiable, Hashable {
    var id: String { title }
    let title: String
    let query: String
    var items: [VideoSummary]
    /// Pour les rangées suggérées par Claude : pourquoi elle est proposée.
    var reason: String? = nil
}

enum VCodec: String, Codable, CaseIterable, Hashable {
    case h264, av1, vp9

    static func from(_ raw: String) -> VCodec? {
        if raw.hasPrefix("avc") { return .h264 }
        if raw.hasPrefix("av01") { return .av1 }
        if raw.hasPrefix("vp9") || raw.hasPrefix("vp09") { return .vp9 }
        return nil
    }

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        }
    }

    var container: String { self == .vp9 ? "mkv" : "mp4" }
    var selector: String {
        switch self {
        case .h264: return "[vcodec^=avc]"
        case .av1: return "[vcodec^=av01]"
        case .vp9: return "[vcodec^=vp]"
        }
    }
}

struct YTFormat: Hashable {
    let id: String
    let ext: String
    let vcodec: String
    let acodec: String
    let height: Int?
    let fps: Double?
    let tbr: Double?
    let size: Int64?
    let language: String?
    let note: String
    let proto: String

    var isVideo: Bool { vcodec != "none" && !proto.hasPrefix("mhtml") }
    var isAudioOnly: Bool { vcodec == "none" && acodec != "none" }
    var codec: VCodec? { VCodec.from(vcodec) }
}

struct SubTrack: Codable, Hashable, Identifiable {
    let code: String
    let name: String
    let auto: Bool
    /// Adresse du fichier WebVTT chez YouTube, pour la lecture en streaming.
    var url: String? = nil
    var id: String { (auto ? "a:" : "m:") + code }
}

struct VideoDetail {
    let summary: VideoSummary
    let description: String
    let uploadDate: String?
    let likeCount: Int?
    let formats: [YTFormat]
    let subtitles: [SubTrack]
    let autoSubtitles: [SubTrack]
    let chapterCount: Int
    /// Manifeste adaptatif (HLS) que le lecteur système lit sans téléchargement. Il expire après quelques heures.
    var streamURL: String? = nil
    var fetchedAt = Date()

    /// Flux vidéo directs (HTTP), ceux que yt-dlp privilégie.
    var videoFormats: [YTFormat] {
        formats.filter { $0.isVideo && $0.proto.hasPrefix("http") && $0.codec != nil && ($0.height ?? 0) >= 144 }
    }

    var audioFormats: [YTFormat] {
        formats.filter { $0.isAudioOnly && $0.proto.hasPrefix("http") }
    }

    var heights: [Int] {
        Array(Set(videoFormats.compactMap(\.height))).sorted(by: >)
    }

    func codecs(at height: Int) -> Set<VCodec> {
        Set(videoFormats.filter { $0.height == height }.compactMap(\.codec))
    }

    func heightLabel(_ height: Int) -> String {
        let fps = videoFormats.filter { $0.height == height }.compactMap(\.fps).max() ?? 0
        return "\(height)p" + (fps > 30 ? "\(Int(fps.rounded()))" : "")
    }

    static func heightTag(_ height: Int) -> String? {
        switch height {
        case 4320...: return "8K"
        case 2160..<4320: return "4K"
        case 1440..<2160: return "QHD"
        case 1080..<1440: return "HD"
        default: return nil
        }
    }

    /// Langues audio distinctes (pistes doublées).
    var audioLanguages: [String] {
        var seen = Set<String>(), ordered: [String] = []
        for format in audioFormats {
            guard let language = format.language, !language.isEmpty, seen.insert(language).inserted else { continue }
            ordered.append(language)
        }
        return ordered.count > 1 ? ordered : []
    }

    func estimatedSize(_ options: DownloadOptions) -> Int64? {
        let audios = audioFormats.filter { options.audioLanguage == nil || $0.language == options.audioLanguage }
        let wantsOpus = options.kind == .video ? options.codec == .vp9 : options.audioFormat == .opus
        let preferred = audios.filter { wantsOpus ? $0.acodec == "opus" : $0.acodec.hasPrefix("mp4a") }
        let audio = (preferred.isEmpty ? audios : preferred).max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
        guard options.kind == .video else { return audio?.size }
        let video = videoFormats
            .filter { $0.height == options.height && $0.codec == options.codec }
            .max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
        guard let videoSize = video?.size else { return nil }
        return videoSize + (audio?.size ?? 0)
    }
}

// MARK: - Options de téléchargement

enum MediaKind: String, Codable { case video, audio }

enum AudioFormat: String, Codable, CaseIterable {
    case m4a, mp3, opus, flac

    var label: String {
        switch self {
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        case .opus: return "Opus"
        case .flac: return "FLAC"
        }
    }

    var detail: String {
        switch self {
        case .m4a: return "AAC, sans réencodage"
        case .mp3: return "universel"
        case .opus: return "le plus léger"
        case .flac: return "sans perte"
        }
    }
}

struct DownloadOptions: Hashable {
    var kind: MediaKind = .video
    var height: Int = 1080
    var codec: VCodec = .h264
    var audioFormat: AudioFormat = .m4a
    var audioLanguage: String? = nil
    var subtitles: Set<SubTrack> = []
    var embedSubtitles = true
    var embedMetadata = true
    var embedChapters = true
    var removeSponsors = false

    var qualityLabel: String {
        kind == .audio ? "Audio \(audioFormat.label)" : "\(height)p \(codec.label)"
    }

    /// Arguments yt-dlp correspondant à ces choix.
    func arguments() -> [String] {
        var args: [String] = []
        let language = audioLanguage.map { "[language^=\($0)]" } ?? ""
        switch kind {
        case .video:
            let h = "[height<=\(height)]"
            let audioCodec = codec == .vp9 ? "[acodec=opus]" : "[acodec^=mp4a]"
            let selector = [
                "bv*\(h)\(codec.selector)+ba\(audioCodec)\(language)",
                "bv*\(h)\(codec.selector)+ba\(language)",
                "bv*\(h)\(codec.selector)+ba",
                "bv*\(h)+ba",
                "b\(h)",
                "b",
            ].joined(separator: "/")
            args += ["-f", selector, "--merge-output-format", codec.container]
        case .audio:
            let prefer = audioFormat == .m4a ? "ba[ext=m4a]\(language)/" : ""
            args += ["-f", "\(prefer)ba\(language)/ba/b", "-x", "--audio-format", audioFormat.rawValue, "--audio-quality", "0"]
        }
        if !subtitles.isEmpty {
            let embed = embedSubtitles && kind == .video
            // --write-subs est aussi requis à l'intégration : sans lui, yt-dlp efface les .vtt
            // une fois intégrés, alors que le lecteur de l'app lit ces fichiers.
            if embed || subtitles.contains(where: { !$0.auto }) { args.append("--write-subs") }
            if subtitles.contains(where: { $0.auto }) { args.append("--write-auto-subs") }
            let codes = Array(Set(subtitles.map(\.code))).sorted().joined(separator: ",")
            args += ["--sub-langs", codes, "--sub-format", "vtt/best", "--convert-subs", "vtt", "--sleep-subtitles", "1"]
            if embed { args.append("--embed-subs") }
        }
        if embedMetadata { args += ["--embed-metadata", "--embed-thumbnail"] }
        if embedChapters { args.append("--embed-chapters") }
        if removeSponsors { args += ["--sponsorblock-remove", "sponsor,selfpromo"] }
        return args
    }
}

// MARK: - Bibliothèque

struct LocalSubtitle: Codable, Hashable, Identifiable {
    let code: String
    let file: String
    var id: String { file }
}

struct LibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    let videoID: String
    var title: String
    var channel: String?
    var duration: Double?
    var summaryText: String?
    let folder: String
    let mediaFile: String
    var thumbFile: String?
    var subtitles: [LocalSubtitle]
    let kind: MediaKind
    let quality: String
    var size: Int64
    let addedAt: Date
    var playable: Bool
    var position: Double = 0
    var lastPlayedAt: Date?
    /// Vrai une fois la vidéo vue jusqu'au bout. Optionnel : absent des bibliothèques plus anciennes.
    var watched: Bool? = nil

    var folderURL: URL { URL(fileURLWithPath: folder, isDirectory: true) }
    var mediaURL: URL { folderURL.appendingPathComponent(mediaFile) }
    var images: [URL] {
        var urls: [URL] = []
        if let thumbFile { urls.append(folderURL.appendingPathComponent(thumbFile)) }
        if let remote = URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg") { urls.append(remote) }
        return urls
    }

    var progress: Double? {
        guard let duration, duration > 0, position > 5 else { return nil }
        return min(1, position / duration)
    }
}
