import SwiftUI

@main
struct LumioApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("Lumio", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.library)
                .environmentObject(state.downloads)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()

            Group {
                switch state.tab {
                case .home: HomeView()
                case .categories:
                    if let category = state.category {
                        CategoryView(category: category).id(category.id)
                    } else {
                        CategoriesView()
                    }
                case .search: SearchView()
                case .library: LibraryView()
                case .downloads: DownloadsView()
                case .settings: SettingsView()
                }
            }
            .ignoresSafeArea()

            TopBar()

            if let video = state.detail {
                DetailOverlay(video: video)
                    .id(video.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(2)
            }

            if let item = state.playing {
                PlayerView(item: item)
                    .id(item.id)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .animation(.easeOut(duration: 0.22), value: state.detail)
        .animation(.easeOut(duration: 0.25), value: state.playing)
    }
}

// MARK: - Barre du haut

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var downloads: DownloadManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 22) {
            Text("LUMIO")
                .font(.system(size: 23, weight: .black, design: .rounded))
                .kerning(2.5)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 78)
                .onTapGesture { state.tab = .home }

            tabLink("Accueil", .home)
            tabLink("Catégories", .categories)
            tabLink("Ma bibliothèque", .library)
            tabLink("Téléchargements", .downloads, badge: downloads.activeCount)

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                TextField("Titres, chaînes ou lien YouTube", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { state.runSearch() }
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 150, maxWidth: searchFocused || !state.query.isEmpty ? 330 : 250)
            .frame(height: 32)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(searchFocused ? 0.7 : 0.22)))
            .animation(.easeOut(duration: 0.2), value: searchFocused)

            Button { state.tab = .settings } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(state.tab == .settings ? .white : Theme.dim)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 36)
        }
        .frame(height: 62)
        .background(
            LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        )
        .ignoresSafeArea()
    }

    private func tabLink(_ title: String, _ tab: AppState.Tab, badge: Int = 0) -> some View {
        Button {
            if tab == .categories { state.category = nil }
            state.tab = tab
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: 13.5, weight: state.tab == tab ? .bold : .medium))
                    .foregroundStyle(state.tab == tab ? Color.white : Theme.dim)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
