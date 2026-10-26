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

    init(seriesID: String, itemID: String? = nil, title: String? = nil,
         cover: String? = nil, intro: String? = nil, tags: [String]? = nil,
         episodeText: String? = nil, episodeCount: Int? = nil,
         freeEpisodes: Int? = nil, playCount: Int? = nil,
         followedCount: Int? = nil) {
        self.seriesID = seriesID
        self.itemID = itemID
        self.title = title
        self.cover = cover
        self.intro = intro
        self.tags = tags
        self.episodeText = episodeText
        self.episodeCount = episodeCount
        self.freeEpisodes = freeEpisodes
        self.playCount = playCount
        self.followedCount = followedCount
    }

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
    var nextOffset: Int?
    var items: [HGFeedItem]?

    enum CodingKeys: String, CodingKey {
        case ok, tab, offset, count, items
        case hasMore = "has_more"
        case nextOffset = "next_offset"
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
            offset = resp.nextOffset ?? items.count
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
            // 服务端给的是上游真实 offset，不能自己累加（会有重复被过滤）
            offset = resp.nextOffset ?? (offset + (resp.items ?? []).count)
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


// MARK: - 搜索

struct HGSearchResponse: Decodable {
    var ok: Bool
    var q: String?
    var count: Int?
    var totalIndexed: Int?
    var items: [HGFeedItem]?

    enum CodingKeys: String, CodingKey {
        case ok, q, count, items
        case totalIndexed = "total_indexed"
    }
}

extension HGServerClient {
    func search(_ query: String) async throws -> HGSearchResponse {
        guard let base = config.normalized else { throw HGServeError.notConfigured }
        var baseStr = base.absoluteString
        while baseStr.hasSuffix("/") { baseStr.removeLast() }

        guard var comps = URLComponents(string: baseStr + "/api/search") else {
            throw HGServeError.badPath("/api/search")
        }
        var items = [URLQueryItem(name: "q", value: query)]
        if !config.token.isEmpty {
            items.append(URLQueryItem(name: "token", value: config.token))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw HGServeError.badPath("/api/search") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 90   // 首次建索引要十几秒
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.token.isEmpty {
            req.setValue(config.token, forHTTPHeaderField: "X-Auth-Token")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw HGServeError.http((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                    String(msg.prefix(160)))
        }
        return try JSONDecoder().decode(HGSearchResponse.self, from: data)
    }
}
