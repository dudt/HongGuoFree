// 持久化：设置、收藏、历史、播放进度
import Foundation
import SwiftUI
import Combine

// MARK: - 设置

final class SettingsStore: ObservableObject {
    private enum Key {
        static let feedURL = "app.feedURL"
        static let autoplayNext = "app.autoplayNext"
        static let loopEpisode = "app.loopEpisode"
        static let rememberProgress = "app.rememberProgress"
        static let playbackRate = "app.playbackRate"
        static let preferQuality = "app.preferQuality"
        static let resolverBaseURL = "app.resolverBaseURL"
        static let resolverToken = "app.resolverToken"
    }

    private let defaults = UserDefaults.standard
    private var bag = Set<AnyCancellable>()

    @Published var feedURLString: String
    @Published var autoplayNext: Bool
    @Published var loopEpisode: Bool
    @Published var rememberProgress: Bool
    @Published var playbackRate: Double
    @Published var preferQuality: String

    /// 自建解析服务地址（server/hongguo-server.mjs）
    @Published var resolverBaseURL: String
    /// 服务端 ACCESS_TOKEN（可选）
    @Published var resolverToken: String

    /// 组装好的解析服务配置
    var resolverConfig: ResolverConfig {
        ResolverConfig(baseURL: resolverBaseURL, token: resolverToken)
    }

    /// 是否已配置解析服务
    var hasResolver: Bool { resolverConfig.isConfigured }

    init() {
        defaults.register(defaults: [
            Key.autoplayNext: true,
            Key.loopEpisode: false,
            Key.rememberProgress: true,
            Key.playbackRate: 1.0,
            Key.preferQuality: "自动",
            Key.resolverBaseURL: "",
            Key.resolverToken: ""
        ])

        let storedRate = defaults.double(forKey: Key.playbackRate)
        feedURLString = defaults.string(forKey: Key.feedURL) ?? ""
        autoplayNext = defaults.bool(forKey: Key.autoplayNext)
        loopEpisode = defaults.bool(forKey: Key.loopEpisode)
        rememberProgress = defaults.bool(forKey: Key.rememberProgress)
        playbackRate = storedRate == 0 ? 1.0 : storedRate
        preferQuality = defaults.string(forKey: Key.preferQuality) ?? "自动"
        resolverBaseURL = defaults.string(forKey: Key.resolverBaseURL) ?? ""
        resolverToken = defaults.string(forKey: Key.resolverToken) ?? ""

        bindPersistence()
    }

    /// 任何设置变化都写回 UserDefaults（避免给 @Published 加 didSet）
    private func bindPersistence() {
        $feedURLString
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.feedURL) }
            .store(in: &bag)
        $autoplayNext
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.autoplayNext) }
            .store(in: &bag)
        $loopEpisode
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.loopEpisode) }
            .store(in: &bag)
        $rememberProgress
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.rememberProgress) }
            .store(in: &bag)
        $playbackRate
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.playbackRate) }
            .store(in: &bag)
        $preferQuality
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.preferQuality) }
            .store(in: &bag)
        $resolverBaseURL
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.resolverBaseURL) }
            .store(in: &bag)
        $resolverToken
            .sink { [weak self] in self?.defaults.set($0, forKey: Key.resolverToken) }
            .store(in: &bag)
    }

    var customFeedURL: URL? {
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

// MARK: - 收藏 / 历史 / 进度

final class LibraryStore: ObservableObject {
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var history: [String] = []
    @Published private(set) var records: [String: PlaybackRecord] = [:]

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.hongguofree.library", qos: .utility)

    private struct Snapshot: Codable {
        var favorites: [String]
        var history: [String]
        var records: [String: PlaybackRecord]
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("HongGuoFree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        load()
    }

    func isFavorite(_ dramaID: String) -> Bool { favorites.contains(dramaID) }

    func toggleFavorite(_ dramaID: String) {
        if favorites.contains(dramaID) {
            favorites.remove(dramaID)
        } else {
            favorites.insert(dramaID)
        }
        persist()
    }

    func touchHistory(_ dramaID: String) {
        history.removeAll { $0 == dramaID }
        history.insert(dramaID, at: 0)
        if history.count > 60 { history = Array(history.prefix(60)) }
        persist()
    }

    func record(for dramaID: String) -> PlaybackRecord? { records[dramaID] }

    func save(_ record: PlaybackRecord) {
        records[record.dramaID] = record
        persist()
    }

    func clearProgress(for dramaID: String) {
        records.removeValue(forKey: dramaID)
        persist()
    }

    func clearAll() {
        favorites.removeAll()
        history.removeAll()
        records.removeAll()
        persist()
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = Set(snapshot.favorites)
        history = snapshot.history
        records = snapshot.records
    }

    private func persist() {
        let snapshot = Snapshot(favorites: Array(favorites),
                                history: history,
                                records: records)
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
