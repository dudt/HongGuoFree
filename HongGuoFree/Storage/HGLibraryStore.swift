// 追剧 / 历史：只存红果 seriesID，不依赖演示数据的 Drama 模型
import Foundation
import Combine

/// 一条追剧记录
struct HGRecord: Codable, Identifiable, Hashable {
    var seriesID: String
    var title: String
    var cover: String?
    var episodeCount: Int?
    var lastEpisode: Int?
    var updatedAt: Date

    var id: String { seriesID }
}

@MainActor
final class HGLibraryStore: ObservableObject {
    private enum Key {
        static let favorites = "hg.favorites"
        static let history = "hg.history"
    }

    private let defaults = UserDefaults.standard
    private var bag = Set<AnyCancellable>()

    @Published private(set) var favorites: [HGRecord] = []
    @Published private(set) var history: [HGRecord] = []

    init() {
        favorites = Self.load(from: defaults, key: Key.favorites)
        history = Self.load(from: defaults, key: Key.history)
    }

    // MARK: 收藏

    func isFavorite(_ seriesID: String) -> Bool {
        favorites.contains { $0.seriesID == seriesID }
    }

    func toggleFavorite(_ item: HGFeedItem) {
        if let idx = favorites.firstIndex(where: { $0.seriesID == item.seriesID }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(
                HGRecord(
                    seriesID: item.seriesID,
                    title: item.title ?? "未命名",
                    cover: item.cover,
                    episodeCount: item.episodeCount,
                    lastEpisode: nil,
                    updatedAt: Date()
                ),
                at: 0
            )
        }
        persist(favorites, key: Key.favorites)
    }

    // MARK: 历史

    func touchHistory(_ item: HGFeedItem, episode: Int?) {
        let rec = HGRecord(
            seriesID: item.seriesID,
            title: item.title ?? "未命名",
            cover: item.cover,
            episodeCount: item.episodeCount,
            lastEpisode: episode,
            updatedAt: Date()
        )
        history.removeAll { $0.seriesID == item.seriesID }
        history.insert(rec, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        persist(history, key: Key.history)
    }

    func record(for seriesID: String) -> HGRecord? {
        history.first { $0.seriesID == seriesID }
    }

    func removeHistory(_ seriesID: String) {
        history.removeAll { $0.seriesID == seriesID }
        persist(history, key: Key.history)
    }

    func clearHistory() {
        history.removeAll()
        persist(history, key: Key.history)
    }

    func removeFavorite(_ seriesID: String) {
        favorites.removeAll { $0.seriesID == seriesID }
        persist(favorites, key: Key.favorites)
    }

    // MARK: 持久化

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [HGRecord] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([HGRecord].self, from: data) else {
            return []
        }
        return list
    }
}
