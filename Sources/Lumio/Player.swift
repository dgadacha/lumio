import SwiftUI
import AVKit

// MARK: - Ce que le lecteur sait lire

struct PlayerSubtitle: Identifiable, Hashable {
    let code: String
    let label: String
    /// Fichier .vtt local, ou adresse distante pour une lecture en streaming.
    let url: URL
    var id: String { url.absoluteString }
}

/// Un fichier de la bibliothèque ou un flux lu sans téléchargement.
struct PlayableMedia: Identifiable, Hashable {
    let id: String
    let video: VideoSummary
    let detailLine: String
    let url: URL
    let kind: MediaKind
    let images: [URL]
    let subtitles: [PlayerSubtitle]
    let startPosition: Double
    let source: Source

    /// D'où vient ce qui est lu : cela décide des menus affichés et de l'endroit où la position est mémorisée.
    enum Source: Hashable {
        /// Téléchargé par Lumio.
        case library(UUID)
        /// Flux YouTube lu sans téléchargement.
        case stream
        /// Film ou épisode trouvé sur le disque ; `path` est le fichier d'origine, jamais la copie temporaire.
        case local(path: String, nextPath: String?)
    }

    var isStream: Bool { source == .stream }
    var localPath: String? {
        if case .local(let path, _) = source { return path }
        return nil
    }
    var nextLocalPath: String? {
        if case .local(_, let next) = source { return next }
        return nil
    }

    init(item: LibraryItem) {
        id = item.id.uuidString
        video = VideoSummary(id: item.videoID, title: item.title, channel: item.channel, duration: item.duration,
                             viewCount: nil, thumbnail: nil)
        detailLine = [item.channel, item.quality].compactMap { $0 }.joined(separator: " · ")
        url = item.mediaURL
        kind = item.kind
        images = item.images
        subtitles = item.subtitles.map {
            PlayerSubtitle(code: $0.code, label: Fmt.language($0.code), url: item.folderURL.appendingPathComponent($0.file))
        }
        startPosition = item.position
        source = .library(item.id)
    }

    /// Film ou épisode du disque, une fois rendu lisible par `MediaPreparer`.
    init(localPath: String, title: String, detailLine: String, prepared: PreparedMedia, startPosition: Double, nextPath: String?) {
        id = "local-\(LocalTools.fingerprint(localPath))"
        video = VideoSummary(id: id, title: title, channel: nil, duration: prepared.duration > 0 ? prepared.duration : nil,
                             viewCount: nil, thumbnail: nil)
        self.detailLine = detailLine
        url = prepared.playURL
        kind = .video
        images = []
        subtitles = prepared.subtitles
        self.startPosition = startPosition
        source = .local(path: localPath, nextPath: nextPath)
    }

    init(stream detail: VideoDetail, url: URL, startPosition: Double) {
        let summary = detail.summary
        id = "stream-\(summary.id)"
        video = summary
        detailLine = [summary.channel, "Streaming"].compactMap { $0 }.joined(separator: " · ")
        self.url = url
        kind = .video
        images = summary.heroImages
        // Pistes manuelles, langue d'origine automatique, puis quelques traductions courantes.
        let common = ["fr", "en", "es", "de", "it", "pt"]
        let originals = detail.autoSubtitles.filter { $0.code.hasSuffix("-orig") }
        let translated = detail.autoSubtitles.filter { common.contains($0.code) }
        // Une ligne par langue : la piste manuelle d'abord, puis la transcription d'origine, puis la traduction.
        var seen = Set<String>()
        subtitles = (detail.subtitles + originals + translated).compactMap { track -> PlayerSubtitle? in
            let language = track.code.replacingOccurrences(of: "-orig", with: "")
            guard let raw = track.url, let remote = URL(string: raw), seen.insert(language).inserted else { return nil }
            let label: String
            if !track.auto { label = track.name }
            else if track.code.hasSuffix("-orig") { label = "\(Fmt.language(language)) (transcription automatique)" }
            else { label = "\(Fmt.language(language)) (traduction automatique)" }
            return PlayerSubtitle(code: track.code, label: label, url: remote)
        }
        self.startPosition = startPosition
        source = .stream
    }
}

/// Piste audio d'un fichier (version originale, version française…).
struct AudioChoice: Identifiable, Hashable {
    let id: Int
    let label: String
    let language: String?
}

// MARK: - Modèle du lecteur

@MainActor
final class PlayerModel: ObservableObject {
    let media: PlayableMedia
    let player = AVPlayer()

    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isBuffering = false
    @Published var caption = ""
    @Published var subtitle: PlayerSubtitle?
    @Published var rate: Float = 1
    @Published var volume: Float = 1 { didSet { player.volume = volume } }
    @Published var maxHeight: Int = 0
    /// Hauteur de l'image réellement affichée (le flux adaptatif en change selon le débit).
    @Published var videoHeight: Int = 0
    @Published var controlsVisible = true
    @Published var failed: String?
    @Published var notice: String?
    @Published var audioChoices: [AudioChoice] = []
    @Published var audioChoice: Int?
    private var audioGroup: AVMediaSelectionGroup?

    var onClose: () -> Void = {}
    private var cues: [Cue] = []
    private var timeObserver: Any?
    private var keyMonitor: Any?
    private var statusObserver: NSKeyValueObservation?
    private var hideWork: DispatchWorkItem?
    private var subtitleTask: Task<Void, Never>?
    private let playerItem: AVPlayerItem

    init(media: PlayableMedia) {
        self.media = media
        duration = media.video.duration ?? 0
        let asset = AVURLAsset(url: media.url)
        playerItem = AVPlayerItem(asset: asset)
        // Les sous-titres sont dessinés par l'app : on coupe ceux intégrés au fichier pour éviter le doublon.
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.replaceCurrentItem(with: playerItem)
        let item = playerItem
        Task {
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                item.select(nil, in: group)
            }
            if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
                duration = loaded.seconds
            }
            await loadAudioChoices(asset: asset)
        }
        statusObserver = playerItem.observe(\.status) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let message = observed.error?.localizedDescription ?? "Lecture impossible"
            DispatchQueue.main.async { self?.failed = message }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] current in
            MainActor.assumeIsolated { self?.tick(current.seconds) }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(key: event) ?? true } ? event : nil
        }
        if media.startPosition > 5 {
            player.seek(to: CMTime(seconds: media.startPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            time = media.startPosition
        }
        // La langue mémorisée n'est rechargée d'office que pour un fichier sur disque : en streaming,
        // chaque piste est une requête à YouTube, faite seulement à la demande.
        if media.localPath != nil {
            // Fichier du disque : on retrouve la piste par son libellé (« Français — Complets »),
            // identique d'un épisode à l'autre d'une même série.
            if let label = UserDefaults.standard.string(forKey: "localSubtitleLabel"),
               let match = media.subtitles.first(where: { $0.label == label }) {
                select(subtitle: match, remember: false)
            }
        } else if !media.isStream, let preferred = UserDefaults.standard.string(forKey: "subtitleLanguage"),
                  let match = media.subtitles.first(where: { $0.code == preferred }) {
            select(subtitle: match, remember: false)
        }
        player.play()
        isPlaying = true
        pokeControls()
        DebugDriver.playerReport = { [weak self] in
            guard let self else { return "lecteur fermé" }
            let item = self.playerItem
            return "statut=\(item.status.rawValue) temps=\(self.time) durée=\(self.duration) brut=\(self.player.currentTime().seconds) "
                + "image=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) contrôle=\(self.player.timeControlStatus.rawValue) "
                + "attente=\(self.player.reasonForWaitingToPlay?.rawValue ?? "-") échec=\(self.failed ?? "aucun") "
                + "erreur=\(item.error?.localizedDescription ?? "aucune") journal=\(item.errorLog()?.events.last?.errorComment ?? "-") reprise=\(self.media.startPosition) "
                + "détail=\((item.error as NSError?).map { "\($0.domain) \($0.code) sous-jacente=\(($0.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "-") raison=\($0.localizedFailureReason ?? "-")" } ?? "-") "
                + "audio=\(self.audioChoices.map(\.label)) choisie=\(self.audioChoice.map(String.init) ?? "-") fichier=\(self.media.url.lastPathComponent)"
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        time = seconds
        isPlaying = player.rate != 0
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let height = Int(playerItem.presentationSize.height.rounded())
        if height != videoHeight {
            videoHeight = height
            DebugDriver.videoHeight = height
        }
        let active = cues.last { $0.start <= seconds && seconds < $0.end }?.text ?? ""
        if active != caption { caption = active }
    }

    /// Renvoie vrai si la touche n'a pas été traitée.
    private func handle(key event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return true }
        switch event.keyCode {
        case 49: togglePlay()
        case 123: seek(by: -10)
        case 124: seek(by: 10)
        case 126: volume = min(1, volume + 0.1)
        case 125: volume = max(0, volume - 0.1)
        case 3: toggleFullScreen()
        case 53:
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } else { onClose() }
        default: return true
        }
        pokeControls()
        return false
    }

    func togglePlay() {
        if player.rate == 0 {
            if duration > 0, time >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: rate)
        } else {
            player.pause()
        }
        isPlaying = player.rate != 0
    }

    func seek(by delta: Double) { seek(to: time + delta) }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(duration - 0.2, 0)))
        time = target
        // En streaming, une tolérance large évite de recharger un segment pour un écart minime.
        let tolerance = media.isStream ? CMTime(seconds: 1, preferredTimescale: 600) : .zero
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func set(rate newRate: Float) {
        rate = newRate
        if player.rate != 0 { player.rate = newRate }
    }

    /// Plafonne la résolution d'un flux adaptatif ; 0 laisse le lecteur choisir.
    func set(maxHeight height: Int) {
        maxHeight = height
        playerItem.preferredMaximumResolution = height > 0
            ? CGSize(width: CGFloat(height) * 16 / 9 * 1.4, height: CGFloat(height))
            : .zero
    }

    func select(subtitle track: PlayerSubtitle?, remember: Bool = true) {
        subtitleTask?.cancel()
        subtitle = track
        caption = ""
        cues = []
        if remember {
            // Les fichiers du disque ont leur propre préférence, pour ne pas écraser celle des vidéos YouTube.
            if media.localPath != nil {
                UserDefaults.standard.set(track?.label, forKey: "localSubtitleLabel")
            } else {
                UserDefaults.standard.set(track?.code, forKey: "subtitleLanguage")
            }
        }
        guard let track else { return }
        if track.url.isFileURL {
            if let text = try? String(contentsOf: track.url, encoding: .utf8) { cues = VTT.parse(text) }
            return
        }
        subtitleTask = Task { [weak self] in
            let loaded: [Cue]? = await {
                guard let (data, response) = try? await URLSession.shared.data(from: track.url),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return VTT.parse(String(decoding: data, as: UTF8.self))
            }()
            guard let self, !Task.isCancelled, self.subtitle == track else { return }
            if let loaded, !loaded.isEmpty {
                self.cues = loaded
            } else {
                self.subtitle = nil
                self.show(notice: "Sous-titres indisponibles pour l'instant : YouTube limite leur débit.")
            }
        }
    }

    private func show(notice text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    /// Liste les pistes audio et rétablit la langue choisie la dernière fois.
    private func loadAudioChoices(asset: AVURLAsset) async {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1 else { return }
        audioGroup = group
        audioChoices = group.options.enumerated().map { index, option in
            AudioChoice(id: index, label: option.displayName, language: option.extendedLanguageTag ?? option.locale?.identifier)
        }
        let preferred = UserDefaults.standard.string(forKey: "audioLanguage")
        if let preferred, let match = audioChoices.first(where: { Self.sameLanguage($0.language, preferred) }) {
            select(audio: match.id, remember: false)
        } else if let current = playerItem.currentMediaSelection.selectedMediaOption(in: group),
                  let index = group.options.firstIndex(of: current) {
            audioChoice = index
        } else {
            audioChoice = 0
        }
    }

    /// « fre », « fra » et « fr » désignent la même langue.
    private static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let fold: (String) -> String = { Locale(identifier: $0).language.languageCode?.identifier ?? String($0.prefix(2)).lowercased() }
        return fold(a) == fold(b)
    }

    func select(audio index: Int, remember: Bool = true) {
        guard let group = audioGroup, group.options.indices.contains(index) else { return }
        playerItem.select(group.options[index], in: group)
        audioChoice = index
        if remember, let language = audioChoices.first(where: { $0.id == index })?.language {
            UserDefaults.standard.set(language, forKey: "audioLanguage")
        }
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// Affiche les commandes, puis les masque après 3 s de lecture sans mouvement.
    func pokeControls() {
        if !controlsVisible { controlsVisible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying else { return }
            self.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func shutdown() -> Double {
        hideWork?.cancel()
        subtitleTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        timeObserver = nil
        keyMonitor = nil
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
        return time
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

// MARK: - Vue

struct PlayerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @StateObject private var model: PlayerModel

    init(media: PlayableMedia) {
        _model = StateObject(wrappedValue: PlayerModel(media: media))
    }

    private var media: PlayableMedia { model.media }

    var body: some View {
        ZStack {
            Color.black
            if media.kind == .audio {
                RemoteImage(urls: media.images).blur(radius: 50).opacity(0.5)
                Color.clear
                    .frame(width: 480, height: 270)
                    .overlay(RemoteImage(urls: media.images))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 30)
            } else {
                PlayerSurface(player: model.player)
            }

            // Zone de clic : lecture / pause, double clic : plein écran.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.toggleFullScreen() }
                .onTapGesture { model.togglePlay(); model.pokeControls() }

            if model.isBuffering, model.failed == nil {
                ProgressView().controlSize(.large).allowsHitTesting(false)
            }

            if !model.caption.isEmpty || model.notice != nil {
                VStack {
                    Spacer()
                    Text(model.notice ?? model.caption)
                        .font(.system(size: model.notice == nil ? 24 : 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black, radius: 3)
                        .padding(.horizontal, 80)
                        .padding(.bottom, model.controlsVisible ? 92 : 48)
                }
                .allowsHitTesting(false)
            }

            if let failed = model.failed {
                if media.isStream {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Lecture en streaming impossible",
                               message: "\(failed)\nLe lien fourni par YouTube a peut-être expiré : rouvrez la vidéo, ou téléchargez-la.",
                               actionTitle: "Fermer") { close() }
                } else {
                    EmptyState(symbol: "exclamationmark.triangle", title: "Lecture impossible",
                               message: media.localPath == nil ? failed
                                   : "\(failed)\nLe lecteur de macOS ne sait pas lire ce format vidéo.",
                               actionTitle: "Ouvrir dans le lecteur par défaut") {
                        NSWorkspace.shared.open(media.localPath.map(URL.init(fileURLWithPath:)) ?? media.url)
                        close()
                    }
                }
            }

            controls
                .opacity(model.controlsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: model.controlsVisible)
        }
        .onContinuousHover { phase in
            if case .active = phase { model.pokeControls() }
        }
        .onAppear { model.onClose = close }
        .onDisappear {
            savePosition()
            _ = model.shutdown()
        }
        // Quitter l'app pendant la lecture ne doit pas faire perdre la position.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            savePosition()
        }
    }

    /// Mémorise la position, sauf après un échec ou sans lecture réelle : un lien expiré
    /// laisserait sinon une position nulle écraser la précédente.
    private func savePosition() {
        guard model.failed == nil, model.time > 1 else { return }
        switch media.source {
        case .library(let id):
            library.updatePosition(id, position: model.time)
        case .stream:
            state.history.record(media.video, position: model.time, duration: model.duration)
        case .local(let path, _):
            state.local.record(path: path, position: model.time, duration: model.duration)
        }
    }

    private func close() {
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { model.toggleFullScreen() }
        state.playing = nil
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                playerButton("chevron.left", size: 15) { close() }
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.video.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(media.detailLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 36)
            .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))

            Spacer().allowsHitTesting(false)

            VStack(spacing: 4) {
                Scrubber(value: model.time, total: model.duration) { model.seek(to: $0); model.pokeControls() }

                HStack(spacing: 10) {
                    playerButton(model.isPlaying ? "pause.fill" : "play.fill", size: 17) { model.togglePlay() }
                    playerButton("gobackward.10", size: 15) { model.seek(by: -10) }
                    playerButton("goforward.10", size: 15) { model.seek(by: 10) }
                    if let next = media.nextLocalPath {
                        playerButton("forward.end.fill", size: 14) { Task { await state.playLocal(path: next) } }
                            .help("Épisode suivant")
                    }
                    HStack(spacing: 4) {
                        playerButton(model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13) {
                            model.volume = model.volume == 0 ? 1 : 0
                        }
                        Scrubber(value: Double(model.volume), total: 1, height: 2, tint: .white.opacity(0.75), thumb: 8) { model.volume = Float($0) }
                            .frame(width: 60)
                    }
                    Text("\(Fmt.duration(model.time).isEmpty ? "0:00" : Fmt.duration(model.time)) / \(Fmt.duration(model.duration))")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.leading, 6)
                    Spacer()
                    HStack(spacing: 16) {
                        if media.isStream { qualityMenu }
                        if model.audioChoices.count > 1 { audioMenu }
                        subtitleMenu
                        rateMenu
                    }
                    playerButton("arrow.up.left.and.arrow.down.right", size: 13) { model.toggleFullScreen() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 12)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func playerButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            model.pokeControls()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(_ text: String, _ symbol: String, dimmed: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .regular))
            .foregroundStyle(dimmed ? Theme.faint : Color.white.opacity(0.8))
    }

    private var qualityMenu: some View {
        Menu {
            ForEach([0, 1080, 720, 480, 360], id: \.self) { height in
                Button { model.set(maxHeight: height) } label: {
                    Label(height == 0 ? "Automatique" : "\(height)p maximum", systemImage: model.maxHeight == height ? "checkmark" : "")
                }
            }
        } label: {
            menuLabel((model.maxHeight == 0 ? "Auto" : "Max \(model.maxHeight)p")
                      + (model.videoHeight > 0 ? " · \(model.videoHeight)p" : ""), "dial.medium.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var audioMenu: some View {
        Menu {
            ForEach(model.audioChoices) { choice in
                Button { model.select(audio: choice.id) } label: {
                    Label(choice.label, systemImage: model.audioChoice == choice.id ? "checkmark" : "")
                }
            }
        } label: {
            menuLabel(model.audioChoices.first { $0.id == model.audioChoice }?.label ?? "Audio", "waveform")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var subtitleMenu: some View {
        Menu {
            Button { model.select(subtitle: nil) } label: {
                Label("Désactivés", systemImage: model.subtitle == nil ? "checkmark" : "")
            }
            ForEach(media.subtitles) { track in
                Button { model.select(subtitle: track) } label: {
                    Label(track.label, systemImage: model.subtitle == track ? "checkmark" : "")
                }
            }
        } label: {
            menuLabel(model.subtitle?.label ?? "Sous-titres", "captions.bubble.fill", dimmed: media.subtitles.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(media.subtitles.isEmpty)
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { value in
                Button { model.set(rate: value) } label: {
                    Label(value == 1 ? "Normale" : "×\(String(format: "%g", value))", systemImage: model.rate == value ? "checkmark" : "")
                }
            }
        } label: {
            menuLabel(model.rate == 1 ? "Vitesse" : "×\(String(format: "%g", model.rate))", "speedometer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Barre de progression cliquable et glissable.
struct Scrubber: View {
    let value: Double
    let total: Double
    var height: CGFloat = 3
    var tint: Color = Theme.accent
    var thumb: CGFloat = 10
    let onSeek: (Double) -> Void
    @State private var hover = false
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, max(0, (dragValue ?? value) / total)) : 0
            let active = hover || dragValue != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(tint).frame(width: geo.size.width * fraction)
                Circle()
                    .fill(tint)
                    .frame(width: thumb, height: thumb)
                    .offset(x: geo.size.width * fraction - thumb / 2)
                    .opacity(active ? 1 : 0)
            }
            // Fine au repos, un peu plus épaisse au survol pour rester facile à attraper.
            .frame(height: active ? height + 2 : height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragValue = min(1, max(0, gesture.location.x / geo.size.width)) * total
                    }
                    .onEnded { _ in
                        if let dragValue { onSeek(dragValue) }
                        dragValue = nil
                    }
            )
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .frame(height: 16)
    }
}
