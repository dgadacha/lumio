import SwiftUI
import AppKit

// MARK: - Thème

enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let surface2 = Color(red: 0.15, green: 0.15, blue: 0.17)
    /// Couleur du logo (#FA3C20) : l'accent de l'app s'aligne dessus.
    static let accent = Color(red: 0.98, green: 0.235, blue: 0.125)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)
}

// MARK: - Emplacements

enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let engineDir = support.appendingPathComponent("engine", isDirectory: true)

    static var downloads: URL {
        if let custom = UserDefaults.standard.string(forKey: "downloadDir"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumio", isDirectory: true)
    }
}

// MARK: - Mise en forme

enum Fmt {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func longDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return m > 0 ? "\(m) min" : "\(s) s"
    }

    static func views(_ count: Int?) -> String {
        guard let count else { return "" }
        let n = Double(count)
        let text: String
        if n >= 1_000_000_000 { text = String(format: "%.1f Md", n / 1_000_000_000) }
        else if n >= 1_000_000 { text = String(format: "%.1f M", n / 1_000_000) }
        else if n >= 1_000 { text = String(format: "%.0f k", n / 1_000) }
        else { text = "\(count)" }
        return text.replacingOccurrences(of: ".0", with: "").replacingOccurrences(of: ".", with: ",") + " vues"
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count, count > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func language(_ code: String) -> String {
        let clean = code.replacingOccurrences(of: "-orig", with: "")
        let name = Locale(identifier: "fr_FR").localizedString(forIdentifier: clean) ?? clean
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "20261026" -> "2026"
    static func year(_ uploadDate: String?) -> String {
        guard let uploadDate, uploadDate.count >= 4 else { return "" }
        return String(uploadDate.prefix(4))
    }
}

// MARK: - Exécution de processus

struct ProcResult {
    let status: Int32
    let out: Data
    let err: String
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum ProcessRunner {
    /// Lance un exécutable, lit stdout et stderr sans risque d'interblocage.
    /// `onLine` reçoit chaque ligne (stdout et stderr), depuis un fil d'arrière-plan.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        env: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
        register: (@Sendable (Process) -> Void)? = nil
    ) async throws -> ProcResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let env { process.environment = env }
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                register?(process)

                let outBox = DataBox(), errBox = DataBox()
                let group = DispatchGroup()
                for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        var pending = Data()
                        let handle = pipe.fileHandleForReading
                        while true {
                            let chunk = handle.availableData
                            if chunk.isEmpty { break }
                            box.data.append(chunk)
                            guard let onLine else { continue }
                            pending.append(chunk)
                            while let newline = pending.firstIndex(of: 10) {
                                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                                pending = Data(pending[pending.index(after: newline)...])
                                onLine(line)
                            }
                        }
                        if let onLine, !pending.isEmpty {
                            onLine(String(decoding: pending, as: UTF8.self))
                        }
                        group.leave()
                    }
                }
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: ProcResult(
                    status: process.terminationStatus,
                    out: outBox.data,
                    err: String(decoding: errBox.data, as: UTF8.self)
                ))
            }
        }
    }
}

// MARK: - Images

actor ImageStore {
    static let shared = ImageStore()
    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        cache.countLimit = 400
    }

    /// Essaie chaque URL dans l'ordre et renvoie la première image valide.
    func load(_ urls: [URL]) async -> NSImage? {
        for url in urls {
            let key = url.absoluteString as NSString
            if let hit = cache.object(forKey: key) { return hit }
            if url.isFileURL {
                if let image = NSImage(contentsOf: url) {
                    cache.setObject(image, forKey: key)
                    return image
                }
                continue
            }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data),
                  (image.representations.first?.pixelsWide ?? Int(image.size.width)) > 160
            else { continue }
            cache.setObject(image, forKey: key)
            return image
        }
        return nil
    }
}

struct RemoteImage: View {
    let urls: [URL]
    /// Fond affiché tant que l'image n'est pas chargée ; transparent pour laisser voir ce qu'il y a dessous.
    var placeholder: Color = Theme.surface2
    @State private var image: NSImage?

    var body: some View {
        placeholder
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: urls) {
                let loaded = await ImageStore.shared.load(urls)
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }
}

/// Image distante qui n'occupe aucune place tant qu'elle n'est pas chargée (affiche facultative).
struct OptionalRemoteImage<Footer: View>: View {
    let url: URL
    let size: CGSize
    @ViewBuilder var footer: Footer
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                VStack(alignment: .leading, spacing: 4) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    footer
                }
            }
        }
        .task(id: url) { image = await ImageStore.shared.load([url]) }
    }
}

// MARK: - Mise en page en flux (puces)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (points, maxWidth, y + rowHeight)
    }
}

// MARK: - Composants communs

struct Chip: View {
    let label: String
    var detail: String? = nil
    let selected: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).opacity(0.7)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Color.black : Color.white)
            .background(selected ? Color.white : Color.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(selected ? 0 : 0.14)))
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = .white
    var text: Color = .black

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(text)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 15
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 2.3, height: size * 2.3)
                .background(Color.white.opacity(hover ? 0.2 : 0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
