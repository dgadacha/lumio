import SwiftUI

// MARK: - Carte

struct CardData: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let images: [URL]
    var duration: Double? = nil
    var badge: String? = nil
    var progress: Double? = nil
    var hoverSymbol = "info.circle.fill"
    let action: () -> Void
}

struct VideoCard: View {
    let data: CardData
    var width: CGFloat? = 264
    @State private var hover = false

    var body: some View {
        Button(action: data.action) {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(RemoteImage(urls: data.images))
                    .overlay(Color.black.opacity(hover ? 0.28 : 0))
                    .overlay {
                        Image(systemName: data.hoverSymbol)
                            .font(.system(size: 38))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                            .opacity(hover ? 1 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = data.duration, duration > 0 {
                            Text(Fmt.duration(duration))
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3))
                                .padding(7)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let badge = data.badge {
                            Label(badge, systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 10.5, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                                .padding(7)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = data.progress {
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
                    Text(data.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !data.subtitle.isEmpty {
                        Text(data.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.07 : 1, anchor: .center)
        .zIndex(hover ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Rangée horizontale

struct Shelf: View {
    let title: String
    var subtitle: String? = nil
    var suggested = false
    let cards: [CardData]
    @State private var position: String?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if suggested {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent).font(.system(size: 15, weight: .bold))
                    }
                    Text(title).font(.system(size: 19, weight: .bold))
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(2)
                }
            }
            .padding(.horizontal, 48)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(cards) { card in
                        VideoCard(data: card).id(card.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 48)
                .padding(.vertical, 14)
            }
            .scrollPosition(id: $position, anchor: .leading)
            .scrollClipDisabled()
            .overlay(alignment: .leading) { arrow("chevron.left", step: -4) }
            .overlay(alignment: .trailing) { arrow("chevron.right", step: 4) }
        }
        .onHover { hover = $0 }
    }

    private func arrow(_ symbol: String, step: Int) -> some View {
        Button {
            let current = cards.firstIndex { $0.id == position } ?? 0
            let target = min(max(current + step, 0), cards.count - 1)
            withAnimation(.easeInOut(duration: 0.45)) { position = cards[target].id }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 148)
                .background(Color.black.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hover && cards.count > 4 ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .padding(.bottom, 58)
    }
}

// MARK: - Fabrique de cartes

@MainActor
struct CardFactory {
    let state: AppState
    let library: Library

    func card(_ video: VideoSummary) -> CardData {
        let owned = library.item(forVideo: video.id)
        return CardData(
            id: video.id,
            title: video.title,
            subtitle: video.subtitleLine,
            images: video.cardImages,
            duration: video.duration,
            badge: owned == nil ? nil : "Hors ligne",
            progress: owned?.progress,
            action: { state.detail = video }
        )
    }

    func card(_ item: LibraryItem) -> CardData {
        CardData(
            id: item.id.uuidString,
            title: item.title,
            subtitle: [item.channel, item.quality].compactMap { $0 }.joined(separator: " · "),
            images: item.images,
            duration: item.duration,
            progress: item.progress,
            hoverSymbol: item.playable ? "play.circle.fill" : "arrow.up.forward.app.fill",
            action: { state.play(item) }
        )
    }
}

// MARK: - Accueil

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        let factory = CardFactory(state: state, library: library)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let featured = state.featured {
                    HeroView(video: featured)
                } else {
                    Color.clear.frame(height: 90)
                }

                if state.engineChecked, state.engine.path == nil || state.engine.outdated {
                    EngineBanner().padding(.horizontal, 48)
                }

                if !library.continueWatching.isEmpty {
                    Shelf(title: "Reprendre la lecture", cards: library.continueWatching.map(factory.card))
                }
                if !library.items.isEmpty {
                    Shelf(title: "Disponibles hors ligne", cards: library.items.prefix(20).map(factory.card))
                }

                if state.aiEnabled {
                    ForEach(state.aiRows) { row in
                        Shelf(title: row.title, subtitle: row.reason, suggested: true, cards: row.items.map(factory.card))
                    }
                    if state.aiBusy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Claude prépare vos suggestions…").font(.system(size: 13)).foregroundStyle(Theme.dim)
                        }
                        .padding(.horizontal, 48)
                    } else if let error = state.aiError {
                        Label(error, systemImage: "sparkles")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal, 48)
                    }
                }

                ForEach(state.rows) { row in
                    Shelf(title: row.title, cards: row.items.map(factory.card))
                }

                if state.loadingHome {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Chargement du catalogue…").foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else if state.rows.isEmpty, let error = state.homeError {
                    EmptyState(
                        symbol: "wifi.slash",
                        title: "Catalogue indisponible",
                        message: "\(error)\nVos vidéos téléchargées restent accessibles dans Ma bibliothèque.",
                        actionTitle: "Réessayer"
                    ) { Task { await state.loadHome(force: true) } }
                }
            }
            .padding(.bottom, 60)
        }
    }
}

struct HeroView: View {
    let video: VideoSummary
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urls: video.heroImages)
            LinearGradient(colors: [.black.opacity(0.88), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Theme.bg.opacity(0.6), Theme.bg], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                Text("À LA UNE")
                    .font(.system(size: 11.5, weight: .heavy))
                    .kerning(3)
                    .foregroundStyle(Theme.accent)
                Text(video.title)
                    .font(.system(size: 42, weight: .heavy))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
                Text([video.channel, Fmt.longDuration(video.duration), Fmt.views(video.viewCount)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))

                HStack(spacing: 12) {
                    if let owned = library.item(forVideo: video.id) {
                        Button { state.play(owned) } label: {
                            Label("Lecture", systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button { state.detail = video } label: {
                            Label("Télécharger", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Button { state.detail = video } label: {
                        Label("Plus d'infos", systemImage: "info.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle(fill: Color.white.opacity(0.24), text: .white))
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.bottom, 54)
        }
        .frame(height: 540)
        .clipped()
    }
}

struct EngineBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 3) {
                Text(state.engine.path == nil ? "Moteur de téléchargement absent" : "Moteur de téléchargement ancien (\(state.engine.version ?? "?"))")
                    .font(.system(size: 14, weight: .bold))
                Text(state.engineBusy ? state.engineLog : "YouTube évolue souvent : sans un moteur récent, les téléchargements échouent.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer()
            if state.engineBusy {
                ProgressView().controlSize(.small)
            } else {
                Button(state.engine.path == nil ? "Installer" : "Mettre à jour") { state.updateEngine() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.35)))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(Theme.faint)
            Text(title).font(.system(size: 20, weight: .bold))
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

// MARK: - Grille

struct CardGrid: View {
    let cards: [CardData]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)], alignment: .leading, spacing: 26) {
            ForEach(cards) { card in
                VideoCard(data: card, width: nil)
            }
        }
    }
}

struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 30, weight: .heavy))
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Theme.dim)
                    }
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 96)
            .padding(.bottom, 60)
        }
    }
}

// MARK: - Recherche

struct SearchView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        let factory = CardFactory(state: state, library: library)
        PageScaffold(
            title: state.searchedQuery.isEmpty ? "Recherche" : "Résultats pour « \(state.searchedQuery) »",
            subtitle: state.searching ? "" : (state.results.isEmpty ? "" : "\(state.results.count) vidéos")
        ) {
            if state.searching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Recherche en cours…").foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
            } else if let error = state.searchError {
                EmptyState(symbol: "exclamationmark.magnifyingglass", title: "Recherche impossible", message: error,
                           actionTitle: "Réessayer") { state.runSearch() }
            } else if state.results.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "Aucun résultat",
                           message: "Essayez d'autres mots-clés, ou collez le lien d'une vidéo, d'une playlist ou d'une chaîne.")
            } else {
                CardGrid(cards: state.results.map(factory.card))
            }
        }
    }
}

// MARK: - Bibliothèque

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @State private var filter: MediaKind?
    @State private var pendingDelete: LibraryItem?

    private var shown: [LibraryItem] {
        library.items.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        PageScaffold(
            title: "Ma bibliothèque",
            subtitle: library.items.isEmpty ? "" : "\(library.items.count) titres hors ligne · \(Fmt.bytes(library.totalSize))"
        ) {
            if library.items.isEmpty {
                EmptyState(symbol: "film.stack", title: "Rien à regarder hors ligne pour l'instant",
                           message: "Les vidéos que vous téléchargez apparaissent ici et se lisent sans connexion.",
                           actionTitle: "Parcourir le catalogue") { state.tab = .home }
            } else {
                HStack(spacing: 8) {
                    Chip(label: "Tout", selected: filter == nil) { filter = nil }
                    Chip(label: "Vidéos", selected: filter == .video) { filter = .video }
                    Chip(label: "Audio", selected: filter == .audio) { filter = .audio }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)], alignment: .leading, spacing: 26) {
                    ForEach(shown) { item in
                        VideoCard(data: CardFactory(state: state, library: library).card(item), width: nil)
                            .contextMenu {
                                Button(item.playable ? "Lire" : "Ouvrir dans le lecteur par défaut") { state.play(item) }
                                Button("Afficher dans le Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.mediaURL])
                                }
                                Divider()
                                Button("Supprimer…", role: .destructive) { pendingDelete = item }
                            }
                    }
                }
            }
        }
        .confirmationDialog(
            "Supprimer « \(pendingDelete?.title ?? "") » ?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Mettre à la corbeille", role: .destructive) {
                if let item = pendingDelete { library.remove(item) }
                pendingDelete = nil
            }
        } message: {
            Text("Le fichier est déplacé dans la corbeille.")
        }
    }
}

// MARK: - Téléchargements

struct DownloadsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        PageScaffold(title: "Téléchargements", subtitle: "Enregistrés dans \(Paths.downloads.path)") {
            if downloads.jobs.isEmpty {
                EmptyState(symbol: "arrow.down.circle", title: "Aucun téléchargement en cours",
                           message: "Ouvrez la fiche d'une vidéo pour choisir le format, la résolution et les sous-titres.")
            } else {
                if downloads.jobs.contains(where: { !$0.isActive }) {
                    Button("Effacer les téléchargements terminés") { downloads.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                }
                VStack(spacing: 10) {
                    ForEach(downloads.jobs) { job in
                        DownloadRow(job: job)
                    }
                }
            }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var downloads: DownloadManager

    private var statusColor: Color {
        switch job.state {
        case .failed: return .red
        case .done: return .green
        default: return Theme.dim
        }
    }

    private var statusText: String {
        switch job.state {
        case .failed(let message): return message
        case .running:
            var parts = ["\(Int(job.fraction * 100)) %"]
            if let speed = job.speed, speed > 0 { parts.append(Fmt.bytes(Int64(speed)) + "/s") }
            if let eta = job.eta, eta > 0 { parts.append("reste " + Fmt.longDuration(eta)) }
            return parts.joined(separator: " · ")
        default: return job.stage
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Color.clear
                .frame(width: 150, height: 84)
                .overlay(RemoteImage(urls: job.video.cardImages))
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 7) {
                Text(job.video.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text([job.video.channel, job.options.qualityLabel, Fmt.bytes(job.expectedBytes)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                if job.isActive {
                    if job.state == .finishing || job.state == .queued || job.fraction == 0 {
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    } else {
                        ProgressView(value: job.fraction).tint(Theme.accent)
                    }
                }
                Text(job.state == .running && job.fraction == 0 ? job.stage : statusText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if job.isActive {
                IconButton(symbol: "xmark") { downloads.cancel(job) }
            } else if job.state == .done, let item = library.item(forVideo: job.video.id) {
                Button { state.play(item) } label: { Label("Lire", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
