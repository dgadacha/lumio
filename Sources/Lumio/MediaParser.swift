import Foundation

// Classement des fichiers vidéo locaux en séries, saisons, épisodes et films, à partir de leur nom.
// Fonctions pures (Foundation seul) : testables hors de l'app.

struct LocalEpisode: Codable, Hashable, Identifiable {
    let path: String
    let season: Int
    let number: Int
    let title: String?
    let size: Int64
    var id: String { path }

    var label: String { title ?? "Épisode \(number)" }
}

struct LocalSeries: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let year: Int?
    var episodes: [LocalEpisode]

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    func episodes(in season: Int) -> [LocalEpisode] {
        episodes.filter { $0.season == season }.sorted { $0.number < $1.number }
    }
    var totalSize: Int64 { episodes.reduce(0) { $0 + $1.size } }
}

struct LocalMovie: Codable, Hashable, Identifiable {
    let path: String
    let title: String
    let year: Int?
    let size: Int64
    var id: String { path }
}

struct LocalCatalog: Codable, Hashable {
    var series: [LocalSeries] = []
    var movies: [LocalMovie] = []
    var isEmpty: Bool { series.isEmpty && movies.isEmpty }
}

enum MediaParser {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv", "mpg", "mpeg"]

    /// En dessous de cette taille, un fichier sans numéro d'épisode n'est pas pris pour un film.
    static let minimumMovieSize: Int64 = 300 << 20

    /// Mots qui marquent la fin du titre dans un nom de fichier (qualité, source, codec, langue).
    private static let tags: Set<String> = [
        "multi", "vostfr", "vost", "vff", "vfq", "vf", "vo", "french", "truefrench", "subfrench", "english", "dual",
        "2160p", "1080p", "1080", "720p", "576p", "480p", "4k", "uhd", "hdr", "hdr10", "dv", "sdr",
        "bluray", "bdrip", "brrip", "bdremux", "remux", "web", "webrip", "webdl", "hdtv", "dvdrip", "hdrip", "dvd",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid", "divx", "10bit", "10bits", "8bit",
        "aac", "ac3", "eac3", "dts", "opus", "flac", "truehd", "atmos", "ddp", "dd",
        "integrale", "complete", "repack", "proper", "extended", "unrated", "remastered",
        "amzn", "nf", "dsnp", "atvp", "hmax", "cr",
    ]

    /// Noms de fichier qui ne disent rien du contenu : le titre est alors celui du dossier.
    private static let genericNames: Set<String> = ["movie", "film", "video", "feature", "main", "title", "fichier", "untitled"]

    /// Noms produits par un appareil photo, un téléphone ou un enregistrement d'écran : ni film ni série.
    private static let cameraPattern = try! NSRegularExpression(
        pattern: #"^(img|mvi|dsc|dscf|vid|mov|gopr|gx|gh|pxl|dji|clip)[ _-]?\d{3,}|^(screen recording|enregistrement de l.écran|capture d.écran|zoom_|video-\d|whatsapp video|trim\.)"#,
        options: [.caseInsensitive])

    private static let episodePatterns: [NSRegularExpression] = [
        // S01E02, s01e02, S01.E02, S01 E02
        try! NSRegularExpression(pattern: #"(?<![a-z0-9])s(\d{1,2})[ ._-]?e(\d{1,3})(?!\d)"#, options: [.caseInsensitive]),
        // 1x02
        try! NSRegularExpression(pattern: #"(?<![a-z0-9])(\d{1,2})x(\d{2,3})(?!\d)"#, options: [.caseInsensitive]),
    ]
    /// Numéro d'épisode seul (« Épisode 12 », « - 12 ») : la saison vient alors du dossier.
    private static let bareEpisodePattern = try! NSRegularExpression(
        pattern: #"(?:(?:épisode|episode|ep|e)[ ._-]?(\d{1,3})(?!\d))|(?: - (\d{1,3})(?=[ .\[(]|$))"#, options: [.caseInsensitive])
    private static let seasonFolderPattern = try! NSRegularExpression(
        pattern: #"(?:saison|season)[ ._-]?(\d{1,2})|(?<![a-z0-9])s(\d{1,2})(?![a-z0-9])"#, options: [.caseInsensitive])
    private static let yearPattern = try! NSRegularExpression(pattern: #"(?<!\d)(19[3-9]\d|20[0-4]\d)(?!\d)"#)

    // MARK: Entrée principale

    /// Construit le catalogue à partir de chemins de fichiers et de leur taille.
    static func catalog(files: [(path: String, size: Int64)]) -> LocalCatalog {
        var seriesByKey: [String: (title: String, year: Int?, episodes: [String: LocalEpisode])] = [:]
        var movies: [LocalMovie] = []

        for file in files {
            let url = URL(fileURLWithPath: file.path)
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            guard !matches(cameraPattern, stem), !stem.lowercased().contains("sample") else { continue }
            let folders = Array(url.deletingLastPathComponent().pathComponents.suffix(2))

            if let found = episode(in: stem, folders: folders) {
                let key = normalize(found.series)
                guard !key.isEmpty else { continue }
                var entry = seriesByKey[key] ?? (title: found.series, year: found.year, episodes: [:])
                if entry.year == nil { entry.year = found.year }
                let slot = "\(found.season)-\(found.number)"
                let candidate = LocalEpisode(path: file.path, season: found.season, number: found.number,
                                             title: found.episodeTitle, size: file.size)
                // Deux fichiers pour le même épisode : on garde le plus gros (en pratique la meilleure qualité).
                if let existing = entry.episodes[slot] {
                    if candidate.size > existing.size {
                        entry.episodes[slot] = LocalEpisode(path: candidate.path, season: candidate.season, number: candidate.number,
                                                            title: candidate.title ?? existing.title, size: candidate.size)
                    } else if existing.title == nil, let title = candidate.title {
                        entry.episodes[slot] = LocalEpisode(path: existing.path, season: existing.season, number: existing.number,
                                                            title: title, size: existing.size)
                    }
                } else {
                    entry.episodes[slot] = candidate
                }
                seriesByKey[key] = entry
            } else if file.size >= minimumMovieSize {
                // Un nom de fichier vide de sens (« movie.mkv ») laisse la main au nom du dossier.
                var parsed = titleAndYear(from: stem)
                if parsed.title.count < 3 || genericNames.contains(normalize(parsed.title)), let folder = folders.last {
                    parsed = titleAndYear(from: folder)
                }
                guard parsed.title.count >= 2 else { continue }
                movies.append(LocalMovie(path: file.path, title: parsed.title, year: parsed.year, size: file.size))
            }
        }

        let series = seriesByKey.map { key, value in
            LocalSeries(id: key, title: value.title, year: value.year,
                        episodes: value.episodes.values.sorted { ($0.season, $0.number) < ($1.season, $1.number) })
        }
        return LocalCatalog(
            series: series.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
            movies: movies.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        )
    }

    // MARK: Épisodes

    private struct Found {
        let series: String
        let year: Int?
        let season: Int
        let number: Int
        let episodeTitle: String?
    }

    private static func episode(in stem: String, folders: [String]) -> Found? {
        let range = NSRange(stem.startIndex..., in: stem)
        var season: Int?, number: Int?, matchRange: NSRange?

        for pattern in episodePatterns {
            if let match = pattern.firstMatch(in: stem, range: range) {
                season = Int(text(stem, match.range(at: 1)))
                number = Int(text(stem, match.range(at: 2)))
                matchRange = match.range
                break
            }
        }
        if number == nil, let match = bareEpisodePattern.firstMatch(in: stem, range: range) {
            // Sans saison explicite, il faut que le dossier en indique une : sinon « Film - 2 » serait pris pour un épisode.
            guard let folderSeason = folders.reversed().lazy.compactMap({ seasonNumber(in: $0) }).first else { return nil }
            let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            season = folderSeason
            number = Int(text(stem, group))
            matchRange = match.range
        }
        guard let season, let number, let matchRange, let swiftRange = Range(matchRange, in: stem) else { return nil }

        // Le titre de la série précède le numéro ; à défaut, on le prend dans le nom du dossier.
        var parsed = titleAndYear(from: String(stem[..<swiftRange.lowerBound]))
        for folder in Array(folders.reversed()) where parsed.title.count < 2 || parsed.year == nil {
            // « Saison 1 » ne dit rien du titre : on remonte au dossier parent.
            guard !isOnlySeason(folder) else { continue }
            let fromFolder = titleAndYear(from: folder)
            if parsed.title.count < 2 { parsed.title = fromFolder.title }
            // L'année du dossier ne vaut que s'il désigne bien la même série.
            if parsed.year == nil, normalize(fromFolder.title) == normalize(parsed.title) { parsed.year = fromFolder.year }
        }
        guard parsed.title.count >= 2 else { return nil }

        let after = titleAndYear(from: String(stem[swiftRange.upperBound...])).title
        return Found(series: parsed.title, year: parsed.year, season: season, number: number,
                     episodeTitle: after.count >= 2 ? after : nil)
    }

    /// Numéro de saison indiqué par un nom de dossier (« Saison 4 », « Season 2 », « S03 »).
    private static func seasonNumber(in folder: String) -> Int? {
        guard let match = seasonFolderPattern.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)) else { return nil }
        let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        return Int(text(folder, group))
    }

    /// Vrai pour un dossier qui ne nomme que la saison (« Saison 1 », « S02 »).
    private static func isOnlySeason(_ folder: String) -> Bool {
        let stripped = seasonFolderPattern.stringByReplacingMatches(
            in: folder, range: NSRange(folder.startIndex..., in: folder), withTemplate: "")
        return normalize(stripped).isEmpty
    }

    // MARK: Nettoyage des titres

    /// Extrait un titre lisible et une année d'un fragment de nom de fichier ou de dossier.
    static func titleAndYear(from raw: String) -> (title: String, year: Int?) {
        // Les crochets ne contiennent que des informations techniques.
        var text = raw.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        // Points et tirets bas servent d'espaces dans les noms de fichiers.
        text = text.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)

        var year: Int?
        // L'année de sortie est la dernière du nom. Une année en tout début fait partie du titre
        // (« 2001 l'Odyssée… ») et n'est jamais prise pour une date.
        for match in yearPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  !text[..<range.lowerBound].trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty else { continue }
            year = Int(text[range])
            text = String(text[..<range.lowerBound])
            break
        }

        var kept: [String] = []
        for word in text.split(whereSeparator: { $0 == " " }) {
            let bare = word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let compact = bare.replacingOccurrences(of: "-", with: "")
            if tags.contains(bare) || tags.contains(compact) { break }
            if seasonMarker(bare) { break }
            kept.append(String(word))
        }
        var title = kept.joined(separator: " ")
        title = title.replacingOccurrences(of: #"\(\s*\)"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,(").union(.whitespaces))
        // Une parenthèse entière autour du reste (« (Fin) ») : on garde le contenu.
        if title.hasPrefix("("), title.hasSuffix(")") { title = String(title.dropFirst().dropLast()) }
        if title.hasSuffix(")"), !title.contains("(") { title = String(title.dropLast()) }
        title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return (title.trimmingCharacters(in: .whitespaces), year)
    }

    /// « S01 », « Saison », « Season » : marque de saison, qui clôt le titre de la série.
    private static func seasonMarker(_ word: String) -> Bool {
        word == "saison" || word == "season" || word.range(of: #"^s\d{1,2}$"#, options: .regularExpression) != nil
    }

    /// Clé de regroupement : sans accents, sans ponctuation, en minuscules.
    static func normalize(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func text(_ source: String, _ range: NSRange) -> String {
        Range(range, in: source).map { String(source[$0]) } ?? ""
    }
}
