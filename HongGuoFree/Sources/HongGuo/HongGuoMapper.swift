// 红果数据 → App 内部模型
import Foundation

enum HongGuoMapper {

    /// 搜索/榜单结果 → Drama
    static func drama(from data: HGVideoData) -> Drama? {
        guard let seriesID = data.seriesID, !seriesID.isEmpty else { return nil }
        let vids = data.vidList ?? []
        let count = data.episodeCnt ?? vids.count
        let episodes = makeEpisodes(seriesID: seriesID, vids: vids, count: count, accessible: 3)

        return Drama(
            id: seriesID,
            title: data.seriesTitle ?? "未命名短剧",
            tagline: (data.seriesIntro ?? "").prefix(40).description,
            synopsis: data.seriesIntro,
            tags: (data.categoryList ?? []).compactMap { $0.name },
            coverURL: normalize(data.seriesCover),
            categoryIDs: (data.categoryList ?? []).compactMap { $0.categoryID },
            playCount: data.hotScoreData?.score,
            rating: nil,
            isFinished: data.seriesStatus == 1,
            episodes: episodes
        )
    }

    /// 详情页数据 → Drama
    static func drama(from detail: HGDetailPageData) -> Drama {
        let episodes = makeEpisodes(seriesID: detail.seriesID,
                                    vids: detail.vidList,
                                    count: detail.episodeCount,
                                    accessible: detail.accessibleEpisodeCount)
        return Drama(
            id: detail.seriesID,
            title: detail.seriesName,
            tagline: detail.seriesIntro.prefix(40).description,
            synopsis: detail.seriesIntro,
            tags: detail.tags,
            coverURL: normalize(detail.seriesCover),
            categoryIDs: [],
            playCount: nil,
            rating: nil,
            isFinished: true,
            episodes: episodes
        )
    }

    /// 把 vid 列表变成 Episode；超出免费范围的集标记为不可播（不提供地址）
    private static func makeEpisodes(seriesID: String, vids: [String], count: Int, accessible: Int) -> [Episode] {
        let total = max(count, vids.count)
        let free = max(accessible, 0)
        var result: [Episode] = []
        result.reserveCapacity(total)

        for index in 1...max(total, 1) {
            let vid: String? = index <= vids.count ? vids[index - 1] : nil
            let isFree = index <= free

            // 只有前 accessible 集才给出播放源；其余留空，UI 显示锁
            var sources: [PlaySource] = []
            if isFree, let vid {
                sources = [PlaySource(
                    url: "hg://\(seriesID)/\(vid)/\(index)",
                    quality: "720P",
                    priority: 10,
                    kind: "hongguo"
                )]
            }

            result.append(Episode(
                id: vid ?? "\(seriesID)-\(index)",
                index: index,
                title: "第 \(index) 集",
                duration: nil,
                isFree: isFree,
                sources: sources
            ))
        }
        return result
    }

    /// 封面 URL 修正：协议相对 → 绝对；http → https
    static func normalize(_ url: String?) -> String? {
        guard var value = url?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        // 兜底：万一 HTML 里的 \u002F 没被解码
        value = value
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u002f", with: "/")
        if value.hasPrefix("//") {
            value = "https:" + value
        }
        if value.hasPrefix("http://") {
            value = value.replacingOccurrences(of: "http://", with: "https://")
        }
        guard value.hasPrefix("https://") else { return nil }
        return value
    }
}
