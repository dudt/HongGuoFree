// 弹幕层
//
// 数据来自 /api/danmaku（服务端已带签名拉好红果真实弹幕）。
// 渲染方式：按 offset_ms 从右向左滚动，分轨道避免重叠。
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
    /// 拉一页弹幕
    func danmaku(vid: String, seriesID: String, cursor: String = "",
                 offsetMs: Int = 0) async throws -> HGDmakuPage {
        var path = "/api/danmaku?vid=\(vid)&series_id=\(seriesID)"
        if !cursor.isEmpty {
            let escaped = cursor.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? ""
            path += "&cursor=\(escaped)"
        }
        if offsetMs > 0 { path += "&offset_ms=\(offsetMs)" }

        guard let url = absolute(path) else { throw HGServeError.notConfigured }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.token.isEmpty {
            req.setValue(config.token, forHTTPHeaderField: "X-Auth-Token")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HGServeError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, "弹幕请求失败")
        }
        return try JSONDecoder().decode(HGDmakuPage.self, from: data)
    }
}

// MARK: - 弹幕轨道引擎

@MainActor
final class DanmakuEngine: ObservableObject {
    /// 当前应显示的弹幕
    @Published private(set) var active: [ActiveDanmaku] = []
    @Published var isEnabled = true
    @Published var opacity: Double = 0.9
    @Published var fontSize: CGFloat = 15

    struct ActiveDanmaku: Identifiable, Equatable {
        let id: String
        let text: String
        let lane: Int
        let startSec: Double
        let duration: Double   // 飞过屏幕所需秒数
    }

    private var all: [HGDmakuItem] = []
    private var laneFreeAt: [Double] = Array(repeating: 0, count: 6)
    let laneCount = 6

    /// 装载整集弹幕
    func load(_ items: [HGDmakuItem]) {
        all = items.sorted { $0.offsetMs < $1.offsetMs }
        active = []
        laneFreeAt = Array(repeating: 0, count: laneCount)
    }

    func clear() {
        all = []
        active = []
        laneFreeAt = Array(repeating: 0, count: laneCount)
    }

    var total: Int { all.count }

    /// 播放进度变化时调用（currentTime 单位：秒）
    func tick(currentTime: Double) {
        guard isEnabled, !all.isEmpty else {
            if !active.isEmpty { active = [] }
            return
        }

        // 屏幕上前 8 秒内仍应可见的弹幕
        let window = 8.0
        let from = currentTime - 0.3
        let to = currentTime + 0.3

        var next: [ActiveDanmaku] = []

        // 已经在屏上的：保留（用 startSec 判断还没飞完）
        for d in active where currentTime < d.startSec + d.duration {
            next.append(d)
        }

        // 新进入时间窗的
        for item in all {
            let t = item.offsetSec
            if t < from { continue }
            if t > to { break }
            if next.contains(where: { $0.id == item.id }) { continue }

            // 找空闲轨道
            var lane = -1
            for i in 0..<laneCount {
                if laneFreeAt[i] <= t {
                    lane = i
                    laneFreeAt[i] = t + 2.2   // 该轨道占用 2.2 秒
                    break
                }
            }
            if lane < 0 { lane = Int.random(in: 0..<laneCount) }

            next.append(ActiveDanmaku(
                id: item.id,
                text: item.text,
                lane: lane,
                startSec: t,
                duration: window
            ))
        }

        if next != active { active = next }
    }
}
