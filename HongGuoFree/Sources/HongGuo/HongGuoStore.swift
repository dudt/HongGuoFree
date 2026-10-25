// 红果内容源（网页接口）
import Foundation
import Combine

/// 红果短剧数据源：搜索、榜单、详情。
/// 只使用网页端公开接口；播放交给网页播放器，避免触碰 DRM。
@MainActor
final class HongGuoStore: ObservableObject {
    @Published private(set) var results: [Drama] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastQuery: String = ""

    private var cache: [String: Drama] = [:]

    var isEmpty: Bool { results.isEmpty }

    func search(_ keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        lastQuery = trimmed
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let items = try await HongGuoClient.search(keyword: trimmed)
            let dramas = items.compactMap { HongGuoMapper.drama(from: $0) }
            for drama in dramas { cache[drama.id] = drama }
            results = dramas
            if dramas.isEmpty {
                errorMessage = "没有搜到「\(trimmed)」相关的短剧。"
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 拉详情，补全全部集数
    func loadDetail(seriesID: String) async throws -> Drama {
        let detail = try await HongGuoClient.detail(seriesID: seriesID)
        let drama = HongGuoMapper.drama(from: detail)
        cache[seriesID] = drama
        if let index = results.firstIndex(where: { $0.id == seriesID }) {
            results[index] = drama
        }
        return drama
    }

    /// 拿某一集的播放页地址（网页播放器用）
    func playerURL(seriesID: String, vid: String) -> URL? {
        URL(string: "\(HongGuoClient.base)/player/\(seriesID)/\(vid)")
    }

    func clear() {
        results = []
        errorMessage = nil
        lastQuery = ""
    }
}
