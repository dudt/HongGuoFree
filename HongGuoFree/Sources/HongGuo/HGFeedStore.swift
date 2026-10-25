// 真实数据源：从自建解析服务拉短剧库
//
// 替代原来的 sample-feed.json 演示数据。
// 数据全部来自红果真实剧库（App 端 multi_video_model + album_detail）。
import Foundation

// MARK: - 模型

struct HGFeedItem: Identifiable, Decodable {
    var seriesID: String
    var itemID: String?
    var title: String?
    var cover: String?
    var intro: String?
    var tags: [String]?
    var episodeText: String?
    var episodeCount: Int?
    var freeEpisodes: Int?
    var playCount: Int?
    var followedCount: Int?

    var id: String { seriesID }

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case itemID = "item_id"
        case title, cover, intro, tags
        case episodeText = "episode_text"
        case episodeCount = "episode_count"
        case freeEpisodes = "free_episodes"
        case playCount = "play_count"
        case followedCount = "followed_count"
    }

    /// "8.5M 次播放" / "1234 次播放"
    var playText: String {
        let n = playCount ?? 0
        guard n > 0 else { return "" }
        if n >= 100_000_000 { return String(format: "%.1f亿播放", Double(n) / 100_000_000) }
        if n >= 10_000 { return String(format: "%.1f万播放", Double(n) / 10_000) }
        return "\(n) 次播放"
    }

    /// "全 62 集"
    var episodeTextResolved: String {
        if let c = episodeCount, c > 0 { return "全 \(c) 集" }
        return episodeText ?? ""
    }
}

struct HGDiscoverResponse: Decodable {
    var ok: Bool
    var tab: Int?
    var offset: Int?
    var count: Int?
    var hasMore: Bool?
    var items: [HGFeedItem]?

    enum CodingKeys: String, CodingKey {
        case ok, tab, offset, count, items
        case hasMore = "has_more"
    }
}

// MARK: - 客户端扩展

extension HGServerClient {
    /// 发现页：拉真实短剧列表
    func discover(tab: Int = 201, offset: Int = 0, count: Int = 20) async throws -> HGDiscoverResponse {
        let path = "/api/discover?tab=\(tab)&offset=\(offset)&count=\(count)"
        guard let url = absolute(path) else { throw HGServeError.notConfigured }

        var req = URLRequest(url: url)
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.token.isEmpty {
            req.setValue(config.token, forHTTPHeaderField: "X-Auth-Token")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw HGServeError.decode("不是 HTTP 响应")
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw HGServeError.http(http.statusCode, String(msg.prefix(200)))
            }
            return try JSONDecoder().decode(HGDiscoverResponse.self, from: data)
        } catch let e as HGServeError {
            throw e
        } catch {
            throw HGServeError.decode(error.localizedDescription)
        }
    }
}

// MARK: - 状态容器

@MainActor
final class HGFeedStore: ObservableObject {
    @Published private(set) var items: [HGFeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    @Published private(set) var hasMore = true
    @Published var tab: Int = 201

    private var offset = 0
    private let pageSize = 20
    private var loadedTabs: [Int: (items: [HGFeedItem], offset: Int, hasMore: Bool)] = [:]

    /// 切换 tab 时恢复各自的分页状态
    func selectTab(_ newTab: Int) async {
        // 先把当前 tab 的进度存起来
        loadedTabs[tab] = (items, offset, hasMore)
        tab = newTab
        if let saved = loadedTabs[newTab] {
            items = saved.items
            offset = saved.offset
            hasMore = saved.hasMore
        } else {
            items = []
            offset = 0
            hasMore = true
            await reload(config: nil)
        }
    }

    func reload(config: ResolverConfig?) async {
        guard let config, config.isConfigured else {
            items = []
            errorText = "还没配置解析服务。请到「我的 → 解析服务」填写地址。"
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let client = HGServerClient(config: config)
            let resp = try await client.discover(tab: tab, offset: 0, count: pageSize)
            items = resp.items ?? []
            offset = items.count
            hasMore = resp.hasMore ?? false
        } catch {
            errorText = error.localizedDescription
        }
    }

    func loadMore(config: ResolverConfig?) async {
        guard !isLoading, hasMore, let config, config.isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = HGServerClient(config: config)
            let resp = try await client.discover(tab: tab, offset: offset, count: pageSize)
            let fresh = (resp.items ?? []).filter { new in
                !items.contains(where: { $0.seriesID == new.seriesID })
            }
            items.append(contentsOf: fresh)
            offset += (resp.items ?? []).count
            hasMore = (resp.hasMore ?? false) && !fresh.isEmpty
        } catch {
            errorText = error.localizedDescription
            hasMore = false
        }
    }

    func clear() {
        items = []
        offset = 0
        hasMore = true
        errorText = nil
        loadedTabs.removeAll()
    }
}
