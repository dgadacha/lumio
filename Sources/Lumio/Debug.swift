import SwiftUI
import AppKit

/// Pilote de test, inactif en usage normal.
/// Lancer avec `open --env LUMIO_DEBUG=/chemin/script.txt build/Lumio.app` : chaque ligne du script
/// est une commande (wait, snap, tab, search, detail, download, waitdownloads, play, stop, engine, pref, quit).
/// Le journal est écrit dans `<script>.log`.
@MainActor
enum DebugDriver {
    /// Hauteur d'image du flux en cours, renseignée par le lecteur pour la commande `height`.
    static var videoHeight = 0
    /// État détaillé du lecteur en cours, fourni par lui pour la commande `player`.
    static var playerReport: () -> String = { "aucun lecteur" }
    /// Place la lecture à quelques secondes de la fin, pour tester l'enchaînement des épisodes.
    static var playerSeekNearEnd: () -> Void = {}
    static var playerSeekTo: (Double) -> Void = { _ in }
    static var playerToggleMini: () -> Void = {}
    static var playerSelectSubtitle: (Int) -> Void = { _ in }
    /// Affiche les commandes de la petite fenêtre sans survol, le temps d'une capture.
    static var forceMiniControls = false
    static var playerMiniReport: () -> String = { "aucun lecteur" }
    /// Simule le survol de la barre de progression à une position (0 à 1) ; une valeur négative l'arrête.
    static var playerHover: (Double?) -> Void = { _ in }
    /// Ouvre un panneau du lecteur (tracks, episodes, speed, quality) ou le ferme (none).
    static var playerSetPanel: (String) -> Void = { _ in }

    static func startIfRequested(_ state: AppState) {
        guard let path = ProcessInfo.processInfo.environment["LUMIO_DEBUG"],
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let logURL = URL(fileURLWithPath: path + ".log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        func log(_ text: String) {
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write((text + "\n").data(using: .utf8)!)
            try? handle.close()
        }
        Task {
            for line in script.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard let command = parts.first, !command.hasPrefix("#") else { continue }
                let argument = parts.count > 1 ? parts[1] : ""
                switch command {
                case "wait":
                    try? await Task.sleep(nanoseconds: UInt64((Double(argument) ?? 1) * 1_000_000_000))
                case "snap":
                    log("snap \(argument): \(snapshot(to: argument))")
                case "tab":
                    let tabs: [String: AppState.Tab] = ["home": .home, "categories": .categories, "local": .local, "search": .search, "library": .library, "downloads": .downloads, "settings": .settings]
                    if let tab = tabs[argument] { state.tab = tab }
                case "search":
                    state.query = argument
                    state.runSearch()
                    while state.searching { try? await Task.sleep(nanoseconds: 200_000_000) }
                    log("search \(argument): \(state.results.count) résultats, erreur=\(state.searchError ?? "aucune")")
                case "detail":
                    state.detail = argument == "featured" ? state.featured : state.results.first
                    log("detail: \(state.detail?.title ?? "aucune")")
                case "closedetail":
                    state.detail = nil
                case "download":
                    // download <hauteur max> <codec> <sous-titres séparés par des virgules>
                    guard let video = state.detail ?? state.results.first else { log("download: pas de vidéo"); continue }
                    do {
                        let detail = try await state.loadDetail(video)
                        let fields = argument.split(separator: " ").map(String.init)
                        var options = DownloadOptions()
                        if fields.first == "audio" {
                            options.kind = .audio
                        } else {
                            let cap = Int(fields.first ?? "") ?? 360
                            options.height = detail.heights.first { $0 <= cap } ?? detail.heights.last ?? 360
                            options.codec = VCodec(rawValue: fields.count > 1 ? fields[1] : "h264") ?? .h264
                        }
                        if fields.count > 2 {
                            for code in fields[2].split(separator: ",").map(String.init) {
                                if let track = detail.subtitles.first(where: { $0.code == code })
                                    ?? detail.autoSubtitles.first(where: { $0.code == code }) {
                                    options.subtitles.insert(track)
                                }
                            }
                        }
                        log("formats: hauteurs=\(detail.heights) sous-titres=\(detail.subtitles.map(\.code)) auto=\(detail.autoSubtitles.count) langues audio=\(detail.audioLanguages)")
                        log("download: \(options.qualityLabel) subs=\(options.subtitles.map(\.id)) args=\(options.arguments().joined(separator: " "))")
                        state.downloads.enqueue(video: video, detail: detail, options: options)
                    } catch {
                        log("download: erreur \(error.localizedDescription)")
                    }
                case "waitdownloads":
                    var ticks = 0
                    while state.downloads.activeCount > 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        ticks += 1
                        if ticks % 2 == 0, ticks <= 60, let job = state.downloads.jobs.first(where: \.isActive) {
                            log("progression: \(Int(job.fraction * 100)) % — \(job.stage)")
                        }
                    }
                    for job in state.downloads.jobs {
                        log("job \(job.video.title): \(job.state) — \(job.stage)")
                    }
                    for item in state.library.items {
                        log("bibliothèque: \(item.mediaFile) lisible=\(item.playable) taille=\(item.size) subs=\(item.subtitles.map(\.code)) miniature=\(item.thumbFile ?? "aucune")")
                    }
                case "play":
                    if let item = state.library.items.first { state.play(item) }
                    log("play: \(state.playing?.video.title ?? "ouvert à l'extérieur ou rien")")
                case "stop":
                    state.playing = nil
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    log("stop: position=\(state.library.items.first?.position ?? -1)")
                case "click":
                    // click <x> <y> : clic gauche réel dans la fenêtre (points, origine en haut à gauche).
                    let fields = argument.split(separator: " ").compactMap { Double($0) }
                    guard fields.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                        log("click: arguments ou fenêtre manquants"); continue
                    }
                    let point = NSPoint(x: fields[0], y: window.frame.height - fields[1])
                    // L'app doit être active et la fenêtre principale, sinon le premier clic ne fait que l'activer.
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    // Les deux événements partent ensemble dans la file : une vue qui suit la souris
                    // (texte sélectionnable) y trouve le relâchement, au lieu de l'attendre indéfiniment.
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                            pressure: type == .leftMouseDown ? 1 : 0) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    log("click: fenêtre clé=\(window.isKeyWindow) app active=\(NSApp.isActive) hauteur=\(Int(window.frame.height))")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    log("click \(argument): fiche ouverte=\(state.detail != nil) lecteur=\(state.playing != nil) onglet=\(state.tab)")
                case "height":
                    log("height: \(videoHeight)p à \(argument)")
                case "artoverview":
                    // Récupère les descriptions manquantes (faux serveur), puis les journalise.
                    log("artoverview: manquantes avant=\(state.artwork.missingOverviews)")
                    await state.artwork.fetchOverviews()
                    log("artoverview: manquantes après=\(state.artwork.missingOverviews) erreur=\(state.artwork.error ?? "aucune")")
                    for (id, art) in state.artwork.items.sorted(by: { $0.key < $1.key }) where art.found {
                        log("  \(id): description=\(art.overview.map { "\($0.count) caractères" } ?? "absente")")
                    }
                case "artnone":
                    // artnone <identifiant> : « aucune affiche » choisi à la main, puis recherche forcée.
                    state.artwork.chooseNone(for: argument)
                    await state.refreshArtwork(force: true)
                    let art = state.artwork.items[argument]
                    log("artnone \(argument): trouvée=\(art?.found ?? true) manuel=\(art?.manual ?? false) (doit rester false/true après recherche forcée)")
                case "artpick":
                    // artpick <identifiant> <recherche> : recherche libre puis choix du premier résultat (faux serveur).
                    let fields = argument.split(separator: " ", maxSplits: 1).map(String.init)
                    guard fields.count == 2 else { log("artpick: arguments manquants"); continue }
                    do {
                        let found = try await TMDBClient.candidates(query: fields[1], isSeries: true)
                        log("artpick: \(found.count) proposition(s) : \(found.map { "\($0.name) (\($0.year.map(String.init) ?? "?"))" })")
                        if let first = found.first { state.artwork.choose(first, for: fields[0]) }
                        let art = state.artwork.items[fields[0]]
                        log("artpick: retenue=\(art?.found ?? false) id=\(art?.tmdbID.map(String.init) ?? "-") manuel=\(art?.manual ?? false)")
                    } catch { log("artpick: erreur \(error.localizedDescription)") }
                case "artwork":
                    // Cherche les affiches. À n'utiliser qu'avec LUMIO_TMDB_ENDPOINT (faux serveur) et TMDB_API_KEY factice.
                    await state.refreshArtwork(force: true)
                    log("artwork: cherchées=\(state.artwork.items.count) reconnues=\(state.artwork.items.values.filter(\.found).count) erreur=\(state.artwork.error ?? "aucune")")
                    for (id, art) in state.artwork.items.sorted(by: { $0.key < $1.key }) {
                        log("  \(id): trouvée=\(art.found) id=\(art.tmdbID.map(String.init) ?? "-") affiche=\(art.posterPath ?? "-") fond=\(art.backdropPath ?? "-") saisons=\(art.seasons?.mapValues(\.count) ?? [:])")
                    }
                case "datacheck":
                    // Ce que l'app a relu des fichiers de données réels, à comparer à leur contenu brut.
                    log("datacheck: bibliothèque=\(state.library.items.count) historique=\(state.history.entries.count) positions=\(state.local.positions.count) fiches=\(state.local.info.count) séries=\(state.local.catalog.series.count) accueil=\(state.rows.count) suggestions=\(state.aiRows.count) plus-tard=\(state.watchLater.videos.count) abonnements=\(state.subscriptions.channels.count)")
                case "follow":
                    // follow <identifiant> <nom> : suit une chaîne (en mémoire seulement sous le pilote de test).
                    let fields = argument.split(separator: " ", maxSplits: 1).map(String.init)
                    if fields.count == 2 { state.subscriptions.toggle(id: fields[0], name: fields[1]) }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    while state.subscriptions.loading { try? await Task.sleep(nanoseconds: 300_000_000) }
                    log("follow: chaînes=\(state.subscriptions.channels.map(\.name)) fil=\(state.subscriptions.feed.count) erreur=\(state.subscriptions.error ?? "aucune")")
                    for video in state.subscriptions.feed.prefix(4) {
                        log("  \(video.publishedAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "sans date") | \(video.channel ?? "-") | \(video.title.prefix(40))")
                    }
                case "later":
                    // Ajoute à « À regarder plus tard » les deux premiers résultats de la recherche en cours.
                    for video in state.results.prefix(2) { state.watchLater.toggle(video) }
                    log("later: \(state.watchLater.videos.count) vidéo(s), identifiants de chaîne présents=\(state.results.prefix(2).allSatisfy { $0.channelID != nil })")
                case "localscan":
                    await state.local.scan()
                    let catalog = state.local.catalog
                    log("localscan: \(catalog.series.count) séries, \(catalog.movies.count) films, refusés=\(state.local.denied.count)")
                    for series in catalog.series {
                        log("  série: \(series.id) saisons=\(series.seasons) épisodes=\(series.episodes.count)")
                    }
                case "localmeta":
                    // Demande les fiches manquantes. À n'utiliser qu'avec LUMIO_CLAUDE_ENDPOINT (faux serveur).
                    await state.local.fetchMissingInfo()
                    log("localmeta: fiches=\(state.local.info.count) reconnues=\(state.local.info.values.filter(\.known).count) erreur=\(state.local.describeError ?? "aucune")")
                    for (id, info) in state.local.info.sorted(by: { $0.key < $1.key }) {
                        log("  \(id): reconnue=\(info.known) genres=\(info.genres) année=\(info.year.map(String.init) ?? "-") texte=\(info.synopsis.count) caractères")
                    }
                case "localseries":
                    // localseries <clé> : ouvre la page d'une série.
                    state.tab = .local
                    state.localSeries = state.local.catalog.series.first { $0.id == argument }
                    log("localseries \(argument): \(state.localSeries == nil ? "introuvable" : "ouverte")")
                case "localplay":
                    // localplay <clé> <saison> <épisode> : lit un épisode. Les positions ne sont pas écrites
                    // sous le pilote de test (voir LocalLibrary.record).
                    let fields = argument.split(separator: " ").map(String.init)
                    guard fields.count == 3, let series = state.local.catalog.series.first(where: { $0.id == fields[0] }),
                          let episode = series.episodes.first(where: { $0.season == Int(fields[1]) && $0.number == Int(fields[2]) }) else {
                        log("localplay: épisode introuvable"); continue
                    }
                    let started = Date()
                    await state.playLocal(path: episode.path)
                    log("localplay: lecture=\(state.playing?.video.title ?? "aucune") détail=\(state.playing?.detailLine ?? "") préparé en \(String(format: "%.1f", Date().timeIntervalSince(started))) s sous-titres=\(state.playing?.subtitles.map(\.label) ?? []) suivant=\(state.playing?.nextLocalPath != nil) erreur=\(state.streamError ?? "aucune")")
                case "panel":
                    playerSetPanel(argument)
                case "hover":
                    let value = Double(argument) ?? -1
                    playerHover(value < 0 ? nil : value)
                case "subtitle":
                    playerSelectSubtitle(Int(argument) ?? 0)
                case "minimouse":
                    // minimouse <x1> <x2> <y depuis le bas> : clic (x1 = x2) ou glisser dans la petite fenêtre,
                    // en points, sans activer l'app. Rapporte le temps de lecture et le cadre de la fenêtre.
                    let values = argument.split(separator: " ").compactMap { Double($0) }
                    guard values.count == 3, let panel = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel && $0.level == .floating }) else {
                        log("minimouse: arguments ou petite fenêtre manquants"); continue
                    }
                    forceMiniControls = true
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let before = panel.frame
                    func event(_ type: NSEvent.EventType, _ x: Double) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: values[2]), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                    }
                    var sequence: [NSEvent?] = [event(.leftMouseDown, values[0])]
                    if values[0] != values[1] {
                        for step in 1...6 { sequence.append(event(.leftMouseDragged, values[0] + (values[1] - values[0]) * Double(step) / 6)) }
                    }
                    sequence.append(event(.leftMouseUp, values[1]))
                    for item in sequence.compactMap({ $0 }) {
                        NSApp.postEvent(item, atStart: false)
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    forceMiniControls = false
                    let moved = panel.frame != before
                    log("minimouse \(argument): \(playerMiniReport()) | fenêtre déplacée=\(moved) cadre=\(Int(panel.frame.minX)),\(Int(panel.frame.minY)) \(Int(panel.frame.width))x\(Int(panel.frame.height)) app active=\(NSApp.isActive)")
                case "snapmini":
                    // Capture de la petite fenêtre du lecteur réduit (commandes affichées de force).
                    forceMiniControls = true
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel && $0.level == .floating }) {
                        log("snapmini: \(snapshot(window: panel, to: argument)) fenêtre \(Int(panel.frame.width))x\(Int(panel.frame.height))")
                    } else { log("snapmini: aucune petite fenêtre") }
                    forceMiniControls = false
                case "mini":
                    // Bascule le lecteur réduit, puis rapporte son état.
                    if argument != "état" { playerToggleMini() }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    log("mini \(argument): [\(state.playing?.detailLine ?? "aucun lecteur")] \(playerMiniReport()) | lecteur masqué=\(state.playerMinimized) fenêtres de l'app=\(NSApp.windows.filter(\.isVisible).count)")
                    // Détail des fenêtres visibles : type, taille, niveau (une fenêtre flottante a un niveau élevé).
                    for window in NSApp.windows where window.isVisible {
                        log("    fenêtre \(String(describing: type(of: window))) \(Int(window.frame.width))x\(Int(window.frame.height)) niveau=\(window.level.rawValue) titre=\(window.title.isEmpty ? "-" : window.title)")
                    }
                case "seekto":
                    playerSeekTo(Double(argument) ?? 0)
                case "seekend":
                    playerSeekNearEnd()
                case "player":
                    log("player \(argument): [\(state.playing?.video.title ?? "-") — \(state.playing?.detailLine ?? "-")] \(playerReport())")
                case "localresume":
                    // localresume <clé> : ce que la page de la série proposerait, d'après les positions relues du disque.
                    guard let series = state.local.catalog.series.first(where: { $0.id == argument }) else { log("localresume: série introuvable"); continue }
                    let next = state.local.nextUp(in: series)
                    let saved = next.flatMap { state.local.position(for: $0.path) }
                    log("localresume \(argument): positions relues=\(state.local.positions.count) à reprendre=S\(next?.season ?? 0):É\(next?.number ?? 0) position=\(saved.map { String(format: "%.1f", $0.position) } ?? "absente") en cours=\(state.local.inProgress.count)")
                case "localstop":
                    let path = state.playing?.localPath
                    state.playing = nil
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let saved = path.flatMap({ state.local.position(for: $0) }) {
                        log("localstop: position=\(String(format: "%.1f", saved.position)) durée=\(String(format: "%.0f", saved.duration))")
                    } else {
                        log("localstop: aucune position enregistrée")
                    }
                case "watch":
                    // Lecture en streaming de la vidéo de la fiche ouverte, ou du premier résultat.
                    guard let video = state.detail ?? state.results.first else { log("watch: pas de vidéo"); continue }
                    await state.watch(video)
                    log("watch: lecture=\(state.playing?.video.title ?? "aucune") flux=\(state.playing?.isStream ?? false) sous-titres=\(state.playing?.subtitles.map(\.code) ?? []) reprise=\(Int(state.playing?.startPosition ?? 0)) erreur=\(state.streamError ?? "aucune")")
                case "stopstream":
                    state.playing = nil
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    log("stopstream: position=\(state.history.entries.first?.position ?? -1) entrées=\(state.history.entries.count)")
                case "autoupdate":
                    // Simule une vérification due : remet la date à zéro puis laisse l'app décider.
                    state.engineLastCheck = nil
                    log("autoupdate: activée=\(state.engineAutoUpdate) avant=\(state.engine.version ?? "aucun")")
                    await state.autoUpdateEngineIfDue()
                    log("autoupdate: après=\(state.engine.version ?? "aucun") vérifié=\(state.engineLastCheck != nil) — \(state.engineLog)")
                    let stamp = state.engineLastCheck
                    await state.autoUpdateEngineIfDue()
                    log("autoupdate: seconde passe sans effet=\(stamp == state.engineLastCheck)")
                case "engine":
                    state.updateEngine()
                    while state.engineBusy { try? await Task.sleep(nanoseconds: 500_000_000) }
                    log("engine: \(state.engine) — \(state.engineLog)")
                case "pref":
                    let fields = argument.split(separator: " ").map(String.init)
                    if fields.count == 2 { UserDefaults.standard.set(fields[1], forKey: fields[0]) }
                case "resize":
                    let fields = argument.split(separator: " ").compactMap { Double($0) }
                    if fields.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                        window.setFrame(NSRect(x: 0, y: 0, width: fields[0], height: fields[1]), display: true)
                    }
                case "cancel":
                    if let job = state.downloads.jobs.first(where: \.isActive) {
                        let folder = job.folder
                        state.downloads.cancel(job)
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        log("cancel: état=\(job.state) dossier présent=\(FileManager.default.fileExists(atPath: folder.path))")
                    } else { log("cancel: aucun téléchargement actif") }
                case "allcategories":
                    // Charge chaque catégorie et signale les rangées vides ou en échec.
                    for category in Category.all {
                        await state.loadCategory(category, force: false)
                        let rows = state.categoryRows[category.id] ?? []
                        let missing = category.rows.count - rows.count
                        log("catégorie \(category.id): \(rows.count)/\(category.rows.count) rangées, \(rows.map { String($0.items.count) }.joined(separator: "+")) vidéos\(missing > 0 ? " — MANQUE \(missing)" : "")\(state.categoryErrors[category.id].map { " — ERREUR \($0)" } ?? "")")
                    }
                case "query":
                    state.query = argument
                case "category":
                    if let category = Category.all.first(where: { $0.id == argument }) {
                        state.open(category)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        while state.categoryLoading.contains(category.id) { try? await Task.sleep(nanoseconds: 300_000_000) }
                        for row in state.categoryRows[category.id] ?? [] {
                            log("catégorie \(category.id): \(row.title) — \(row.items.count) vidéos")
                        }
                        log("catégorie \(category.id): erreur=\(state.categoryErrors[category.id] ?? "aucune")")
                    } else { log("catégorie inconnue : \(argument)") }
                case "keychain":
                    // Aller-retour dans le Trousseau avec une valeur factice ; seul le résultat est journalisé.
                    let had = UserDefaults.standard.bool(forKey: "aiKeySaved")
                    if had {
                        log("keychain: une clé existe déjà, test ignoré pour ne pas l'écraser")
                    } else {
                        let probe = "valeur-factice-\(UUID().uuidString)"
                        let saved = APIKeyStore.save(probe)
                        let matches = APIKeyStore.load() == probe
                        APIKeyStore.delete()
                        log("keychain: écriture=\(saved) relecture identique=\(matches) supprimée=\(APIKeyStore.load() == nil)")
                    }
                case "ai":
                    // Force une actualisation des suggestions. La clé n'est jamais journalisée.
                    state.aiEnabled = true
                    let profile = state.tasteProfile
                    log("ai: profil=\(profile.watched.count) titres, \(profile.searches.count) recherches, clé=\(APIKeyStore.hasKey)")
                    await state.refreshSuggestions(force: true)
                    while state.aiBusy { try? await Task.sleep(nanoseconds: 300_000_000) }
                    log("ai: erreur=\(state.aiError ?? "aucune")")
                    for row in state.aiRows {
                        log("ai rangée: \(row.title) | \(row.query) | \(row.items.count) vidéos | \(row.reason ?? "")")
                    }
                case "quit":
                    NSApp.terminate(nil)
                default:
                    log("commande inconnue : \(command)")
                }
            }
            log("fin")
        }
    }

    private static func snapshot(to path: String) -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }) else { return "pas de fenêtre" }
        return snapshot(window: window, to: path)
    }

    private static func snapshot(window: NSWindow, to path: String) -> String {
        // Capture de notre propre fenêtre par le serveur de fenêtres (inclut les calques et la vidéo).
        // L'API est masquée dans le SDK récent mais toujours présente : on la résout à l'exécution.
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return "API absente" }
        let capture = unsafeBitCast(symbol, to: CaptureFn.self)
        // .null = cadre de la fenêtre ; 8 = optionIncludingWindow ; 1 = boundsIgnoreFraming.
        guard let image = capture(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { return "capture refusée" }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "échec PNG" }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return "ok \(rep.pixelsWide)x\(rep.pixelsHigh)"
        } catch {
            return error.localizedDescription
        }
    }
}
