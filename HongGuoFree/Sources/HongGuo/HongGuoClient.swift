// 红果短剧网页端数据源
//
// 说明：本文件只调用 hongguoduanju.com 的**公开网页接口**（与浏览器访问同一套 API），
// 不伪造设备指纹、不绕过签名、不逆向加密视频。
// 网页端本身把可播放集数限制在前 3 集（accessible_episode_cnt），这是它的产品设计，
// 超出部分会返回 protected_playback_unavailable，App 会如实提示用户去官方 App 观看。
import Foundation

// MARK: - 错误

enum HongGuoError: LocalizedError {
    case badURL
    case transport(String)
    case decode(String)
    case paywalled(Int)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "红果接口地址无效。"
        case .transport(let message):
            return "请求失败：\(message)"
        case .decode(let message):
            return "数据解析失败：\(message)"
        case .paywalled(let index):
            return "第 \(index) 集在网页端未开放，需在红果短剧 App 内观看。"
        }
    }
}

// MARK: - 原始响应模型

/// GET /api/search/result?query=xxx
struct HGSearchResponse: Decodable {
    var searchList: [HGSearchItem]?
}

struct HGSearchItem: Decodable {
    var docType: Int?
    var name: String?
    var keyword: String?
    var videoData: HGVideoData?

    enum CodingKeys: String, CodingKey {
        case docType = "doc_type"
        case name
        case keyword
        case videoData = "video_data"
    }
}

struct HGVideoData: Decodable {
    var seriesID: String?
    var seriesTitle: String?
    var seriesIntro: String?
    var seriesCover: String?
    var episodeCnt: Int?
    var episodeRightText: String?
    var seriesStatus: Int?
    var vidList: [String]?
    var categoryList: [HGCategory]?
    var celebrities: [HGCelebrity]?
    var hotScoreData: HGHotScore?

    enum CodingKeys: String, CodingKey {
        case seriesID = "series_id"
        case seriesTitle = "series_title"
        case seriesIntro = "series_intro"
        case seriesCover = "series_cover"
        case episodeCnt = "episode_cnt"
        case episodeRightText = "episode_right_text"
        case seriesStatus = "series_status"
        case vidList = "vid_list"
        case categoryList = "category_list"
        case celebrities
        case hotScoreData = "hot_score_data"
    }
}

struct HGCategory: Decodable {
    var categoryID: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case name
    }
}

struct HGCelebrity: Decodable {
    var nickname: String?
    var avatar: String?
    var subTitle: String?

    enum CodingKeys: String, CodingKey {
        case nickname
        case avatar
        case subTitle = "sub_title"
    }
}

struct HGHotScore: Decodable {
    var score: Int?
    var text: String?
}

/// POST /api/video/protected/play-info
struct HGPlayInfoResponse: Decodable {
    var playInfo: HGPlayInfo?
    var baseResp: HGBaseResp?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case playInfo = "play_info"
        case baseResp = "base_resp"
        case error
    }
}

struct HGBaseResp: Decodable {
    var statusCode: Int?
    var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "StatusCode"
        case statusMessage = "StatusMessage"
    }
}

struct HGPlayInfo: Decodable {
    var vid: String?
    var kid: String?
    var mainURL: String?
    var backupURL: String?
    var playerAccessKey: String?
    var definition: String?
    var format: String?
    var codecType: String?
    var width: String?
    var height: String?
    var duration: Double?
    var size: String?
    var bitrate: String?
    var expiresAt: Double?
    var audio: HGAudioTrack?

    enum CodingKeys: String, CodingKey {
        case vid
        case kid
        case mainURL = "main_url"
        case backupURL = "backup_url"
        case playerAccessKey = "player_access_key"
        case definition
        case format
        case codecType = "codec_type"
        case width
        case height
        case duration
        case size
        case bitrate
        case expiresAt = "expires_at"
        case audio
    }
}

struct HGAudioTrack: Decodable {
    var mainURL: String?
    var backupURL: String?
    var playerAccessKey: String?
    var duration: Double?
    var format: String?

    enum CodingKeys: String, CodingKey {
        case mainURL = "main_url"
        case backupURL = "backup_url"
        case playerAccessKey = "player_access_key"
        case duration
        case format
    }
}

// MARK: - 详情页 SSR 数据

/// 详情页里嵌入的 vid_list（比 search 接口更全，能拿到全部 90 集）
struct HGDetailPageData {
    var seriesID: String
    var seriesName: String
    var seriesIntro: String
    var seriesCover: String
    var tags: [String]
    var vidList: [String]
    var episodeCount: Int
    var celebrities: [HGCelebrity]
    var accessibleEpisodeCount: Int
}

// MARK: - 客户端

struct HongGuoClient {
    static let base = "https://hongguoduanju.com"
    static let webUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": webUA,
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
        return URLSession(configuration: config)
    }()

    // MARK: 搜索

    static func search(keyword: String) async throws -> [HGVideoData] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/api/search/result?query=\(encoded)") else {
            throw HongGuoError.badURL
        }
        let data = try await get(url, referer: "\(base)/search")
        do {
            let decoded = try JSONDecoder().decode(HGSearchResponse.self, from: data)
            return (decoded.searchList ?? []).compactMap { $0.videoData }
        } catch {
            throw HongGuoError.decode(error.localizedDescription)
        }
    }

    // MARK: 详情页

    static func detail(seriesID: String) async throws -> HGDetailPageData {
        guard let url = URL(string: "\(base)/detail?series_id=\(seriesID)") else {
            throw HongGuoError.badURL
        }
        let data = try await get(url, referer: base)
        guard let html = String(data: data, encoding: .utf8) else {
            throw HongGuoError.decode("详情页不是 UTF-8 文本")
        }
        return try parseDetailHTML(html, seriesID: seriesID)
    }

    static func parseDetailHTML(_ html: String, seriesID: String) throws -> HGDetailPageData {
        func firstMatch(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                return nil
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, options: [], range: range) else { return nil }
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }

        func jsonString(_ raw: String?) -> String {
            guard let raw else { return "" }
            return raw
                .replacingOccurrences(of: "\\u002F", with: "/")
                .replacingOccurrences(of: "\\u002f", with: "/")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        // JSON 字符串值，正确处理 \" 与 \\ 转义
        let strValue = #""((?:[^"\\]|\\.)*)""#

        let name = jsonString(firstMatch(#""series_name":\#(strValue)"#))
        let intro = jsonString(firstMatch(#""series_intro":\#(strValue)"#))
        let cover = jsonString(firstMatch(#""series_cover":\#(strValue)"#))

        var vids: [String] = []
        if let listRaw = firstMatch(#""vid_list":\[(.*?)\]"#) {
            if let regex = try? NSRegularExpression(pattern: #""(\d+)""#) {
                let range = NSRange(listRaw.startIndex..<listRaw.endIndex, in: listRaw)
                regex.enumerateMatches(in: listRaw, range: range) { match, _, _ in
                    guard let match, let r = Range(match.range(at: 1), in: listRaw) else { return }
                    vids.append(String(listRaw[r]))
                }
            }
        }

        var tags: [String] = []
        if let tagRaw = firstMatch(#""tags":\[(.*?)\]"#) {
            if let regex = try? NSRegularExpression(pattern: strValue) {
                let range = NSRange(tagRaw.startIndex..<tagRaw.endIndex, in: tagRaw)
                regex.enumerateMatches(in: tagRaw, range: range) { match, _, _ in
                    guard let match, let r = Range(match.range(at: 1), in: tagRaw) else { return }
                    tags.append(String(tagRaw[r]))
                }
            }
        }

        let episodeCount = Int(firstMatch(#""episode_cnt":(\d+)"#) ?? "") ?? vids.count
        let accessible = Int(firstMatch(#""accessible_episode_cnt":(\d+)"#) ?? "") ?? 3

        guard !vids.isEmpty else {
            throw HongGuoError.decode("详情页里没有找到剧集列表")
        }

        return HGDetailPageData(seriesID: seriesID,
                                seriesName: name.isEmpty ? "未命名短剧" : name,
                                seriesIntro: intro,
                                seriesCover: cover,
                                tags: tags,
                                vidList: vids,
                                episodeCount: max(episodeCount, vids.count),
                                celebrities: [],
                                accessibleEpisodeCount: accessible)
    }

    // MARK: 播放地址

    /// 拿单集播放信息。网页端只开放前 3 集，其余会抛 .paywalled。
    static func playInfo(seriesID: String, vid: String, episodeIndex: Int, definition: String = "720p") async throws -> HGPlayInfo {
        guard let url = URL(string: "\(base)/api/video/protected/play-info") else {
            throw HongGuoError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(base)/player/\(seriesID)/\(vid)", forHTTPHeaderField: "Referer")
        request.setValue(base, forHTTPHeaderField: "Origin")
        let body: [String: String] = [
            "series_id": seriesID,
            "item_id": vid,
            "definition": definition,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HongGuoError.paywalled(episodeIndex)
        }
        let decoded: HGPlayInfoResponse
        do {
            decoded = try JSONDecoder().decode(HGPlayInfoResponse.self, from: data)
        } catch {
            throw HongGuoError.decode(error.localizedDescription)
        }
        if let err = decoded.error, !err.isEmpty {
            throw HongGuoError.paywalled(episodeIndex)
        }
        guard let info = decoded.playInfo, let main = info.mainURL, !main.isEmpty else {
            throw HongGuoError.paywalled(episodeIndex)
        }
        return info
    }

    // MARK: 底层 GET

    private static func get(_ url: URL, referer: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw HongGuoError.transport("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as HongGuoError {
            throw error
        } catch {
            throw HongGuoError.transport(error.localizedDescription)
        }
    }
}
