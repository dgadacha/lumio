import SwiftUI
import VideoToolbox

/// Fiche d'une vidéo : infos, puis choix du format, de la résolution et des sous-titres.
struct DetailOverlay: View {
    let video: VideoSummary
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @EnvironmentObject var downloads: DownloadManager

    @State private var detail: VideoDetail?
    @State private var error: String?
    @State private var options = DownloadOptions()
    @State private var expanded = false
    @State private var showAllAuto = false
    @State private var subtitleFilter = ""

    private static let av1Hardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    private static let commonLanguages = ["fr", "en", "es", "de", "it", "pt", "ja", "ko", "zh-Hans", "ar"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { state.detail = nil }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 26) {
                        about
                        Divider().overlay(Color.white.opacity(0.12))
                        if let detail {
                            optionsPanel(detail)
                        } else if let error {
                            EmptyState(symbol: "exclamationmark.triangle", title: "Formats indisponibles", message: error,
                                       actionTitle: "Réessayer") { Task { await load() } }
                        } else {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Analyse des formats disponibles…").foregroundStyle(Theme.dim)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    .padding(.bottom, 34)
                }
                .frame(width: 880)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.7), radius: 40, y: 20)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await load() }
        .onExitCommand { state.detail = nil }
    }

    private func load() async {
        error = nil
        do {
            let loaded = try await state.loadDetail(video)
            detail = loaded
            applyDefaults(loaded)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyDefaults(_ detail: VideoDetail) {
        guard let top = detail.heights.first else {
            options.kind = .audio
            return
        }
        let preferred = UserDefaults.standard.integer(forKey: "defaultHeight")
        let cap = preferred > 0 ? preferred : 1080
        options.height = detail.heights.first { $0 <= cap } ?? top
        options.codec = bestCodec(detail, at: options.height)
    }

    private func bestCodec(_ detail: VideoDetail, at height: Int) -> VCodec {
        let available = detail.codecs(at: height)
        if available.contains(.h264) { return .h264 }
        if available.contains(.av1), Self.av1Hardware { return .av1 }
        return available.contains(.vp9) ? .vp9 : (available.first ?? .h264)
    }

    private func playsInApp(_ codec: VCodec) -> Bool {
        codec == .h264 || (codec == .av1 && Self.av1Hardware)
    }

    // MARK: En-tête

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urls: video.heroImages)
            LinearGradient(colors: [.clear, Theme.surface.opacity(0.5), Theme.surface], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                Text(detail?.summary.title ?? video.title)
                    .font(.system(size: 30, weight: .heavy))
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                if let owned = library.item(forVideo: video.id) {
                    HStack(spacing: 12) {
                        Button { state.play(owned) } label: {
                            Label(owned.playable ? (owned.progress != nil ? "Reprendre" : "Lecture") : "Ouvrir", systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Label("Disponible hors ligne · \(owned.quality)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
        .frame(height: 430)
        .clipped()
        .overlay(alignment: .topTrailing) {
            IconButton(symbol: "xmark", size: 14) { state.detail = nil }
                .padding(16)
        }
    }

    private var about: some View {
        let summary = detail?.summary ?? video
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let year = detail.map({ Fmt.year($0.uploadDate) }), !year.isEmpty {
                    Text(year).foregroundStyle(.green).fontWeight(.bold)
                }
                Text(Fmt.longDuration(summary.duration))
                if let top = detail?.heights.first, let tag = VideoDetail.heightTag(top) {
                    Text(tag)
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.5)))
                }
                Text(Fmt.views(summary.viewCount)).foregroundStyle(Theme.dim)
                Spacer()
                if let channel = summary.channel {
                    Text(channel).fontWeight(.semibold)
                }
            }
            .font(.system(size: 13.5))

            if let description = detail?.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                Button(expanded ? "Réduire" : "Lire la suite") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: Options

    @ViewBuilder
    private func optionsPanel(_ detail: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Télécharger").font(.system(size: 21, weight: .bold))

            section("Type") {
                HStack(spacing: 8) {
                    Chip(label: "Vidéo", selected: options.kind == .video, enabled: !detail.heights.isEmpty) { options.kind = .video }
                    Chip(label: "Audio seul", selected: options.kind == .audio) { options.kind = .audio }
                }
            }

            if options.kind == .video {
                section("Résolution") {
                    FlowLayout {
                        ForEach(detail.heights, id: \.self) { height in
                            Chip(label: detail.heightLabel(height), detail: VideoDetail.heightTag(height),
                                 selected: options.height == height) {
                                options.height = height
                                if !detail.codecs(at: height).contains(options.codec) {
                                    options.codec = bestCodec(detail, at: height)
                                }
                            }
                        }
                    }
                }
                section("Format", note: playsInApp(options.codec)
                        ? "Lisible dans le lecteur intégré."
                        : "Ce codec n'est pas lu par macOS : la vidéo s'ouvrira dans votre lecteur par défaut (VLC, IINA…).") {
                    HStack(spacing: 8) {
                        ForEach(VCodec.allCases, id: \.self) { codec in
                            Chip(label: "\(codec.label) · \(codec.container.uppercased())",
                                 detail: codec == .h264 ? "compatible partout" : (codec == .av1 ? "plus léger" : "jusqu'à la 4K"),
                                 selected: options.codec == codec,
                                 enabled: detail.codecs(at: options.height).contains(codec)) { options.codec = codec }
                        }
                    }
                }
            } else {
                section("Format audio") {
                    HStack(spacing: 8) {
                        ForEach(AudioFormat.allCases, id: \.self) { format in
                            Chip(label: format.label, detail: format.detail, selected: options.audioFormat == format) {
                                options.audioFormat = format
                            }
                        }
                    }
                }
            }

            if !detail.audioLanguages.isEmpty {
                section("Piste audio") {
                    FlowLayout {
                        Chip(label: "Originale", selected: options.audioLanguage == nil) { options.audioLanguage = nil }
                        ForEach(detail.audioLanguages, id: \.self) { code in
                            Chip(label: Fmt.language(code), selected: options.audioLanguage == code) { options.audioLanguage = code }
                        }
                    }
                }
            }

            subtitleSection(detail)

            section("Options") {
                VStack(alignment: .leading, spacing: 9) {
                    if options.kind == .video, !options.subtitles.isEmpty {
                        Toggle("Intégrer aussi les sous-titres dans le fichier vidéo", isOn: $options.embedSubtitles)
                    }
                    Toggle("Intégrer la miniature et les métadonnées", isOn: $options.embedMetadata)
                    if detail.chapterCount > 0 {
                        Toggle("Conserver les \(detail.chapterCount) chapitres", isOn: $options.embedChapters)
                    }
                    Toggle("Retirer les segments sponsorisés (SponsorBlock)", isOn: $options.removeSponsors)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
            }

            footer(detail)
        }
    }

    private func subtitleSection(_ detail: VideoDetail) -> some View {
        let original = detail.autoSubtitles.filter { $0.code.hasSuffix("-orig") }
        let common = detail.autoSubtitles.filter { Self.commonLanguages.contains($0.code) }
        let shownAuto: [SubTrack] = {
            if !subtitleFilter.isEmpty {
                return detail.autoSubtitles.filter {
                    $0.name.localizedCaseInsensitiveContains(subtitleFilter) || $0.code.localizedCaseInsensitiveContains(subtitleFilter)
                }
            }
            if showAllAuto { return detail.autoSubtitles }
            var seen = Set<String>()
            return (original + common + options.subtitles.filter(\.auto)).filter { seen.insert($0.id).inserted }
        }()

        return section("Sous-titres", note: detail.subtitles.isEmpty && detail.autoSubtitles.isEmpty
                       ? "Aucun sous-titre n'est proposé pour cette vidéo." : nil) {
            VStack(alignment: .leading, spacing: 12) {
                if !detail.subtitles.isEmpty {
                    FlowLayout {
                        ForEach(detail.subtitles) { track in subtitleChip(track) }
                    }
                }
                if !detail.autoSubtitles.isEmpty {
                    HStack(spacing: 10) {
                        Text("Générés automatiquement").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.dim)
                        if showAllAuto || !subtitleFilter.isEmpty || detail.autoSubtitles.count > shownAuto.count {
                            TextField("Filtrer les \(detail.autoSubtitles.count) langues", text: $subtitleFilter)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(.horizontal, 9)
                                .frame(width: 190, height: 24)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }
                        if detail.autoSubtitles.count > shownAuto.count || showAllAuto {
                            Button(showAllAuto ? "Réduire" : "Toutes les langues") { showAllAuto.toggle() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    FlowLayout {
                        ForEach(shownAuto) { track in subtitleChip(track) }
                    }
                }
            }
        }
    }

    private func subtitleChip(_ track: SubTrack) -> some View {
        Chip(label: track.name, detail: track.code.hasSuffix("-orig") ? "langue d'origine" : nil,
             selected: options.subtitles.contains(track)) {
            if options.subtitles.contains(track) { options.subtitles.remove(track) } else { options.subtitles.insert(track) }
        }
    }

    private func footer(_ detail: VideoDetail) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(options.qualityLabel + (options.subtitles.isEmpty ? "" : " · \(options.subtitles.count) sous-titre(s)"))
                    .font(.system(size: 14, weight: .bold))
                let size = Fmt.bytes(detail.estimatedSize(options))
                Text(size.isEmpty ? "Taille inconnue avant téléchargement" : "Environ \(size)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            if let job = downloads.job(forVideo: video.id) {
                ActiveJobBadge(job: job)
            } else {
                Button {
                    downloads.enqueue(video: video, detail: detail, options: options)
                } label: {
                    Label(library.item(forVideo: video.id) == nil ? "Télécharger" : "Télécharger à nouveau", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(PrimaryButtonStyle(fill: Theme.accent, text: .white))
                .disabled(state.engine.path == nil)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .kerning(1.4)
                .foregroundStyle(Theme.faint)
            content()
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
    }
}

struct ActiveJobBadge: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: job.fraction).tint(Theme.accent).frame(width: 150)
            Text(job.state == .running ? "\(Int(job.fraction * 100)) %" : job.stage)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Button("Voir") {
                state.detail = nil
                state.tab = .downloads
            }
            .buttonStyle(PrimaryButtonStyle(fill: Color.white.opacity(0.2), text: .white))
        }
    }
}
