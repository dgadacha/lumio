import SwiftUI

// Listes tenues par l'utilisateur : vidéos à regarder plus tard, chaînes suivies.
// Chacune a son propre fichier de données, pour ne jamais risquer ceux de la bibliothèque.

/// Vrai sous le pilote de test : aucune liste n'est alors écrite sur disque.
private var isTestRun: Bool { ProcessInfo.processInfo.environment["LUMIO_DEBUG"] != nil }

// MARK: - À regarder plus tard

@MainActor
final class WatchLater: ObservableObject {
    @Published private(set) var videos: [VideoSummary] = []
    private let file = Paths.support.appendingPathComponent("watch-later.json")

    init() {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([VideoSummary].self, from: data) else { return }
        videos = decoded
    }

    private func save() {
        guard !isTestRun, let data = try? JSONEncoder().encode(videos) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func contains(_ id: String) -> Bool { videos.contains { $0.id == id } }

    func toggle(_ video: VideoSummary) {
        if contains(video.id) {
            videos.removeAll { $0.id == video.id }
        } else {
            videos.insert(video, at: 0)
        }
        save()
    }

    func remove(_ id: String) {
        guard contains(id) else { return }
        videos.removeAll { $0.id == id }
        save()
    }
}

// MARK: - Abonnements

struct FollowedChannel: Codable, Hashable, Identifiable {
    /// Identifiant stable de la chaîne chez YouTube (commence par « UC »).
    let id: String
    var name: String

    var videosURL: String { "https://www.youtube.com/channel/\(id)/videos" }
}

@MainActor
final class Subscriptions: ObservableObject {
    @Published private(set) var channels: [FollowedChannel] = []
    /// Dernières vidéos des chaînes suivies, de la plus récente à la plus ancienne.
    @Published private(set) var feed: [VideoSummary] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private let file = Paths.support.appendingPathComponent("subscriptions.json")
    private let feedFile = Paths.support.appendingPathComponent("subscriptions-feed.json")
    private var feedDate: Date?
    /// Une demande de rechargement est arrivée pendant qu'un autre était en cours.
    private var refreshAgain = false

    private struct FeedCache: Codable {
        let date: Date
        let channelIDs: [String]
        let videos: [VideoSummary]
    }

    init() {
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([FollowedChannel].self, from: data) {
            channels = decoded
        }
        if let data = try? Data(contentsOf: feedFile),
           let cache = try? JSONDecoder().decode(FeedCache.self, from: data),
           Set(cache.channelIDs) == Set(channels.map(\.id)) {
            feed = cache.videos
            feedDate = cache.date
        }
    }

    private func save() {
        guard !isTestRun, let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func isFollowing(_ id: String?) -> Bool {
        guard let id else { return false }
        return channels.contains { $0.id == id }
    }

    func toggle(id: String, name: String) {
        if isFollowing(id) {
            channels.removeAll { $0.id == id }
            feed.removeAll { $0.channelID == id }
        } else {
            channels.append(FollowedChannel(id: id, name: name))
            channels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        save()
        Task { await refresh(force: true) }
    }

    /// Recharge les dernières vidéos de chaque chaîne suivie, quatre chaînes de front.
    /// Sans `force`, ne fait rien si le fil a moins d'une heure.
    func refresh(force: Bool) async {
        guard !loading else {
            // Le chargement en cours a été lancé avec l'ancienne liste de chaînes : il faudra le refaire.
            if force { refreshAgain = true }
            return
        }
        guard !channels.isEmpty else {
            feed = []
            return
        }
        if !force, let feedDate, Date().timeIntervalSince(feedDate) < 3600, !feed.isEmpty { return }
        loading = true
        error = nil
        refreshAgain = false
        defer {
            loading = false
            if refreshAgain { Task { await refresh(force: true) } }
        }

        let followed = channels
        var collected: [VideoSummary] = []
        var firstError: String?
        for start in stride(from: 0, to: followed.count, by: 4) {
            await withTaskGroup(of: ([VideoSummary], String?).self) { group in
                for channel in followed[start..<min(start + 4, followed.count)] {
                    group.addTask {
                        do { return (try await Engine.channelVideos(channel, limit: 8), nil) }
                        catch { return ([], error.localizedDescription) }
                    }
                }
                for await (videos, failure) in group {
                    collected += videos
                    if let failure, firstError == nil { firstError = failure }
                }
            }
        }
        // Une chaîne retirée pendant le chargement ne doit pas réapparaître dans le fil.
        let current = Set(channels.map(\.id))
        var seen = Set<String>()
        feed = collected
            .filter { current.contains($0.channelID ?? "") && seen.insert($0.id).inserted }
            .sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        feedDate = Date()
        if feed.isEmpty { error = firstError }
        if !isTestRun, !feed.isEmpty,
           let data = try? JSONEncoder().encode(FeedCache(date: Date(), channelIDs: channels.map(\.id), videos: feed)) {
            try? data.write(to: feedFile, options: .atomic)
        }
    }
}
