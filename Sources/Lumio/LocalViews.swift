import SwiftUI

// Onglet « Films et séries » : ce que l'analyse des dossiers a trouvé sur le disque.

// MARK: - Accueil de l'onglet

struct LocalLibraryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary

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
                                      preferCover: true, symbol: "rectangle.stack.fill") { state.localSeries = series }
                        }
                    }
                }
                if !local.catalog.movies.isEmpty {
                    section("Films") {
                        ForEach(local.catalog.movies) { movie in
                            LocalCard(path: movie.path, title: movie.title,
                                      subtitle: [movie.year.map(String.init), Fmt.bytes(movie.size)].compactMap { $0 }.joined(separator: " · "),
                                      progress: local.position(for: movie.path)?.progress, preferCover: true,
                                      symbol: "play.circle.fill") { Task { await state.playLocal(path: movie.path) } }
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
    let action: () -> Void
    @EnvironmentObject var state: AppState
    @State private var hover = false

    var body: some View {
        let preparing = state.localPreparing == path
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(LocalThumb(path: path, preferCover: preferCover))
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

// MARK: - Page d'une série

struct LocalSeriesView: View {
    let series: LocalSeries
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary
    @State private var season: Int?

    private var shownSeason: Int { season ?? local.nextUp(in: series)?.season ?? series.seasons.first ?? 1 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header

                VStack(alignment: .leading, spacing: 16) {
                    if series.seasons.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(series.seasons, id: \.self) { number in
                                Chip(label: "Saison \(number)", detail: "\(series.episodes(in: number).count)",
                                     selected: shownSeason == number) { season = number }
                            }
                        }
                    } else {
                        Text("Saison \(shownSeason)").font(.system(size: 19, weight: .bold))
                    }
                    VStack(spacing: 2) {
                        ForEach(series.episodes(in: shownSeason)) { episode in
                            LocalEpisodeRow(series: series, episode: episode)
                        }
                    }
                }
                .padding(.horizontal, 48)
            }
            .padding(.bottom, 60)
        }
    }

    private var header: some View {
        let next = local.nextUp(in: series)
        let started = next.flatMap { local.position(for: $0.path) }?.progress != nil
            || series.episodes.contains { local.position(for: $0.path) != nil }
        return ZStack(alignment: .bottomLeading) {
            // Une image de l'épisode à venir sert de décor.
            LocalThumb(path: next?.path ?? series.episodes.first?.path ?? "")
                .blur(radius: 18)
                .scaleEffect(1.15)
            LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.45), .black.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Theme.bg.opacity(0.6), Theme.bg], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                Button { state.localSeries = nil } label: {
                    Label("Films et séries", systemImage: "chevron.left")
                        .font(.system(size: 12.5, weight: .bold)).foregroundStyle(.white.opacity(0.85)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(series.title)
                    .font(.system(size: 46, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
                Text([series.year.map(String.init),
                      series.seasons.count > 1 ? "\(series.seasons.count) saisons" : nil,
                      "\(series.episodes.count) épisodes", Fmt.bytes(series.totalSize)]
                    .compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                if let next {
                    HStack(spacing: 12) {
                        Button { Task { await state.playLocal(path: next.path) } } label: {
                            HStack(spacing: 8) {
                                if state.localPreparing == next.path { ProgressView().controlSize(.small).tint(.black) }
                                else { Image(systemName: "play.fill") }
                                Text(started ? "Reprendre S\(next.season) : É\(next.number)" : "Lecture")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(state.localPreparing != nil)
                        if let title = next.title {
                            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 30)
        }
        .frame(height: 380)
        .clipped()
    }
}

struct LocalEpisodeRow: View {
    let series: LocalSeries
    let episode: LocalEpisode
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
                        Text(episode.label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if position?.finished == true {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                        }
                    }
                    Text([duration > 0 ? Fmt.longDuration(duration) : nil, Fmt.bytes(episode.size),
                          URL(fileURLWithPath: episode.path).pathExtension.uppercased()]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
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
