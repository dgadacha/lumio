import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var history: WatchHistory
    @EnvironmentObject var local: LocalLibrary
    @EnvironmentObject var artwork: ArtworkLibrary
    @State private var tmdbDraft = ""
    @State private var tmdbSaved = TMDBKeyStore.hasKey
    @AppStorage("downloadDir") private var downloadDir = ""
    @AppStorage("defaultHeight") private var defaultHeight = 1080
    @AppStorage("autoplayNext") private var autoplayNext = true
    @State private var rowsText = ""
    @State private var keyDraft = ""
    @State private var keySaved = APIKeyStore.hasKey
    @State private var keyMessage = ""

    var body: some View {
        PageScaffold(title: "Réglages") {
            card("Téléchargements") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dossier de destination").font(.system(size: 13.5, weight: .semibold))
                        Text(Paths.downloads.path).font(.system(size: 12)).foregroundStyle(Theme.dim).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Choisir…") { chooseFolder() }
                    Button("Ouvrir") {
                        try? FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Paths.downloads)
                    }
                }
                Divider().overlay(Color.white.opacity(0.1))
                VStack(alignment: .leading, spacing: 9) {
                    Text("Résolution proposée par défaut").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 8) {
                        ForEach([2160, 1440, 1080, 720, 480], id: \.self) { height in
                            Chip(label: "\(height)p", detail: VideoDetail.heightTag(height), selected: defaultHeight == height) {
                                defaultHeight = height
                            }
                        }
                    }
                }
            }

            card("Films et séries du disque") {
                Text("Dossiers analysés pour l'onglet Films et séries. Lumio ne fait que lire : vos fichiers ne sont ni déplacés, ni renommés, ni supprimés.")
                    .font(.system(size: 12)).foregroundStyle(Theme.dim)
                VStack(spacing: 6) {
                    ForEach(local.folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.dim)
                            Text(folder).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { local.folders.removeAll { $0 == folder } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Divider().overlay(Color.white.opacity(0.1))
                Toggle(isOn: $autoplayNext) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lecture automatique de l'épisode suivant").font(.system(size: 13.5, weight: .semibold))
                        Text("À la fin d'un épisode, le suivant démarre après un compte à rebours de quelques secondes, annulable.")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                Divider().overlay(Color.white.opacity(0.1))
                Toggle(isOn: $local.describeEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Descriptions rédigées par Claude").font(.system(size: 13.5, weight: .semibold))
                        Text(local.describing ? "Claude rédige les fiches…"
                             : (local.describeError ?? "\(local.info.values.filter(\.known).count) fiche(s) en cache · chaque titre n'est demandé qu'une fois"))
                            .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
                    }
                }
                .toggleStyle(.switch)
                Text("Utilise votre clé API Claude (section ci-dessous). Seuls le titre, l'année et le type (film ou série) de chaque œuvre sont envoyés à l'API d'Anthropic, jamais les noms de fichiers ni les chemins. Les résumés sont écrits de mémoire par le modèle et peuvent contenir des erreurs.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                HStack {
                    Button("Effacer les fiches en cache") { local.clearInfo() }.disabled(local.info.isEmpty)
                    Spacer()
                }
                HStack {
                    Button("Ajouter un dossier…") { addScanFolder() }
                    Button("Rétablir par défaut") { local.folders = LocalLibrary.defaultFolders }
                    Spacer()
                    if local.scanning { ProgressView().controlSize(.small) }
                    Button("Analyser maintenant") { Task { await local.scan() } }.disabled(local.scanning)
                }
            }

            card("Affiches et résumés d'épisodes (TMDB)") {
                Toggle(isOn: $artwork.enabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Affiches, images de fond et résumés d'épisodes").font(.system(size: 13.5, weight: .semibold))
                        Text(artwork.loading ? "Recherche des affiches…"
                             : (artwork.error ?? "\(artwork.items.values.filter(\.found).count) œuvre(s) reconnue(s) sur \(artwork.items.count) cherchée(s)"))
                            .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
                    }
                }
                .toggleStyle(.switch)
                HStack(spacing: 8) {
                    SecureField(tmdbSaved ? "Clé enregistrée dans le Trousseau" : "Clé API ou jeton d'accès TMDB", text: $tmdbDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Enregistrer") {
                        tmdbSaved = TMDBKeyStore.save(tmdbDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        tmdbDraft = ""
                        if tmdbSaved { Task { await state.refreshArtwork(force: true) } }
                    }
                    .disabled(tmdbDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if tmdbSaved {
                        Button("Supprimer") {
                            TMDBKeyStore.delete()
                            tmdbSaved = TMDBKeyStore.hasKey
                        }
                    }
                }
                HStack {
                    Button("Chercher à nouveau") { Task { await state.refreshArtwork(force: true) } }
                        .disabled(!tmdbSaved || artwork.loading)
                    Button("Effacer les affiches en cache") { artwork.clear() }.disabled(artwork.items.isEmpty)
                    Spacer()
                }
                Text("Clé gratuite à créer sur themoviedb.org (Paramètres → API). Seuls le titre et l'année de chaque œuvre sont envoyés à TMDB. Une affiche n'est retenue que si le titre correspond exactement et que l'année concorde ; sinon la vignette tirée du fichier est conservée.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
            }

            card("Espace disque") {
                StoragePanel()
            }

            card("Historique de lecture") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.history.entries.isEmpty ? "Aucune vidéo regardée en streaming"
                             : "\(state.history.entries.count) vidéo(s) regardée(s) en streaming")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("Sert à reprendre la lecture là où vous vous êtes arrêté. Reste sur ce Mac.")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Button("Effacer l'historique") { state.history.clear() }
                        .disabled(state.history.entries.isEmpty)
                }
            }

            card("Moteur de téléchargement") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.engine.version.map { "yt-dlp \($0)" } ?? "Non installé")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(state.engineLog.isEmpty
                             ? (state.engine.managed ? "Copie privée gérée par Lumio" : (state.engine.path ?? "Aucun moteur trouvé"))
                             : state.engineLog)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                    Spacer()
                    if state.engineBusy { ProgressView().controlSize(.small) }
                    Button(state.engine.managed ? "Mettre à jour" : "Installer la dernière version") { state.updateEngine() }
                        .disabled(state.engineBusy)
                }
                Divider().overlay(Color.white.opacity(0.1))
                Toggle(isOn: $state.engineAutoUpdate) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mise à jour automatique").font(.system(size: 13.5, weight: .semibold))
                        Text(state.engineLastCheck.map { "Dernière vérification : \($0.formatted(date: .abbreviated, time: .shortened))" }
                             ?? "Aucune vérification pour l'instant")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                Text("Une fois par jour, quand aucun téléchargement n'est en cours, Lumio vérifie et installe la dernière version de yt-dlp dans son dossier de données, sans toucher au reste du système. ffmpeg doit être présent (Homebrew).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }

            card("Suggestions par Claude") {
                Toggle(isOn: $state.aiEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rangées « Pour vous » sur l'accueil").font(.system(size: 13.5, weight: .semibold))
                        Text("Claude propose trois rangées d'après votre bibliothèque et vos recherches.")
                            .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .toggleStyle(.switch)
                Divider().overlay(Color.white.opacity(0.1))
                HStack(spacing: 8) {
                    SecureField(keySaved ? "Clé enregistrée dans le Trousseau" : "Clé API Anthropic (sk-ant-…)", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Enregistrer") {
                        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        keySaved = APIKeyStore.save(key)
                        keyMessage = keySaved ? "Clé enregistrée dans le Trousseau." : "Impossible d'écrire dans le Trousseau."
                        keyDraft = ""
                        if keySaved { Task { await state.refreshSuggestions(force: true) } }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if keySaved {
                        Button("Supprimer") {
                            APIKeyStore.delete()
                            state.clearSuggestions()
                            keySaved = APIKeyStore.hasKey
                            keyMessage = "Clé supprimée."
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Actualiser les suggestions") { Task { await state.refreshSuggestions(force: true) } }
                        .disabled(!state.aiEnabled || !keySaved || state.aiBusy)
                    if state.aiBusy { ProgressView().controlSize(.small) }
                    Text(state.aiBusy ? "Claude réfléchit…" : (state.aiError ?? keyMessage))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2)
                }
                Text("Désactivé par défaut. Une fois activé, les titres et chaînes de votre bibliothèque et de votre historique de lecture, votre avancement et vos recherches récentes sont envoyés à l'API d'Anthropic (modèle \(ClaudeClient.model)), facturée sur votre clé. Lumio ne rappelle l'API que si votre historique change, au plus une fois par heure. Clé à créer sur console.anthropic.com.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }

            card("Rangées de l'accueil") {
                Text("Une rangée par ligne : Titre | recherche (ou lien de playlist ou de chaîne).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                TextEditor(text: $rowsText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 150)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Enregistrer et recharger") {
                        UserDefaults.standard.set(rowsText, forKey: "homeRows")
                        state.tab = .home
                        Task { await state.loadHome(force: true) }
                    }
                    Button("Rétablir par défaut") {
                        rowsText = AppState.defaultRows
                    }
                }
            }
        }
        .onAppear { rowsText = state.rowsConfig }
    }

    private func addScanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        if panel.runModal() == .OK {
            for url in panel.urls where !local.folders.contains(url.path) { local.folders.append(url.path) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Paths.downloads
        if panel.runModal() == .OK, let url = panel.url {
            downloadDir = url.path
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 17, weight: .bold))
            content()
        }
        .padding(20)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}


// MARK: - Espace disque

/// Ce que Lumio occupe sur le disque, et de quoi en libérer.
/// Seuls les téléchargements de Lumio et son cache peuvent être supprimés d'ici ;
/// les films et séries de l'utilisateur sont en lecture seule.
struct StoragePanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var local: LocalLibrary
    @State private var cacheSize: Int64 = 0
    @State private var confirmWatched = false
    @State private var pendingDelete: LibraryItem?

    private var watched: [LibraryItem] { library.watchedItems }
    private var watchedSize: Int64 { watched.reduce(0) { $0 + $1.size } }
    private var localSize: Int64 {
        local.catalog.series.reduce(0) { $0 + $1.totalSize } + local.catalog.movies.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            line("Téléchargements de Lumio",
                 library.items.isEmpty ? "Aucun" : "\(library.items.count) vidéo(s) · \(Fmt.bytes(library.totalSize))")

            if !library.items.isEmpty {
                VStack(spacing: 4) {
                    ForEach(library.items.sorted { $0.size > $1.size }.prefix(6)) { item in
                        HStack(spacing: 10) {
                            Text(Fmt.bytes(item.size))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 74, alignment: .trailing)
                            Text(item.title).font(.system(size: 12.5)).lineLimit(1)
                            if item.watched == true {
                                Label("Vue", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                            }
                            Spacer()
                            Button { pendingDelete = item } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                                .help("Mettre à la corbeille")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                HStack {
                    Button(watched.isEmpty ? "Aucune vidéo vue à supprimer"
                           : "Mettre à la corbeille les \(watched.count) vidéo(s) vue(s) · \(Fmt.bytes(watchedSize))") {
                        confirmWatched = true
                    }
                    .disabled(watched.isEmpty)
                    Spacer()
                }
                Text("Une vidéo compte comme vue une fois regardée jusqu'au bout. Les suppressions vont dans la corbeille.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }

            Divider().overlay(Color.white.opacity(0.1))
            line("Films et séries du disque", localSize > 0 ? "\(Fmt.bytes(localSize)) · en lecture seule, Lumio n'y touche pas" : "Aucun")

            Divider().overlay(Color.white.opacity(0.1))
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cache").font(.system(size: 13.5, weight: .semibold))
                    Text("\(cacheSize > 0 ? Fmt.bytes(cacheSize) : "Vide") · copies temporaires des MKV, vignettes, sous-titres extraits")
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Vider le cache") {
                    // La copie en cours de lecture est épargnée.
                    LocalTools.clearCache(keeping: state.playing?.url)
                    refreshCacheSize()
                }
                .disabled(cacheSize == 0)
            }
        }
        .onAppear { refreshCacheSize() }
        .confirmationDialog(
            "Mettre à la corbeille \(watched.count) vidéo(s) vue(s), soit \(Fmt.bytes(watchedSize)) ?",
            isPresented: $confirmWatched
        ) {
            Button("Mettre à la corbeille", role: .destructive) { watched.forEach(library.remove) }
        } message: {
            Text("Seuls les téléchargements de Lumio sont concernés. Ils restent récupérables dans la corbeille.")
        }
        .confirmationDialog(
            "Mettre à la corbeille « \(pendingDelete?.title ?? "") » ?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Mettre à la corbeille", role: .destructive) {
                if let item = pendingDelete { library.remove(item) }
                pendingDelete = nil
            }
        } message: {
            Text("\(Fmt.bytes(pendingDelete?.size)) seront libérés une fois la corbeille vidée.")
        }
    }

    private func refreshCacheSize() {
        Task.detached(priority: .utility) {
            let size = LocalTools.cacheSize()
            await MainActor.run { cacheSize = size }
        }
    }

    private func line(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.dim)
        }
    }
}
