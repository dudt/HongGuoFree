// 内容加载：内置演示数据 + 自建 JSON 接口
import Foundation
import Combine

enum FeedError: LocalizedError {
    case badURL
    case empty
    case transport(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "内容源地址无效，请填写完整的 http(s) 链接。"
        case .empty:
            return "内容源里没有任何短剧，请检查返回的 JSON。"
        case .transport(let message):
            return "网络请求失败：\(message)"
        case .decode(let message):
            return "JSON 解析失败：\(message)"
        }
    }
}

enum FeedLoader {
    static func load(from source: ContentSource) async throws -> FeedPayload {
        if source.urlString.hasPrefix("bundle://") {
            let name = source.urlString
                .replacingOccurrences(of: "bundle://", with: "")
                .replacingOccurrences(of: ".json", with: "")
            guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
                throw FeedError.transport("找不到内置文件 \(name).json")
            }
            let data = try Data(contentsOf: url)
            return try decode(data)
        }

        guard let url = URL(string: source.urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw FeedError.badURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw FeedError.transport("HTTP \(http.statusCode)")
            }
            return try decode(data)
        } catch let error as FeedError {
            throw error
        } catch {
            throw FeedError.transport(error.localizedDescription)
        }
    }

    static func decode(_ data: Data) throws -> FeedPayload {
        do {
            let payload = try JSONDecoder().decode(FeedPayload.self, from: data)
            guard !payload.dramas.isEmpty else { throw FeedError.empty }
            return payload
        } catch let error as FeedError {
            throw error
        } catch {
            throw FeedError.decode(error.localizedDescription)
        }
    }
}

final class AppStore: ObservableObject {
    @Published private(set) var dramas: [Drama] = []
    @Published private(set) var categories: [DramaCategory] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeSourceName: String = "本地演示内容"
    @Published private(set) var lastUpdated: Date?

    let library = LibraryStore()

    private weak var settings: SettingsStore?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // library 的变化异步转发给 AppStore，保证视图读到的是新值而不是旧值
        library.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func attach(settings: SettingsStore) {
        self.settings = settings
        settings.$feedURLString
            .dropFirst()
            .debounce(for: .seconds(0.6), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.reloadAll() }
            }
            .store(in: &cancellables)
    }

    @MainActor
    func reloadAll() async {
        let source: ContentSource
        if let custom = settings?.customFeedURL {
            source = ContentSource(name: "自定义内容源", urlString: custom.absoluteString)
        } else {
            source = ContentSource.builtIn()
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let payload = try await FeedLoader.load(from: source)
            dramas = payload.dramas
            categories = payload.categories ?? Self.deriveCategories(from: payload.dramas)
            activeSourceName = payload.name ?? source.name
            lastUpdated = Date()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if dramas.isEmpty {
                if let fallback = try? await FeedLoader.load(from: .builtIn()) {
                    dramas = fallback.dramas
                    categories = fallback.categories ?? Self.deriveCategories(from: fallback.dramas)
                    activeSourceName = "本地演示内容（离线兜底）"
                }
            }
        }
    }

    private static func deriveCategories(from dramas: [Drama]) -> [DramaCategory] {
        var seen: [String] = []
        for drama in dramas {
            for tag in drama.displayTags where !seen.contains(tag) {
                seen.append(tag)
            }
        }
        return seen.prefix(8).map { DramaCategory(id: $0, title: $0, systemImage: "tag.fill") }
    }

    // MARK: - 查询

    func drama(id: String) -> Drama? {
        dramas.first { $0.id == id }
    }

    func filtered(byCategory categoryID: String?) -> [Drama] {
        guard let categoryID else { return dramas }
        return dramas.filter { drama in
            drama.displayCategories.contains(categoryID) || drama.displayTags.contains(categoryID)
        }
    }

    func search(_ keyword: String) -> [Drama] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        return dramas.filter { drama in
            drama.title.lowercased().contains(key)
                || (drama.synopsis ?? "").lowercased().contains(key)
                || drama.displayTags.contains { $0.lowercased().contains(key) }
        }
    }

    var trending: [Drama] {
        dramas.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
    }

    var favorites: [Drama] {
        library.favorites.compactMap { id in self.drama(id: id) }
    }

    var historyDramas: [Drama] {
        library.history.compactMap { id in self.drama(id: id) }
    }

    func continueWatching(limit: Int = 8) -> [ContinueItem] {
        var items: [ContinueItem] = []
        for id in library.history {
            guard let item = drama(id: id),
                  let record = library.record(for: id) else { continue }
            items.append(ContinueItem(drama: item, record: record))
            if items.count >= limit { break }
        }
        return items
    }
}
