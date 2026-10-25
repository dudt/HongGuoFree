// 内容模型：短剧、分集、播放源
import Foundation

// MARK: - 内容源

/// 一个内容源（本地演示数据 / 自建接口 / 局域网服务）
struct ContentSource: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var urlString: String
    var isBuiltIn: Bool = false

    static func builtIn() -> ContentSource {
        ContentSource(name: "本地演示内容", urlString: "bundle://sample-feed.json", isBuiltIn: true)
    }
}

/// 内容源返回的整包数据
struct FeedPayload: Codable {
    var version: Int?
    var name: String?
    var updatedAt: String?
    var categories: [DramaCategory]?
    var dramas: [Drama]
}

struct DramaCategory: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var systemImage: String?
}

// MARK: - 短剧

struct Drama: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var tagline: String?
    var synopsis: String?
    var tags: [String]?
    var coverURL: String?
    var categoryIDs: [String]?
    var playCount: Int?
    var rating: Double?
    var isFinished: Bool?
    var episodes: [Episode]

    var displayTagline: String { tagline ?? (synopsis ?? "").prefix(60).description }
    var displayTags: [String] { tags ?? [] }
    var displayCategories: [String] { categoryIDs ?? [] }
    var episodeCount: Int { episodes.count }
    var totalDuration: Double { episodes.reduce(0) { $0 + ($1.duration ?? 0) } }

    var heatText: String {
        guard let playCount, playCount > 0 else { return "" }
        if playCount >= 10_000 {
            return String(format: "%.1f 万次播放", Double(playCount) / 10_000.0)
        }
        return "\(playCount) 次播放"
    }

    var ratingText: String {
        guard let rating else { return "" }
        return String(format: "%.1f", rating)
    }

    func filteredEpisodes(in range: ClosedRange<Int>) -> [Episode] {
        episodes.filter { range.contains($0.index) }
    }
}

struct Episode: Codable, Identifiable, Hashable {
    var id: String
    var index: Int
    var title: String?
    var duration: Double?
    var isFree: Bool?
    var sources: [PlaySource]

    var displayTitle: String { title ?? "第 \(index) 集" }
    var displayDuration: String { (duration ?? 0).timeText }

    var bestSource: PlaySource? {
        sources.max { lhs, rhs in
            lhs.priorityValue < rhs.priorityValue
        }
    }
}

struct PlaySource: Codable, Hashable {
    var url: String
    var quality: String?
    var priority: Int?
    var kind: String?   // "hls" / "mp4" / 其它自定义

    var displayQuality: String { quality ?? kind?.uppercased() ?? "自动" }
    var priorityValue: Int { priority ?? 0 }

    var isHLS: Bool {
        if kind?.lowercased() == "hls" { return true }
        return url.lowercased().contains(".m3u8")
    }

    var resolvedURL: URL? {
        URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - 继续观看

struct ContinueItem: Identifiable, Hashable {
    var id: String { drama.id }
    let drama: Drama
    let record: PlaybackRecord
}

// MARK: - 播放进度

struct PlaybackRecord: Codable, Hashable {
    var dramaID: String
    var episodeID: String
    var episodeIndex: Int
    var position: Double
    var duration: Double
    var updatedAt: Date

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
}
