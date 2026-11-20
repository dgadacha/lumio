import SwiftUI
import Security

// Affiches, images de fond et résumés d'épisodes fournis par TMDB (The Movie Database).
// Les images sont affichées et mises en cache sur ce Mac ; rien n'est redistribué.
// Mention exigée par TMDB : « This product uses the TMDB API but is not endorsed or certified by TMDB. »

// MARK: - Clé (Trousseau)

enum TMDBKeyStore {
    private static let service = "local.lumio.app"
    private static let account = "tmdb-api-key"
    private static let flag = "tmdbKeySaved"
    private static var isTestRun: Bool { ProcessInfo.processInfo.environment["LUMIO_DEBUG"] != nil }

    private static var environmentKey: String? {
        let value = ProcessInfo.processInfo.environment["TMDB_API_KEY"] ?? ""
        return value.isEmpty ? nil : value
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Indique qu'une clé existe, sans lire le Trousseau.
    static var hasKey: Bool {
        if isTestRun { return environmentKey != nil }
        return UserDefaults.standard.bool(forKey: flag) || environmentKey != nil
    }

    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let saved = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        UserDefaults.standard.set(saved, forKey: flag)
        return saved
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: flag)
    }

    static func load() -> String? {
        // Sous le pilote de test, jamais de lecture du Trousseau (signature différente : macOS bloquerait sur une demande d'accès).
        if isTestRun { return environmentKey }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return environmentKey
    }
}

// MARK: - Données

struct EpisodeArt: Codable, Hashable {
    let name: String?
    let overview: String?
    let stillPath: String?
}

/// Ce que TMDB a fourni pour une œuvre. `found` faux : rien de sûr n'a été trouvé, on ne redemande pas.
struct Artwork: Codable, Hashable {
    let found: Bool
    var tmdbID: Int? = nil
    var posterPath: String? = nil
    var backdropPath: String? = nil
    /// Épisodes par saison puis par numéro, chargés à l'ouverture de la fiche.
    var seasons: [String: [String: EpisodeArt]]? = nil
    var fetchedAt = Date()

    static let imageBase = "https://image.tmdb.org/t/p/"
    var posterURL: URL? { posterPath.flatMap { URL(string: Self.imageBase + "w500" + $0) } }
    func backdropURL(large: Bool) -> URL? {
        backdropPath.flatMap { URL(string: Self.imageBase + (large ? "w1280" : "w780") + $0) }
    }
    /// Image d'une carte au format paysage : l'image de fond, à défaut l'affiche.
    var cardURLs: [URL] { [backdropURL(large: false), posterURL].compactMap { $0 } }

    func episode(season: Int, number: Int) -> EpisodeArt? { seasons?["\(season)"]?["\(number)"] }
    static func stillURL(_ path: String?) -> URL? { path.flatMap { URL(string: imageBase + "w300" + $0) } }
}

// MARK: - Client

enum TMDBError: LocalizedError {
    case noKey
    case invalidKey
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Aucune clé TMDB enregistrée."
        case .invalidKey: return "Clé TMDB refusée. Vérifiez-la dans Réglages."
        case .http(let code): return "Erreur \(code) de TMDB."
        }
    }
}

enum TMDBClient {
    /// Toujours l'API de TMDB, sauf sous le pilote de test, qui peut viser un faux serveur local.
    private static let base: String = {
        let env = ProcessInfo.processInfo.environment
        if env["LUMIO_DEBUG"] != nil, let override = env["LUMIO_TMDB_ENDPOINT"],
           let url = URL(string: override), url.host == "127.0.0.1" {
            return override
        }
        return "https://api.themoviedb.org/3"
    }()

    private static func get(_ path: String, _ parameters: [String: String]) async throws -> [String: Any] {
        guard let key = TMDBKeyStore.load() else { throw TMDBError.noKey }
        var components = URLComponents(string: base + path)!
        var items = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        // Deux formes de clé : le jeton d'accès (long, en trois parties) va dans un en-tête,
        // la clé courte de la version 3 dans le paramètre `api_key`.
        let isToken = key.count > 60 && key.contains(".")
        if !isToken { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isToken { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw TMDBError.invalidKey }
        guard status == 200, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TMDBError.http(status)
        }
        return root
    }

    /// Cherche une œuvre et ne renvoie un résultat que s'il est sûr : une mauvaise affiche est pire qu'aucune.
    /// Le titre doit correspondre exactement (accents, casse et ponctuation mis à part) au titre ou au titre
    /// original ; l'année, si elle est connue, doit concorder à un an près. Sans année, il faut que la
    /// correspondance de titre soit unique.
    static func find(title: String, alternateTitle: String?, year: Int?, isSeries: Bool) async throws -> Artwork {
        var parameters = ["query": title, "language": "fr-FR", "include_adult": "false"]
        if let year { parameters[isSeries ? "first_air_date_year" : "primary_release_year"] = "\(year)" }
        var results = (try await get(isSeries ? "/search/tv" : "/search/movie", parameters)["results"] as? [[String: Any]]) ?? []
        // L'année déclarée peut différer d'un an de celle de TMDB : seconde recherche sans filtre.
        if results.isEmpty, year != nil {
            parameters.removeValue(forKey: isSeries ? "first_air_date_year" : "primary_release_year")
            results = (try await get(isSeries ? "/search/tv" : "/search/movie", parameters)["results"] as? [[String: Any]]) ?? []
        }

        let wanted = Set([title, alternateTitle].compactMap { $0 }.map(MediaParser.normalize).filter { !$0.isEmpty })
        let nameKeys = isSeries ? ["name", "original_name"] : ["title", "original_title"]
        let dateKey = isSeries ? "first_air_date" : "release_date"
        func resultYear(_ result: [String: Any]) -> Int? { (result[dateKey] as? String).flatMap { Int($0.prefix(4)) } }

        var matches = results.filter { result in
            nameKeys.contains { key in (result[key] as? String).map { wanted.contains(MediaParser.normalize($0)) } ?? false }
        }
        if let year {
            matches = matches.filter { resultYear($0).map { abs($0 - year) <= 1 } ?? false }
        } else if matches.count > 1 {
            return Artwork(found: false)
        }
        guard let best = matches.max(by: { (($0["popularity"] as? NSNumber)?.doubleValue ?? 0) < (($1["popularity"] as? NSNumber)?.doubleValue ?? 0) }),
              let id = (best["id"] as? NSNumber)?.intValue else { return Artwork(found: false) }
        let poster = best["poster_path"] as? String, backdrop = best["backdrop_path"] as? String
        guard poster != nil || backdrop != nil else { return Artwork(found: false) }
        return Artwork(found: true, tmdbID: id, posterPath: poster, backdropPath: backdrop)
    }

    /// Titres et résumés des épisodes d'une saison.
    static func season(seriesID: Int, number: Int) async throws -> [String: EpisodeArt] {
        let root = try await get("/tv/\(seriesID)/season/\(number)", ["language": "fr-FR"])
        var episodes: [String: EpisodeArt] = [:]
        for episode in (root["episodes"] as? [[String: Any]]) ?? [] {
            guard let index = (episode["episode_number"] as? NSNumber)?.intValue else { continue }
            let name = (episode["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let overview = (episode["overview"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(600)) }
            episodes["\(index)"] = EpisodeArt(name: name, overview: overview, stillPath: episode["still_path"] as? String)
        }
        return episodes
    }
}

// MARK: - Bibliothèque d'affiches

@MainActor
final class ArtworkLibrary: ObservableObject {
    @Published private(set) var items: [String: Artwork] = [:]
    @Published private(set) var loading = false
    @Published var error: String?
    @Published var enabled = UserDefaults.standard.object(forKey: "tmdbEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "tmdbEnabled") }
    }

    private let file = Paths.support.appendingPathComponent("local-artwork.json")
    private var isTestRun: Bool { ProcessInfo.processInfo.environment["LUMIO_DEBUG"] != nil }
    /// Après un échec, plus de tentative automatique jusqu'à une demande explicite ou une relance de l'app.
    private var suspended = false
    private var seasonRequests = Set<String>()

    init() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([String: Artwork].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard !isTestRun, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func artwork(for series: LocalSeries) -> Artwork? { items[series.id].flatMap { $0.found ? $0 : nil } }
    func artwork(for movie: LocalMovie) -> Artwork? { items[LocalLibrary.infoKey(movie)].flatMap { $0.found ? $0 : nil } }

    /// Cherche les affiches manquantes. Seuls le titre et l'année de chaque œuvre sont envoyés à TMDB.
    /// `info` donne le titre original et l'année quand Claude les connaît, ce qui fiabilise la correspondance.
    func fetchMissing(catalog: LocalCatalog, info: [String: MediaInfo], force: Bool = false) async {
        guard enabled, !loading, TMDBKeyStore.hasKey else { return }
        if suspended, !force { return }
        suspended = false
        struct Wanted { let id: String; let title: String; let alternate: String?; let year: Int?; let isSeries: Bool }
        var wanted = catalog.series.map {
            Wanted(id: $0.id, title: $0.title, alternate: info[$0.id]?.originalTitle, year: $0.year ?? info[$0.id]?.year, isSeries: true)
        }
        wanted += catalog.movies.map { movie in
            let key = LocalLibrary.infoKey(movie)
            return Wanted(id: key, title: movie.title, alternate: info[key]?.originalTitle, year: movie.year ?? info[key]?.year, isSeries: false)
        }
        wanted = wanted.filter { force ? items[$0.id]?.found != true : items[$0.id] == nil }
        guard !wanted.isEmpty else { return }

        loading = true
        error = nil
        defer { loading = false }
        for work in wanted {
            do {
                items[work.id] = try await TMDBClient.find(title: work.title, alternateTitle: work.alternate, year: work.year, isSeries: work.isSeries)
            } catch {
                self.error = error.localizedDescription
                suspended = true
                break
            }
        }
        save()
    }

    /// Charge les titres et résumés d'une saison à l'ouverture de la fiche, une seule fois.
    /// Ils ne sont retenus que si la saison de TMDB couvre les numéros d'épisodes présents sur le disque :
    /// un découpage différent (numérotation continue d'un animé, par exemple) donnerait de faux résumés.
    func loadSeason(_ season: Int, of series: LocalSeries) async {
        guard enabled, TMDBKeyStore.hasKey, var art = items[series.id], art.found, let tmdbID = art.tmdbID,
              art.seasons?["\(season)"] == nil else { return }
        let token = "\(series.id)-\(season)"
        guard seasonRequests.insert(token).inserted else { return }
        defer { seasonRequests.remove(token) }
        guard let episodes = try? await TMDBClient.season(seriesID: tmdbID, number: season) else { return }
        let local = series.episodes(in: season).map(\.number)
        let covered = !local.isEmpty && local.allSatisfy { episodes["\($0)"] != nil }
        art = items[series.id] ?? art
        var seasons = art.seasons ?? [:]
        // Une saison non concordante est notée vide, pour ne pas la redemander.
        seasons["\(season)"] = covered ? episodes : [:]
        art.seasons = seasons
        items[series.id] = art
        save()
    }

    func clear() {
        items = [:]
        error = nil
        try? FileManager.default.removeItem(at: file)
    }
}
