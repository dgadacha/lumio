import SwiftUI

// MARK: - Catalogue

struct Category: Identifiable, Hashable {
    struct Row: Hashable {
        let title: String
        /// Mots-clés de recherche, ou lien d'une chaîne ou d'une playlist.
        let query: String
    }

    let id: String
    let name: String
    let tagline: String
    let symbol: String
    let hue: Double
    let isChannel: Bool
    let rows: [Row]

    var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.72, brightness: 0.62),
                Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.24),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private static func theme(_ id: String, _ name: String, _ tagline: String, _ symbol: String, _ hue: Double,
                              _ rows: [(String, String)]) -> Category {
        Category(id: id, name: name, tagline: tagline, symbol: symbol, hue: hue, isChannel: false,
                 rows: rows.map { Row(title: $0.0, query: $0.1) })
    }

    private static func channel(_ handle: String, _ name: String, _ tagline: String, _ symbol: String, _ hue: Double,
                                extra: [(String, String)] = []) -> Category {
        let base = "https://www.youtube.com/@\(handle)"
        return Category(
            id: "chaine-\(handle.lowercased())", name: name, tagline: tagline, symbol: symbol, hue: hue, isChannel: true,
            rows: [Row(title: "Dernières vidéos", query: "\(base)/videos")] + extra.map { Row(title: $0.0, query: $0.1) }
        )
    }

    static let themes: [Category] = [
        theme("documentaires", "Documentaires", "Le monde tel qu'il est, en long format.", "globe.europe.africa.fill", 0.38, [
            ("Nature et vie sauvage", "documentaire animalier complet"),
            ("Enquêtes et société", "documentaire société enquête complet"),
            ("Grands récits d'histoire", "documentaire histoire complet"),
            ("Sciences", "documentaire science complet"),
        ]),
        theme("science", "Science et espace", "Comprendre l'univers, de l'atome aux galaxies.", "sparkles", 0.62, [
            ("Exploration spatiale", "documentaire espace univers"),
            ("Vulgarisation", "vulgarisation scientifique"),
            ("Physique et mathématiques", "physique mathématiques expliquées"),
            ("Le vivant", "biologie évolution documentaire"),
        ]),
        theme("histoire", "Histoire", "Les époques, les empires et ceux qui les ont faits.", "building.columns.fill", 0.09, [
            ("Antiquité", "documentaire antiquité rome égypte"),
            ("Moyen Âge", "documentaire moyen âge"),
            ("XXe siècle", "documentaire histoire xxe siècle"),
            ("Civilisations disparues", "documentaire civilisations disparues archéologie"),
        ]),
        theme("cinema", "Cinéma et séries", "Avant, pendant et après la séance.", "film.fill", 0.98, [
            ("Bandes-annonces", "bande annonce officielle vf"),
            ("Analyses de films", "analyse de film"),
            ("Courts métrages", "court métrage primé"),
            ("Dans les coulisses", "making of film tournage"),
        ]),
        theme("musique", "Musique live", "Concerts, sessions et scènes du monde entier.", "music.mic", 0.80, [
            ("Concerts complets", "concert live complet"),
            ("Sessions acoustiques", "live session acoustique"),
            ("Classique", "concert orchestre symphonique"),
            ("Jazz", "jazz live concert"),
        ]),
        theme("voyage", "Voyage et évasion", "Partir loin sans quitter le canapé.", "airplane", 0.53, [
            ("Vues du ciel", "voyage 4k drone"),
            ("Carnets de route", "carnet de voyage documentaire"),
            ("Randonnée et grands espaces", "randonnée trek film"),
            ("Voyages en train", "voyage en train documentaire"),
        ]),
        theme("cuisine", "Cuisine", "Des gestes de chef aux cuisines de rue.", "fork.knife", 0.06, [
            ("Recettes de chefs", "recette de chef"),
            ("Cuisines du monde", "cuisine du monde documentaire"),
            ("Pâtisserie", "pâtisserie technique chef"),
            ("Cuisine de rue", "street food documentaire"),
        ]),
        theme("tech", "Tech et numérique", "Les machines, le code et ce qu'ils changent.", "cpu.fill", 0.58, [
            ("Tests et nouveautés", "test high-tech"),
            ("L'informatique expliquée", "informatique expliquée"),
            ("Intelligence artificielle", "intelligence artificielle explication"),
            ("Rétro-informatique", "rétro informatique histoire ordinateur"),
        ]),
        theme("sport", "Sport et aventure", "L'effort, le risque et les grands exploits.", "figure.climbing", 0.30, [
            ("Documentaires sportifs", "documentaire sport complet"),
            ("Montagne et alpinisme", "film alpinisme escalade"),
            ("Mer et voile", "documentaire voile course au large"),
            ("Exploits et records", "exploit sportif documentaire"),
        ]),
        theme("jeux", "Jeux vidéo", "L'histoire, la technique et la passion du jeu.", "gamecontroller.fill", 0.74, [
            ("Histoire du jeu vidéo", "histoire du jeu vidéo documentaire"),
            ("Création de jeux", "making of jeu vidéo développement"),
            ("Speedrun", "speedrun commenté"),
            ("Rétrogaming", "rétrogaming documentaire"),
        ]),
        theme("arts", "Arts et culture", "Peinture, architecture, littérature et idées.", "paintpalette.fill", 0.90, [
            ("Histoire de l'art", "histoire de l'art documentaire"),
            ("Architecture", "architecture documentaire"),
            ("Littérature et idées", "conférence littérature philosophie"),
            ("Portraits d'artistes", "portrait artiste documentaire"),
        ]),
        theme("humour", "Humour", "Spectacles, sketchs et seuls-en-scène.", "theatermasks.fill", 0.13, [
            ("Spectacles complets", "spectacle humoriste complet"),
            ("Sketchs", "sketch humour"),
            ("Stand-up", "stand up français"),
        ]),
    ]

    static let channels: [Category] = [
        channel("arte", "ARTE", "La chaîne culturelle européenne.", "tv.fill", 0.05, extra: [
            ("Documentaires", "arte documentaire complet"),
            ("Concerts", "arte concert live"),
            ("Reportages", "arte reportage"),
        ]),
        channel("franceculture", "France Culture", "Savoirs, idées et création.", "books.vertical.fill", 0.76),
        channel("lemondefr", "Le Monde", "Enquêtes vidéo et décryptages.", "newspaper.fill", 0.60),
        channel("TV5MONDE", "TV5MONDE", "La francophonie en images.", "globe", 0.56),
        channel("CNRS", "CNRS", "La recherche racontée par ceux qui la font.", "atom", 0.50),
        channel("ScienceEtonnante", "ScienceEtonnante", "La science qui surprend, expliquée.", "lightbulb.fill", 0.15),
        channel("notabenemovies", "Nota Bene", "L'histoire, avec passion.", "scroll.fill", 0.08),
        channel("DirtyBiology", "DirtyBiology", "Le vivant sous un angle inattendu.", "leaf.fill", 0.36),
        channel("BlenderStudio", "Blender Studio", "Films d'animation libres et leurs coulisses.", "cube.transparent.fill", 0.07),
    ]

    static let all = themes + channels

    /// Page d'une chaîne suivie par l'utilisateur ; la teinte découle de son identifiant, donc reste stable.
    static func followed(_ channel: FollowedChannel) -> Category {
        let hue = Double(channel.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        return Category(id: "abo-\(channel.id)", name: channel.name, tagline: "Chaîne suivie", symbol: "person.crop.rectangle.stack.fill",
                        hue: hue, isChannel: true, rows: [Row(title: "Dernières vidéos", query: channel.videosURL)])
    }
}

// MARK: - Onglet Catégories

struct CategoriesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var subscriptions: Subscriptions

    var body: some View {
        PageScaffold(title: "Catégories", subtitle: "Explorez par thème ou par chaîne.") {
            if !subscriptions.channels.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Mes abonnements").font(.system(size: 19, weight: .bold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 14)], spacing: 14) {
                        ForEach(subscriptions.channels) { channel in
                            CategoryTile(category: Category.followed(channel)) { state.open(Category.followed(channel)) }
                                .contextMenu {
                                    Button("Se désabonner de \(channel.name)") {
                                        subscriptions.toggle(id: channel.id, name: channel.name)
                                    }
                                }
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            section("Thèmes", Category.themes)
            section("Chaînes", Category.channels)
        }
    }

    private func section(_ title: String, _ categories: [Category]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 19, weight: .bold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 14)], spacing: 14) {
                ForEach(categories) { category in
                    CategoryTile(category: category) { state.open(category) }
                }
            }
        }
        .padding(.bottom, 10)
    }
}

struct CategoryTile: View {
    let category: Category
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                category.gradient
                Image(systemName: category.symbol)
                    .font(.system(size: 76, weight: .bold))
                    .foregroundStyle(.white.opacity(0.2))
                    .rotationEffect(.degrees(-12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 14, y: 16)
                VStack(alignment: .leading, spacing: 3) {
                    if category.isChannel {
                        Text("CHAÎNE").font(.system(size: 9.5, weight: .heavy)).kerning(1.6).opacity(0.75)
                    }
                    Text(category.name)
                        .font(.system(size: 18, weight: .heavy))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(hover ? 0.6 : 0), lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.04 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hover)
        .onHover { hover = $0 }
    }
}

// MARK: - Page d'une catégorie

struct CategoryView: View {
    let category: Category
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library

    var body: some View {
        let factory = CardFactory(state: state, library: library)
        let rows = state.categoryRows[category.id] ?? []
        let loading = state.categoryLoading.contains(category.id)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header

                // Une chaîne sans rangée thématique s'affiche en grille, comme un catalogue.
                if rows.count == 1, category.rows.count == 1, let only = rows.first {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(only.title).font(.system(size: 19, weight: .bold))
                        CardGrid(cards: only.items.map(factory.card))
                    }
                    .padding(.horizontal, 48)
                } else {
                    ForEach(rows) { row in
                        Shelf(title: row.title, cards: row.items.map(factory.card))
                    }
                }

                if loading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Chargement de la catégorie…").foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else if rows.isEmpty, let error = state.categoryErrors[category.id] {
                    // Seulement après un échec réel : avant le premier chargement, la page reste vide.
                    EmptyState(symbol: "wifi.slash", title: "Catégorie indisponible",
                               message: error,
                               actionTitle: "Réessayer") { Task { await state.loadCategory(category, force: true) } }
                }
            }
            .padding(.bottom, 60)
        }
        .task { await state.loadCategory(category, force: false) }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            category.gradient
            Image(systemName: category.symbol)
                .font(.system(size: 250, weight: .bold))
                .foregroundStyle(.white.opacity(0.13))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: -40, y: 30)
            LinearGradient(colors: [.clear, Theme.bg.opacity(0.55), Theme.bg], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 10) {
                Button { state.category = nil } label: {
                    Label("Catégories", systemImage: "chevron.left")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(category.name)
                    .font(.system(size: 46, weight: .heavy))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
                Text(category.tagline)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 30)
        }
        .frame(height: 330)
        .clipped()
    }
}
