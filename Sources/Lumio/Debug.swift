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
                    let tabs: [String: AppState.Tab] = ["home": .home, "categories": .categories, "search": .search, "library": .library, "downloads": .downloads, "settings": .settings]
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
                case "height":
                    log("height: \(videoHeight)p à \(argument)")
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
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return "pas de fenêtre" }
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
