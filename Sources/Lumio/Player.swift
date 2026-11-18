import SwiftUI
import AVKit

@MainActor
final class PlayerModel: ObservableObject {
    let item: LibraryItem
    let player = AVPlayer()

    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var caption = ""
    @Published var subtitle: LocalSubtitle?
    @Published var rate: Float = 1
    @Published var volume: Float = 1 { didSet { player.volume = volume } }
    @Published var controlsVisible = true
    @Published var failed: String?

    var onClose: () -> Void = {}
    private var cues: [Cue] = []
    private var timeObserver: Any?
    private var keyMonitor: Any?
    private var statusObserver: NSKeyValueObservation?
    private var hideWork: DispatchWorkItem?

    init(item: LibraryItem) {
        self.item = item
        duration = item.duration ?? 0
        let asset = AVURLAsset(url: item.mediaURL)
        let playerItem = AVPlayerItem(asset: asset)
        // Les sous-titres sont dessinés par l'app : on coupe ceux intégrés au fichier pour éviter le doublon.
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.replaceCurrentItem(with: playerItem)
        Task {
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                playerItem.select(nil, in: group)
            }
            if let loaded = try? await asset.load(.duration), loaded.seconds.isFinite, loaded.seconds > 0 {
                duration = loaded.seconds
            }
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
        if item.position > 5 {
            player.seek(to: CMTime(seconds: item.position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            time = item.position
        }
        let preferred = UserDefaults.standard.string(forKey: "subtitleLanguage")
        if let preferred, let match = item.subtitles.first(where: { $0.code == preferred }) {
            select(subtitle: match, remember: false)
        }
        player.play()
        isPlaying = true
        pokeControls()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        time = seconds
        isPlaying = player.rate != 0
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
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func set(rate newRate: Float) {
        rate = newRate
        if player.rate != 0 { player.rate = newRate }
    }

    func select(subtitle track: LocalSubtitle?, remember: Bool = true) {
        subtitle = track
        caption = ""
        cues = []
        if remember { UserDefaults.standard.set(track?.code, forKey: "subtitleLanguage") }
        guard let track,
              let text = try? String(contentsOf: item.folderURL.appendingPathComponent(track.file), encoding: .utf8) else { return }
        cues = VTT.parse(text)
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
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        timeObserver = nil
        keyMonitor = nil
        statusObserver = nil
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

struct PlayerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: Library
    @StateObject private var model: PlayerModel

    init(item: LibraryItem) {
        _model = StateObject(wrappedValue: PlayerModel(item: item))
    }

    var body: some View {
        ZStack {
            Color.black
            if model.item.kind == .audio {
                RemoteImage(urls: model.item.images).blur(radius: 50).opacity(0.5)
                Color.clear
                    .frame(width: 480, height: 270)
                    .overlay(RemoteImage(urls: model.item.images))
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

            if !model.caption.isEmpty {
                VStack {
                    Spacer()
                    Text(model.caption)
                        .font(.system(size: 26, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black, radius: 3)
                        .padding(.horizontal, 80)
                        .padding(.bottom, model.controlsVisible ? 132 : 56)
                }
                .allowsHitTesting(false)
            }

            if let failed = model.failed {
                EmptyState(symbol: "exclamationmark.triangle", title: "Lecture impossible", message: failed,
                           actionTitle: "Ouvrir dans le lecteur par défaut") {
                    NSWorkspace.shared.open(model.item.mediaURL)
                    close()
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
        .onDisappear { library.updatePosition(model.item.id, position: model.shutdown()) }
    }

    private func close() {
        if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { model.toggleFullScreen() }
        state.playing = nil
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                IconButton(symbol: "chevron.left", size: 17) { close() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.item.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    Text([model.item.channel, model.item.quality].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))

            Spacer().allowsHitTesting(false)

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Text(Fmt.duration(model.time).isEmpty ? "0:00" : Fmt.duration(model.time))
                    Scrubber(value: model.time, total: model.duration) { model.seek(to: $0); model.pokeControls() }
                    Text(Fmt.duration(model.duration))
                }
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())

                HStack(spacing: 22) {
                    playerButton(model.isPlaying ? "pause.fill" : "play.fill", size: 26) { model.togglePlay() }
                    playerButton("gobackward.10", size: 21) { model.seek(by: -10) }
                    playerButton("goforward.10", size: 21) { model.seek(by: 10) }
                    HStack(spacing: 8) {
                        playerButton(model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 17) {
                            model.volume = model.volume == 0 ? 1 : 0
                        }
                        Scrubber(value: Double(model.volume), total: 1, height: 4) { model.volume = Float($0) }
                            .frame(width: 90)
                    }
                    Spacer()
                    subtitleMenu
                    rateMenu
                    playerButton("arrow.up.left.and.arrow.down.right", size: 17) { model.toggleFullScreen() }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 60)
            .padding(.bottom, 24)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func playerButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            model.pokeControls()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitleMenu: some View {
        Menu {
            Button { model.select(subtitle: nil) } label: {
                Label("Désactivés", systemImage: model.subtitle == nil ? "checkmark" : "")
            }
            ForEach(model.item.subtitles) { track in
                Button { model.select(subtitle: track) } label: {
                    Label(Fmt.language(track.code), systemImage: model.subtitle == track ? "checkmark" : "")
                }
            }
        } label: {
            Label(model.subtitle.map { Fmt.language($0.code) } ?? "Sous-titres", systemImage: "captions.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.item.subtitles.isEmpty ? Theme.faint : .white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.item.subtitles.isEmpty)
    }

    private var rateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { value in
                Button { model.set(rate: value) } label: {
                    Label(value == 1 ? "Normale" : "×\(String(format: "%g", value))", systemImage: model.rate == value ? "checkmark" : "")
                }
            }
        } label: {
            Label(model.rate == 1 ? "Vitesse" : "×\(String(format: "%g", model.rate))", systemImage: "speedometer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
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
    var height: CGFloat = 5
    let onSeek: (Double) -> Void
    @State private var hover = false
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = total > 0 ? min(1, max(0, (dragValue ?? value) / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                Capsule().fill(Theme.accent).frame(width: geo.size.width * fraction)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * fraction - 7)
                    .opacity(hover || dragValue != nil ? 1 : 0)
            }
            .frame(height: hover || dragValue != nil ? height + 2 : height)
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
        .frame(height: 18)
    }
}
