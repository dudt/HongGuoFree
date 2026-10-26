// 追剧 / 历史 / 播放进度
import Foundation
import Combine

/// 一条追剧记录
struct HGRecord: Codable, Identifiable, Hashable {
    var seriesID: String
    var title: String
    var cover: String?
    var episodeCount: Int?
    var lastEpisode: Int?
    /// 该集的播放位置（秒）
    var position: Double?
    /// 该集总时长（秒）
    var duration: Double?
    var updatedAt: Date

    var id: String { seriesID }

    /// 0~1
    var progressRatio: Double {
        guard let p = position, let d = duration, d > 0 else { return 0 }
        return min(max(p / d, 0), 1)
    }

    var progressText: String {
        guard let p = position, p > 1 else { return "" }
        let s = Int(p)
        let m = s / 60, ss = s % 60
        return String(format: "%d:%02d", m, ss)
    }
}

@MainActor
final class HGLibraryStore: ObservableObject {
    private enum Key {
        static let favorites = "hg.favorites.v2"
        static let history = "hg.history.v2"
    }

    private let defaults = UserDefaults.standard

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
                HGRecord(seriesID: item.seriesID,
                         title: item.title ?? "未命名",
                         cover: item.cover,
                         episodeCount: item.episodeCount,
                         lastEpisode: nil, position: nil, duration: nil,
                         updatedAt: Date()),
                at: 0
            )
        }
        persist(favorites, key: Key.favorites)
    }

    // MARK: 历史

    /// 开始/切换集时调用
    func touchHistory(_ item: HGFeedItem, episode: Int?) {
        if let idx = history.firstIndex(where: { $0.seriesID == item.seriesID }) {
            var r = history[idx]
            if let e = episode { r.lastEpisode = e }
            r.title = item.title ?? r.title
            if let c = item.cover { r.cover = c }
            if let n = item.episodeCount { r.episodeCount = n }
            r.updatedAt = Date()
            // 换集时清掉旧进度
            if let e = episode, e != history[idx].lastEpisode {
                r.position = nil
                r.duration = nil
            }
            history.remove(at: idx)
            history.insert(r, at: 0)
        } else {
            history.insert(
                HGRecord(seriesID: item.seriesID,
                         title: item.title ?? "未命名",
                         cover: item.cover,
                         episodeCount: item.episodeCount,
                         lastEpisode: episode, position: nil, duration: nil,
                         updatedAt: Date()),
                at: 0
            )
        }
        if history.count > 120 { history.removeLast(history.count - 120) }
        persist(history, key: Key.history)
    }

    /// 播放过程中定期保存进度
    func saveProgress(seriesID: String, episode: Int, position: Double, duration: Double) {
        guard position.isFinite, position > 1, duration.isFinite, duration > 5 else { return }
        // 快播完就不记了（避免下次打开又从头）
        let ratio = position / duration
        guard ratio < 0.97 else {
            if let idx = history.firstIndex(where: { $0.seriesID == seriesID }) {
                var r = history[idx]
                r.position = nil
                r.duration = nil
                r.updatedAt = Date()
                history[idx] = r
                persist(history, key: Key.history)
            }
            return
        }

        if let idx = history.firstIndex(where: { $0.seriesID == seriesID }) {
            var r = history[idx]
            r.lastEpisode = episode
            r.position = position
            r.duration = duration
            r.updatedAt = Date()
            history[idx] = r
        } else {
            return
        }
        persist(history, key: Key.history)
    }

    func record(for seriesID: String) -> HGRecord? {
        history.first { $0.seriesID == seriesID }
    }

    /// 最近观看（首页卡片用）
    func continueWatching(limit: Int = 6) -> [HGRecord] {
        Array(history.filter { ($0.lastEpisode ?? 0) > 0 }.prefix(limit))
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
