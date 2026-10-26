// 弹幕引擎与渲染
//
// 性能要点（旧版卡顿的原因）：
//   旧版每 0.1 秒重建一次 active 数组，触发 SwiftUI 全量 diff + 重新布局，
//   弹幕一多就掉帧。
//   新版：数据只在「装载」时算一次静态轨道表，渲染交给 TimelineView
//   自己按时间插值，SwiftUI 不参与每帧状态更新。
import SwiftUI
import Combine

// MARK: - 模型

struct HGDmakuItem: Identifiable, Decodable, Hashable {
    var id: String
    var text: String
    var offsetMs: Int
    var digg: Int?

    var offsetSec: Double { Double(offsetMs) / 1000.0 }

    enum CodingKeys: String, CodingKey {
        case id, text, digg
        case offsetMs = "offset_ms"
    }
}

struct HGDmakuPage: Decodable {
    var ok: Bool
    var count: Int?
    var total: Int?
    var hasMore: Bool?
    var nextCursor: String?
    var items: [HGDmakuItem]?

    enum CodingKeys: String, CodingKey {
        case ok, count, total, items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

// MARK: - 客户端

extension HGServerClient {
    /// 拉整集弹幕（服务端负责遍历所有时间窗）
    func danmaku(vid: String, seriesID: String, cursor: String = "",
                 offsetMs: Int = 0) async throws -> HGDmakuPage {
        guard let base = config.normalized else { throw HGServeError.notConfigured }
        var baseStr = base.absoluteString
        while baseStr.hasSuffix("/") { baseStr.removeLast() }

        guard var comps = URLComponents(string: baseStr + "/api/danmaku") else {
            throw HGServeError.badPath("/api/danmaku")
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "vid", value: vid),
            URLQueryItem(name: "series_id", value: seriesID),
        ]
        if !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        if offsetMs > 0 { items.append(URLQueryItem(name: "offset_ms", value: String(offsetMs))) }
        if !config.token.isEmpty {
            items.append(URLQueryItem(name: "token", value: config.token))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw HGServeError.badPath("/api/danmaku") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 45
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
        return try JSONDecoder().decode(HGDmakuPage.self, from: data)
    }
}

// MARK: - 设置

struct DanmakuSettings: Equatable, Codable {
    var enabled = true
    /// 屏幕占用比例（0.3 = 只在上面 30% 区域滚动）
    var areaRatio: Double = 0.45
    /// 顶部留白（避开播放器顶部按钮）
    var topInset: Double = 44
    /// 字号
    var fontSize: Double = 16
    /// 飞行时长（秒），越小越快
    var duration: Double = 7.5
    /// 不透明度
    var opacity: Double = 0.92
    /// 是否显示描边
    var stroke = true
}

// MARK: - 静态轨道表

/// 一条已经排好轨道的弹幕（装载时一次性算完）
struct ScheduledDanmaku: Identifiable {
    let id: String
    let text: String
    let lane: Int
    let startSec: Double
}

@MainActor
final class DanmakuEngine: ObservableObject {
    private static let settingsKey = "hg.danmaku.settings.v1"

    @Published var settings: DanmakuSettings {
        didSet { persist() }
    }
    @Published private(set) var scheduled: [ScheduledDanmaku] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false

    private var raw: [HGDmakuItem] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(DanmakuSettings.self, from: data) {
            settings = saved
        } else {
            settings = DanmakuSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    /// 当前可用的轨道数（随屏幕高度和字号变化）
    func laneCount(for height: CGFloat) -> Int {
        let usable = Double(height) * settings.areaRatio - settings.topInset
        let laneHeight = settings.fontSize * 1.9
        return max(1, min(14, Int(usable / laneHeight)))
    }

    func load(_ items: [HGDmakuItem]) {
        raw = items.sorted { $0.offsetMs < $1.offsetMs }
        total = raw.count
        rebuild()
    }

    func clear() {
        raw = []
        scheduled = []
        total = 0
    }

    func setLoading(_ v: Bool) { loading = v }

    /// 按当前设置重排轨道（设置变化时调用）
    func rebuild(laneCount lanes: Int = 8) {
        guard !raw.isEmpty else { scheduled = []; return }
        var freeAt = [Double](repeating: 0, count: max(lanes, 1))
        var out: [ScheduledDanmaku] = []
        out.reserveCapacity(raw.count)

        for item in raw {
            let t = item.offsetSec
            var lane = -1
            for i in 0..<freeAt.count {
                if freeAt[i] <= t {
                    lane = i
                    // 该轨道下一次可用时间：飞完一半后再放下一条，避免贴太紧
                    freeAt[i] = t + settings.duration * 0.45
                    break
                }
            }
            if lane < 0 { continue }   // 轨道满了就丢掉，不随机塞
            out.append(ScheduledDanmaku(id: item.id, text: item.text,
                                        lane: lane, startSec: t))
        }
        scheduled = out
    }
}
