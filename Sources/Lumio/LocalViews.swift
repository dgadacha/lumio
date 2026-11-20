import SwiftUI

// Onglet « Films et séries » : ce que l'analyse des dossiers a trouvé sur le disque.

// MARK: - Accueil de l'onglet

struct LocalLibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary
    @EnvironmentObject var artwork: ArtworkLibrary

    private var subtitle: String {
        if local.scanning { return "Analyse des dossiers en cours…" }
        var parts: [String] = []
        if !local.catalog.series.isEmpty { parts.append("\(local.catalog.series.count) série(s)") }
        if !local.catalog.movies.isEmpty { parts.append("\(local.catalog.movies.count) film(s)") }
        if let date = local.lastScan { parts.append("analysé \(date.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        PageScaffold(title: "Films et séries", subtitle: subtitle) {
            HStack(spacing: 10) {
                Button { Task { await local.scan() } } label: {
                    Label(local.scanning ? "Analyse…" : "Analyser les dossiers", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle(fill: Color.white.opacity(0.14), text: .white))
                .disabled(local.scanning)
                if local.scanning { ProgressView().controlSize(.small) }
                Text(local.folders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
            }

            if !local.denied.isEmpty { deniedBanner }

            if local.catalog.isEmpty {
                if !local.scanning {
                    EmptyState(
                        symbol: "externaldrive",
                        title: local.lastScan == nil ? "Vos films et séries, rangés tout seuls" : "Aucun film ni série trouvé",
                        message: "Lumio parcourt les dossiers choisis, repère les épisodes d'après leur nom (S01E02, « Saison 1 »…) et les regroupe par série et par saison. Vos fichiers ne sont ni déplacés ni modifiés.",
                        actionTitle: "Analyser maintenant") { Task { await local.scan() } }
                }
            } else {
                let resume = local.inProgress
                if !resume.isEmpty {
                    section("Reprendre") {
                        ForEach(resume.prefix(8), id: \.path) { row in
                            LocalCard(path: row.path, title: row.title, subtitle: row.detail, progress: row.position.progress,
                                      symbol: "play.circle.fill") { Task { await state.playLocal(path: row.path) } }
                        }
                    }
                }
                if !local.catalog.series.isEmpty {
                    section("Séries") {
                        ForEach(local.catalog.series) { series in
                            let count = series.episodes.count
                            let seasons = series.seasons.count
                            LocalCard(path: series.episodes.first?.path ?? "", title: series.title,
                                      subtitle: [series.year.map(String.init), seasons > 1 ? "\(seasons) saisons" : nil,
                                                 "\(count) épisode\(count > 1 ? "s" : "")"].compactMap { $0 }.joined(separator: " · "),
                                      preferCover: true, symbol: "rectangle.stack.fill",
                                      artURLs: artwork.artwork(for: series)?.cardURLs ?? []) { state.localSeries = series }
                        }
                    }
                }
                if !local.catalog.movies.isEmpty {
                    section("Films") {
                        ForEach(local.catalog.movies) { movie in
                            LocalCard(path: movie.path, title: movie.title,
                                      subtitle: [movie.year.map(String.init), Fmt.bytes(movie.size)].compactMap { $0 }.joined(separator: " · "),
                                      progress: local.position(for: movie.path)?.progress, preferCover: true,
                                      symbol: "info.circle.fill",
                                      artURLs: artwork.artwork(for: movie)?.cardURLs ?? []) { state.localMovie = movie }
                        }
                    }
                }
            }
        }
        .task {
            // À l'ouverture de l'onglet, on analyse sans attendre un clic si l'index est absent ou
            // a plus de dix minutes : un épisode tout juste téléchargé apparaît de lui-même.
            let stale = local.lastScan.map { Date().timeIntervalSince($0) > 600 } ?? true
            if stale, !local.scanning { await local.scan() }
            // Les affiches se cherchent après l'analyse, quand titres et années sont connus.
            if ProcessInfo.processInfo.environment["LUMIO_DEBUG"] == nil { await state.refreshArtwork() }
        }
    }

    private var deniedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("macOS a refusé l'accès à : \(local.denied.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")
                    .font(.system(size: 13.5, weight: .bold))
                Text("Autorisez Lumio dans Réglages Système → Confidentialité et sécurité → Fichiers et dossiers, puis relancez l'analyse.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button("Ouvrir les réglages") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.35)))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 19, weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)], alignment: .leading, spacing: 24) {
                content()
            }
        }
        .padding(.top, 6)
    }
}

/// Carte d'un film, d'une série ou d'un épisode en cours, avec sa vignette extraite du fichier.
struct LocalCard: View {
    let path: String
    let title: String
    let subtitle: String
    var progress: Double? = nil
    var preferCover = false
    var symbol = "play.circle.fill"
    /// Image fournie par TMDB ; à défaut, la vignette est tirée du fichier.
    var artURLs: [URL] = []
    let action: () -> Void
    @EnvironmentObject var state: AppState
    @State private var hover = false

    var body: some View {
        let preparing = state.localPreparing == path
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    // La vignette tirée du fichier reste dessous : si l'image de TMDB ne se charge pas
                    // (hors connexion), la carte n'est jamais vide.
                    .overlay(LocalThumb(path: path, preferCover: preferCover))
                    .overlay { if !artURLs.isEmpty { RemoteImage(urls: artURLs, placeholder: .clear) } }
                    .overlay(Color.black.opacity(hover || preparing ? 0.32 : 0))
                    .overlay {
                        if preparing {
                            ProgressView().controlSize(.regular)
                        } else {
                            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.white)
                                .shadow(radius: 8).opacity(hover ? 1 : 0)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Color.white.opacity(0.3)
                                    Theme.accent.frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(hover ? 0.7 : 0), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.05 : 1)
        .zIndex(hover ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }
}

// MARK: - Fiche d'une série ou d'un film

/// Ce que la fiche présente.
enum LocalItem: Hashable {
    case series(LocalSeries)
    case movie(LocalMovie)

    var id: String {
        switch self {
        case .series(let series): return series.id
        case .movie(let movie): return movie.path
        }
    }
}

/// Fiche en surimpression : bandeau, lecture, synopsis rédigé par Claude, puis saisons et épisodes.
/// Se ferme par la croix, la touche Échap ou un clic en dehors du panneau.
struct LocalDetailOverlay: View {
    let item: LocalItem
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary
    @State private var season: Int?
    @State private var audioLanguages: [String] = []
    @EnvironmentObject var artwork: ArtworkLibrary
    @State private var picking = false

    private var art: Artwork? {
        switch item {
        case .series(let series): return artwork.artwork(for: series)
        case .movie(let movie): return artwork.artwork(for: movie)
        }
    }

    private func close() {
        state.localSeries = nil
        state.localMovie = nil
    }

    private var title: String {
        switch item {
        case .series(let series): return series.title
        case .movie(let movie): return movie.title
        }
    }

    private var info: MediaInfo? {
        switch item {
        case .series(let series): return local.info(for: series)
        case .movie(let movie): return local.info(for: movie)
        }
    }

    private var isSeries: Bool {
        if case .series = item { return true }
        return false
    }

    private var infoKey: String {
        switch item {
        case .series(let series): return series.id
        case .movie(let movie): return LocalLibrary.infoKey(movie)
        }
    }

    /// Fichier dont on tire le décor et qui sera lu par le bouton principal.
    private var mainPath: String? {
        switch item {
        case .series(let series): return local.nextUp(in: series)?.path ?? series.episodes.first?.path
        case .movie(let movie): return movie.path
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.72).ignoresSafeArea().onTapGesture { close() }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        VStack(alignment: .leading, spacing: 24) {
                            about
                            if picking {
                                ArtworkPicker(title: title, isSeries: isSeries, key: infoKey) { picking = false }
                            }
                            if case .series(let series) = item {
                                Divider().overlay(Color.white.opacity(0.12))
                                episodes(of: series)
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 10)
                        .padding(.bottom, 34)
                    }
                    .frame(width: 880)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.7), radius: 40, y: 20)
                    // Un clic dans le panneau ne doit pas remonter jusqu'à la zone qui ferme la fiche.
                    .onTapGesture {}
                    .padding(.vertical, 44)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                }
            }
        }
        .onExitCommand { close() }
        .task(id: item.id) {
            if let path = mainPath, let probe = await MediaInspector.shared.probe(path) {
                var seen = Set<String>()
                audioLanguages = probe.audio.compactMap(\.language).map(Fmt.language).filter { seen.insert($0).inserted }
            }
        }
    }

    // MARK: Bandeau

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            if let path = mainPath {
                LocalThumb(path: path)
            } else {
                Theme.surface2
            }
            if let backdrop = art?.backdropURL(large: true) {
                RemoteImage(urls: [backdrop], placeholder: .clear)
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .center)
            LinearGradient(colors: [.clear, Theme.surface.opacity(0.55), Theme.surface], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 34, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                playButton
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 22)
        }
        .frame(height: 440)
        .clipped()
        .overlay(alignment: .topTrailing) {
            IconButton(symbol: "xmark", size: 14) { close() }.padding(16)
        }
    }

    @ViewBuilder
    private var playButton: some View {
        switch item {
        case .series(let series):
            if let next = local.nextUp(in: series) {
                let started = series.episodes.contains { local.position(for: $0.path) != nil }
                HStack(spacing: 12) {
                    mainButton(path: next.path, label: started ? "Reprendre S\(next.season) : É\(next.number)" : "Lecture")
                    if started {
                        Text(next.label).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    }
                }
            }
        case .movie(let movie):
            let resume = local.position(for: movie.path).map { $0.progress != nil && !$0.finished } ?? false
            mainButton(path: movie.path, label: resume ? "Reprendre" : "Lecture")
        }
    }

    private func mainButton(path: String, label: String) -> some View {
        Button { Task { await state.playLocal(path: path) } } label: {
            HStack(spacing: 8) {
                if state.localPreparing == path { ProgressView().controlSize(.small).tint(.black) }
                else { Image(systemName: "play.fill") }
                Text(label)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(state.localPreparing != nil)
    }

    // MARK: À propos

    private var about: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let year = year {
                        Text(String(year)).foregroundStyle(.green).fontWeight(.bold)
                    }
                    ForEach(facts, id: \.self) { fact in Text(fact) }
                }
                .font(.system(size: 13.5))

                synopsis
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                if let genres = info?.genres, !genres.isEmpty {
                    sideLine("Genres", genres.joined(separator: ", "))
                }
                if let original = info?.originalTitle {
                    sideLine("Titre original", original)
                }
                if !audioLanguages.isEmpty {
                    sideLine("Audio", audioLanguages.joined(separator: ", "))
                }
                sideLine("Taille", Fmt.bytes(totalSize))
                if let poster = art?.posterURL {
                    // Rien ne s'affiche tant que l'affiche n'est pas chargée : pas de cadre vide hors connexion.
                    OptionalRemoteImage(url: poster, size: CGSize(width: 130, height: 195)) {
                        Text("Images : TMDB").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                    .padding(.top, 6)
                }
                // Choix manuel : pour une œuvre non trouvée, ou reconnue à tort.
                if artwork.enabled, TMDBKeyStore.hasKey {
                    Button(picking ? "Fermer le choix" : (art == nil ? "Choisir l'affiche…" : "Changer d'affiche…")) { picking.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 4)
                }
            }
            .frame(width: 250, alignment: .leading)
        }
    }

    private var year: Int? {
        switch item {
        case .series(let series): return series.year ?? info?.year
        case .movie(let movie): return movie.year ?? info?.year
        }
    }

    private var facts: [String] {
        switch item {
        case .series(let series):
            let seasons = series.seasons.count
            return [seasons > 1 ? "\(seasons) saisons" : "1 saison", "\(series.episodes.count) épisodes"]
        case .movie(let movie):
            return [URL(fileURLWithPath: movie.path).pathExtension.uppercased()]
        }
    }

    private var totalSize: Int64 {
        switch item {
        case .series(let series): return series.totalSize
        case .movie(let movie): return movie.size
        }
    }

    @ViewBuilder
    private var synopsis: some View {
        if let info, info.known {
            Text(info.synopsis)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.88))
                .lineSpacing(4)
                .textSelection(.enabled)
            Label("Résumé rédigé par Claude, de mémoire : il peut contenir des erreurs.", systemImage: "sparkles")
                .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
        } else if local.describing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Claude rédige la description…").font(.system(size: 13)).foregroundStyle(Theme.dim)
            }
        } else if let error = local.describeError {
            synopsisNote(error, action: "Réessayer")
        } else if info != nil {
            synopsisNote("Claude n'a pas reconnu ce titre avec certitude, et n'a donc rien rédigé.", action: "Redemander")
        } else if !local.describeEnabled {
            Text("Les descriptions par Claude sont désactivées dans Réglages.")
                .font(.system(size: 13)).foregroundStyle(Theme.dim)
        } else if !APIKeyStore.hasKey {
            Text("Ajoutez une clé API Claude dans Réglages pour obtenir une description.")
                .font(.system(size: 13)).foregroundStyle(Theme.dim)
        } else {
            synopsisNote("Pas encore de description.", action: "Demander à Claude")
        }
    }

    private func synopsisNote(_ text: String, action: String) -> some View {
        HStack(spacing: 12) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.dim)
            Button(action) { Task { await local.fetchMissingInfo(refresh: [infoKey]) } }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white)
        }
    }

    private func sideLine(_ label: String, _ value: String) -> some View {
        (Text("\(label) : ").foregroundStyle(Theme.faint) + Text(value).foregroundStyle(.white.opacity(0.85)))
            .font(.system(size: 12.5))
            .lineLimit(3)
    }

    // MARK: Épisodes

    private func episodes(of series: LocalSeries) -> some View {
        let shown = season ?? local.nextUp(in: series)?.season ?? series.seasons.first ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Épisodes").font(.system(size: 21, weight: .bold))
                Spacer()
                if series.seasons.count > 1 {
                    Menu {
                        ForEach(series.seasons, id: \.self) { number in
                            Button("Saison \(number) (\(series.episodes(in: number).count) épisodes)") { season = number }
                        }
                    } label: {
                        Text("Saison \(shown)").font(.system(size: 14, weight: .semibold))
                    }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                } else {
                    Text("Saison \(shown)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.dim)
                }
            }
            VStack(spacing: 2) {
                ForEach(series.episodes(in: shown)) { episode in
                    LocalEpisodeRow(series: series, episode: episode,
                                    art: art?.episode(season: episode.season, number: episode.number))
                }
            }
        }
        // Titres et résumés des épisodes, demandés à TMDB à l'ouverture de la saison puis gardés en cache.
        // L'identifiant de l'œuvre fait partie de la clé : après un choix manuel, les épisodes se rechargent.
        .task(id: "\(series.id)-\(shown)-\(art?.tmdbID ?? 0)") {
            await artwork.loadSeason(shown, of: series)
        }
    }
}

struct LocalEpisodeRow: View {
    let series: LocalSeries
    let episode: LocalEpisode
    /// Titre et résumé fournis par TMDB, s'ils existent pour cet épisode.
    var art: EpisodeArt? = nil
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary
    @State private var hover = false
    @State private var duration: Double = 0

    var body: some View {
        let position = local.position(for: episode.path)
        let preparing = state.localPreparing == episode.path
        Button { Task { await state.playLocal(path: episode.path) } } label: {
            HStack(spacing: 18) {
                Text("\(episode.number)")
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.dim)
                    .frame(width: 44)

                Color.clear
                    .frame(width: 176, height: 99)
                    .overlay(LocalThumb(path: episode.path))
                    .overlay(Color.black.opacity(hover || preparing ? 0.35 : 0))
                    .overlay {
                        if preparing { ProgressView().controlSize(.regular) }
                        else { Image(systemName: "play.circle.fill").font(.system(size: 34)).opacity(hover ? 1 : 0) }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = position?.progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Color.white.opacity(0.3)
                                    Theme.accent.frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(episode.title ?? art?.name ?? episode.label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if position?.finished == true {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                        }
                    }
                    Text([duration > 0 ? Fmt.longDuration(duration) : nil, Fmt.bytes(episode.size),
                          URL(fileURLWithPath: episode.path).pathExtension.uppercased()]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                    if let overview = art?.overview {
                        Text(overview)
                            .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
                            .lineLimit(3).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.localPreparing != nil)
        .onHover { hover = $0 }
        .task(id: episode.path) { duration = await MediaInspector.shared.probe(episode.path)?.duration ?? 0 }
        .contextMenu {
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: episode.path)])
            }
        }
    }
}


// MARK: - Choix manuel de l'œuvre chez TMDB

/// Recherche libre chez TMDB et choix de la bonne œuvre par l'utilisateur.
/// Sert quand la recherche automatique, volontairement stricte, n'a rien retenu ou s'est trompée.
struct ArtworkPicker: View {
    let title: String
    let isSeries: Bool
    let key: String
    let onDone: () -> Void
    @EnvironmentObject var artwork: ArtworkLibrary
    @State private var query = ""
    @State private var candidates: [TMDBClient.Candidate] = []
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choisir l'œuvre sur TMDB").font(.system(size: 15, weight: .bold))
            HStack(spacing: 8) {
                TextField("Titre à chercher", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Chercher") { search() }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                if searching { ProgressView().controlSize(.small) }
            }
            if let message {
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.dim)
            }
            VStack(spacing: 4) {
                ForEach(candidates) { candidate in
                    CandidateRow(candidate: candidate) {
                        artwork.choose(candidate, for: key)
                        onDone()
                    }
                }
            }
            HStack {
                Button("Aucune affiche pour cette œuvre") {
                    artwork.chooseNone(for: key)
                    onDone()
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
                Spacer()
                Text("Votre choix est conservé : la recherche automatique n'y touchera plus.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            query = title
            search()
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !searching else { return }
        searching = true
        message = nil
        Task {
            do {
                candidates = try await TMDBClient.candidates(query: text, isSeries: isSeries)
                if candidates.isEmpty { message = "Aucun résultat. Essayez le titre original, ou un titre plus court." }
            } catch {
                candidates = []
                message = error.localizedDescription
            }
            searching = false
        }
    }
}

struct CandidateRow: View {
    let candidate: TMDBClient.Candidate
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: 40, height: 60)
                    .overlay {
                        if let url = candidate.posterURL { RemoteImage(urls: [url]) }
                        else { Theme.surface2.overlay(Image(systemName: "film").foregroundStyle(Theme.faint)) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text([candidate.year.map(String.init), candidate.originalName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                Text("Choisir").font(.system(size: 12, weight: .bold)).opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(hover ? 0.1 : 0.03), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
