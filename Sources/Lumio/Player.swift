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

/// Panneaux qui s'ouvrent au-dessus des commandes du lecteur.
enum PlayerPanel: Hashable { case tracks, episodes, speed, quality }

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
    /// Secondes restantes avant l'enchaînement automatique sur l'épisode suivant ; nul hors compte à rebours.
    @Published var nextCountdown: Int?
    /// Panneau ouvert au-dessus des commandes (pistes, épisodes, vitesse, qualité).
    @Published var panel: PlayerPanel?
    var onNext: () -> Void = {}
    private var endObserver: NSObjectProtocol?
    private var countdownTask: Task<Void, Never>?
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
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
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
        DebugDriver.playerSetPanel = { [weak self] name in
            let panels: [String: PlayerPanel] = ["tracks": .tracks, "episodes": .episodes, "speed": .speed, "quality": .quality]
            self?.panel = panels[name]
            self?.pokeControls()
        }
        DebugDriver.playerSeekTo = { [weak self] seconds in self?.seek(to: seconds) }
        DebugDriver.playerSeekNearEnd = { [weak self] in
            guard let self, self.duration > 10 else { return }
            self.seek(to: self.duration - 4)
        }
        DebugDriver.playerReport = { [weak self] in
            guard let self else { return "lecteur fermé" }
            let item = self.playerItem
            return "statut=\(item.status.rawValue) temps=\(self.time) durée=\(self.duration) brut=\(self.player.currentTime().seconds) "
                + "image=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) contrôle=\(self.player.timeControlStatus.rawValue) "
                + "attente=\(self.player.reasonForWaitingToPlay?.rawValue ?? "-") échec=\(self.failed ?? "aucun") "
                + "erreur=\(item.error?.localizedDescription ?? "aucune") journal=\(item.errorLog()?.events.last?.errorComment ?? "-") reprise=\(self.media.startPosition) "
                + "détail=\((item.error as NSError?).map { "\($0.domain) \($0.code) sous-jacente=\(($0.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "-") raison=\($0.localizedFailureReason ?? "-")" } ?? "-") "
                + "audio=\(self.audioChoices.map(\.label)) choisie=\(self.audioChoice.map(String.init) ?? "-") fichier=\(self.media.url.lastPathComponent) "
                + "sous-titre=\(self.subtitle?.label ?? "aucun") texte=\(self.caption.count)c compte=\(self.nextCountdown.map(String.init) ?? "-")"
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
            // Échap ferme d'abord le panneau ouvert, puis le plein écran, puis le lecteur.
            if panel != nil { panel = nil }
            else if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen() }
            else { onClose() }
        default: return true
        }
        pokeControls()
        return false
    }

    func togglePlay() {
        cancelNext() // l'utilisateur reprend la main : pas d'enchaînement automatique
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
        cancelNext() // un déplacement pendant le compte à rebours l'annule
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

    /// Fin de l'épisode : s'il y en a un suivant, il démarre après un court compte à rebours annulable.
    private func reachedEnd() {
        isPlaying = false
        controlsVisible = true
        let enabled = UserDefaults.standard.object(forKey: "autoplayNext") as? Bool ?? true
        guard enabled, media.nextLocalPath != nil, nextCountdown == nil else { return }
        nextCountdown = 6
        countdownTask = Task { [weak self] in
            while let remaining = self?.nextCountdown, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, self.nextCountdown != nil else { return }
                self.nextCountdown = remaining - 1
            }
            guard !Task.isCancelled, let self, self.nextCountdown == 0 else { return }
            self.nextCountdown = nil
            self.onNext()
        }
    }

    func cancelNext() {
        countdownTask?.cancel()
        nextCountdown = nil
    }

    func playNextNow() {
        countdownTask?.cancel()
        nextCountdown = nil
        onNext()
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// Affiche les commandes, puis les masque après 3 s de lecture sans mouvement.
    func pokeControls() {
        if !controlsVisible { controlsVisible = true }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying, self.nextCountdown == nil, self.panel == nil else { return }
            self.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func shutdown() -> Double {
        hideWork?.cancel()
        subtitleTask?.cancel()
        countdownTask?.cancel()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
    @EnvironmentObject var local: LocalLibrary
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
                .onTapGesture {
                    // Un clic dans l'image ferme d'abord le panneau ouvert.
                    if model.panel != nil { model.panel = nil } else { model.togglePlay() }
                    model.pokeControls()
                }

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
                        .padding(.bottom, model.controlsVisible ? 104 : 48)
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

            if let panel = model.panel {
                panelView(panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 22)
                    .padding(.bottom, 92)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let countdown = model.nextCountdown {
                nextCard(countdown)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 28)
                    .padding(.bottom, 84)
                    .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { model.pokeControls() }
        }
        .onAppear {
            model.onClose = close
            model.onNext = {
                guard let next = media.nextLocalPath else { return }
                Task { await state.playLocal(path: next) }
            }
        }
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

    private func nextCard(_ countdown: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Épisode suivant dans \(countdown) s").font(.system(size: 13.5, weight: .semibold))
            HStack(spacing: 8) {
                Button { model.playNextNow() } label: { Label("Lire", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Annuler") { model.cancelNext() }
                    .buttonStyle(PrimaryButtonStyle(fill: Color.white.opacity(0.16), text: .white))
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.14)))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                playerButton("chevron.left", size: 18) { close() }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 30)
            .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom))

            Spacer().allowsHitTesting(false)

            VStack(spacing: 10) {
                // Barre de progression d'un trait, avec le temps restant à droite.
                HStack(spacing: 12) {
                    Scrubber(value: model.time, total: model.duration) { model.seek(to: $0); model.pokeControls() }
                    Text(Fmt.duration(max(model.duration - model.time, 0)).isEmpty ? "0:00" : Fmt.duration(max(model.duration - model.time, 0)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }

                HStack(spacing: 22) {
                    HStack(spacing: 22) {
                        playerButton(model.isPlaying ? "pause.fill" : "play.fill", size: 25) { model.togglePlay() }
                        playerButton("gobackward.10", size: 23) { model.seek(by: -10) }
                        playerButton("goforward.10", size: 23) { model.seek(by: 10) }
                        VolumeControl(model: model)
                    }

                    // Titre entre les deux groupes de boutons : tronqué s'il est long, jamais dessous.
                    (Text(media.video.title).fontWeight(.semibold)
                     + Text(media.localPath == nil ? "" : "   \(media.detailLine)").fontWeight(.regular))
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)

                    HStack(spacing: 22) {
                        if let next = media.nextLocalPath {
                            playerButton("forward.end", size: 23) { Task { await state.playLocal(path: next) } }
                                .help("Épisode suivant")
                        }
                        if currentSeries != nil {
                            panelButton(.episodes, "rectangle.stack", help: "Épisodes")
                        }
                        if media.isStream { panelButton(.quality, "dial.medium", help: "Qualité") }
                        if !media.subtitles.isEmpty || model.audioChoices.count > 1 {
                            panelButton(.tracks, model.subtitle == nil ? "captions.bubble" : "captions.bubble.fill",
                                        help: "Audio et sous-titres")
                        }
                        panelButton(.speed, "speedometer", help: "Vitesse")
                        playerButton("arrow.up.left.and.arrow.down.right", size: 20) { model.toggleFullScreen() }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 44)
            .padding(.bottom, 20)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func playerButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            model.pokeControls()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Panneaux

    /// Série du disque à laquelle appartient l'épisode en cours, s'il y en a une.
    private var currentSeries: LocalSeries? {
        guard let path = media.localPath else { return nil }
        return local.catalog.series.first { series in series.episodes.contains { $0.path == path } }
    }

    private func panelButton(_ panel: PlayerPanel, _ symbol: String, help: String) -> some View {
        Button {
            model.panel = model.panel == panel ? nil : panel
            model.pokeControls()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .scaleEffect(model.panel == panel ? 1.15 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .animation(.easeOut(duration: 0.12), value: model.panel)
    }

    @ViewBuilder
    private func panelView(_ panel: PlayerPanel) -> some View {
        Group {
            switch panel {
            case .tracks: tracksPanel
            case .episodes: if let series = currentSeries { EpisodesPanel(series: series, currentPath: media.localPath ?? "") }
            case .speed: speedPanel
            case .quality: qualityPanel
            }
        }
        .background(Color(white: 0.14).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
        // Un clic dans le panneau ne doit pas atteindre l'image, qui le fermerait.
        .onTapGesture {}
    }

    /// Audio et sous-titres côte à côte, la piste active cochée.
    private var tracksPanel: some View {
        HStack(alignment: .top, spacing: 0) {
            if model.audioChoices.count > 1 {
                PanelColumn(title: "Audio") {
                    ForEach(model.audioChoices) { choice in
                        PanelRow(label: choice.label, selected: model.audioChoice == choice.id) { model.select(audio: choice.id) }
                    }
                }
            }
            if !media.subtitles.isEmpty {
                PanelColumn(title: "Sous-titres") {
                    PanelRow(label: "Désactivés", selected: model.subtitle == nil) { model.select(subtitle: nil) }
                    ForEach(media.subtitles) { track in
                        PanelRow(label: track.label, selected: model.subtitle == track) { model.select(subtitle: track) }
                    }
                }
            }
        }
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var speedPanel: some View {
        PanelColumn(title: "Vitesse") {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { value in
                PanelRow(label: value == 1 ? "Normale" : "×\(String(format: "%g", value))", selected: model.rate == value) {
                    model.set(rate: value)
                }
            }
        }
    }

    private var qualityPanel: some View {
        PanelColumn(title: "Qualité") {
            ForEach([0, 1080, 720, 480, 360], id: \.self) { height in
                PanelRow(label: height == 0 ? "Automatique" : "\(height)p au plus", selected: model.maxHeight == height) {
                    model.set(maxHeight: height)
                }
            }
            if model.videoHeight > 0 {
                Text("Actuellement : \(model.videoHeight)p")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 22).padding(.top, 6)
            }
        }
    }
}

/// Colonne titrée d'un panneau du lecteur.
struct PanelColumn<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 10)
            // Le panneau épouse son contenu ; il ne défile que si la liste est trop longue.
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Ligne cochable d'un panneau : blanche et cochée si active, atténuée sinon.
struct PanelRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 16)
            }
            .foregroundStyle(selected || hover ? Color.white : Color.white.opacity(0.62))
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Color.white.opacity(hover ? 0.08 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Liste des épisodes de la série en cours : l'épisode lu est déployé, un clic lance un autre épisode.
struct EpisodesPanel: View {
    let series: LocalSeries
    let currentPath: String
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary
    @State private var season: Int?

    private var currentSeason: Int { series.episodes.first { $0.path == currentPath }?.season ?? series.seasons.first ?? 1 }

    var body: some View {
        let shown = season ?? currentSeason
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Spacer()
                if series.seasons.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(series.seasons, id: \.self) { number in
                            Button("S\(number)") { season = number }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: shown == number ? .bold : .regular))
                                .foregroundStyle(shown == number ? Color.white : Color.white.opacity(0.55))
                        }
                    }
                } else {
                    Text("Saison \(shown)").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(series.episodes(in: shown)) { episode in
                            EpisodePanelRow(episode: episode, current: episode.path == currentPath)
                                .id(episode.path)
                        }
                    }
                    .padding(.bottom, 10)
                }
                .onAppear { proxy.scrollTo(currentPath, anchor: .center) }
            }
        }
        .frame(width: 470)
        .frame(maxHeight: 460)
    }
}

struct EpisodePanelRow: View {
    let episode: LocalEpisode
    let current: Bool
    @EnvironmentObject var state: AppState
    @EnvironmentObject var local: LocalLibrary
    @State private var hover = false
    @State private var duration: Double = 0

    var body: some View {
        let position = local.position(for: episode.path)
        Button {
            guard !current else { return }
            Task { await state.playLocal(path: episode.path) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text("\(episode.number)").font(.system(size: 16, weight: .semibold).monospacedDigit()).frame(width: 26, alignment: .trailing)
                    Text(episode.label).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if state.localPreparing == episode.path { ProgressView().controlSize(.small) }
                    Spacer(minLength: 12)
                    // Trait de progression de l'épisode.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.white.opacity(0.3)
                            Theme.accent.frame(width: geo.size.width * (position?.finished == true ? 1 : (position?.progress ?? 0)))
                        }
                    }
                    .frame(width: 70, height: 2)
                }
                if current {
                    HStack(alignment: .top, spacing: 14) {
                        Color.clear
                            .frame(width: 150, height: 84)
                            .overlay(LocalThumb(path: episode.path))
                            .overlay(Color.black.opacity(0.45))
                            .overlay {
                                Label("Lecture en cours", systemImage: "waveform")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        VStack(alignment: .leading, spacing: 5) {
                            if duration > 0 {
                                Text(Fmt.longDuration(duration)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            }
                            Text("\(Fmt.bytes(episode.size)) · \(URL(fileURLWithPath: episode.path).pathExtension.uppercased())")
                                .font(.system(size: 12)).foregroundStyle(Theme.dim)
                        }
                    }
                    .padding(.leading, 40)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, current ? 16 : 13)
            .background(Color.white.opacity(current ? 0.06 : (hover ? 0.08 : 0)))
            .overlay { if current { Rectangle().stroke(Color.white.opacity(0.85), lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.localPreparing != nil)
        .onHover { hover = $0 }
        .task(id: episode.path) { if current { duration = await MediaInspector.shared.probe(episode.path)?.duration ?? 0 } }
    }
}

/// Haut-parleur seul au repos ; le curseur de volume se déploie au survol.
struct VolumeControl: View {
    @ObservedObject var model: PlayerModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.volume = model.volume == 0 ? 1 : 0
                model.pokeControls()
            } label: {
                Image(systemName: model.volume == 0 ? "speaker.slash" : (model.volume < 0.5 ? "speaker.wave.1" : "speaker.wave.2"))
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hover {
                Scrubber(value: Double(model.volume), total: 1, tint: .white, thumb: 9) { model.volume = Float($0) }
                    .frame(width: 70)
                    .transition(.opacity)
            }
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// Barre de progression cliquable et glissable.
struct Scrubber: View {
    let value: Double
    let total: Double
    /// Épaisseur du rail ; la partie lue est un point plus épaisse, pour rester lisible sur un rail très fin.
    var height: CGFloat = 1
    var tint: Color = Theme.accent
    var thumb: CGFloat = 10
    /// Curseur rond visible en permanence (barre de progression) ou seulement au survol (volume).
    var showsThumb = true
    let onSeek: (Double) -> Void
    @State private var hover = false
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, max(0, (dragValue ?? value) / total)) : 0
            let active = hover || dragValue != nil
            let size = active ? thumb + 3 : thumb
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.45)).frame(height: height)
                Rectangle().fill(tint).frame(width: geo.size.width * fraction, height: height + 1)
                Circle()
                    .fill(tint)
                    .frame(width: size, height: size)
                    .offset(x: min(max(geo.size.width * fraction - size / 2, 0), geo.size.width - size))
                    .opacity(showsThumb || active ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            // Zone de clic bien plus haute que le trait : il reste facile à attraper.
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
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 18)
    }
}
