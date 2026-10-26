// 直连播放器：客户端自己解 CENC，视频流不经过自建服务器
//
// 带宽对比（实测一集 13.56 MB）：
//   转发模式  /api/stream   → 服务器上传 13.56 MB
//   直连模式  /api/keys     → 服务器上传 ~0.4 MB（gzip 后）
//   省 30+ 倍，且与集时长无关（密钥包体积只跟样本数有关）
//
// 关键设计：虚拟文件与原始文件「布局完全一致」
//   早期版本把 [header, 样本1, 样本2, ...] 重新拼成连续文件，
//   但 moov 里 stco 记录的是原始文件的绝对偏移，两者差一个
//   mdat box 头（16 字节），导致每个样本都错位，
//   AVPlayer 解出来是垃圾数据并报「操作已停止」。
//
//   现在的做法：
//     - 文件长度 = 原始 total_bytes
//     - header 区间（ftyp+moov，已清加密标记）用本地清理版
//     - 样本区间：从 CDN 拉密文 → AES-128-CTR 解密
//     - 空洞区间（mdat 头等非样本字节）：原样从 CDN 透传
//   这样任意偏移都能正确映射，stco 天然对得上。
import Foundation
import AVFoundation
import CommonCrypto

// MARK: - 密钥包

struct HGKeyBundle: Decodable {
    struct Samples: Decodable {
        var count: Int
        var first: Int?        // 第一个样本在原始文件中的偏移
        var sizes: String      // "1234,5678,..."
        var ivs: String        // base64，8 字节 × count
    }

    var ok: Bool
    var mode: String?
    var cdnURL: String?
    var quality: String?
    var duration: Double?
    var totalBytes: Int64?
    var encrypted: Bool?
    var keyHex: String?
    var headerB64: String?
    /// "start:size,start:size" —— 非样本、需原样透传的区间
    var gaps: String?
    var samples: Samples?

    enum CodingKeys: String, CodingKey {
        case ok, mode, quality, duration, encrypted, gaps, samples
        case cdnURL = "cdn_url"
        case totalBytes = "total_bytes"
        case keyHex = "key_hex"
        case headerB64 = "header_b64"
    }
}

// MARK: - 客户端

extension HGServerClient {
    func keys(vid: String) async throws -> HGKeyBundle {
        guard let base = config.normalized else { throw HGServeError.notConfigured }
        var baseStr = base.absoluteString
        while baseStr.hasSuffix("/") { baseStr.removeLast() }

        guard var comps = URLComponents(string: baseStr + "/api/keys") else {
            throw HGServeError.badPath("/api/keys")
        }
        var items = [URLQueryItem(name: "vid", value: vid)]
        if !config.token.isEmpty {
            items.append(URLQueryItem(name: "token", value: config.token))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw HGServeError.badPath("/api/keys") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        if !config.token.isEmpty {
            req.setValue(config.token, forHTTPHeaderField: "X-Auth-Token")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw HGServeError.http((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                    String(msg.prefix(160)))
        }
        return try JSONDecoder().decode(HGKeyBundle.self, from: data)
    }
}

// MARK: - 解密器

final class CENCDecryptor {
    struct Segment {
        var start: Int64
        var size: Int64
        var iv: Data?      // nil = 空洞，原样透传
    }

    let key: Data
    let header: Data
    let totalSize: Int64
    /// 按 start 升序排列的所有区间（样本 + 空洞）
    let segments: [Segment]

    init?(bundle: HGKeyBundle) {
        guard let keyHex = bundle.keyHex,
              let keyData = Data(hexString: keyHex), keyData.count == 16 else { return nil }
        guard let hb = bundle.headerB64, let headerData = Data(base64Encoded: hb) else { return nil }
        guard let s = bundle.samples, let ivData = Data(base64Encoded: s.ivs) else { return nil }
        guard let total = bundle.totalBytes, total > 0 else { return nil }

        let sizes = s.sizes.split(separator: ",").compactMap { Int64($0) }
        guard sizes.count == s.count, ivData.count >= s.count * 8 else { return nil }

        self.key = keyData
        self.header = headerData
        self.totalSize = total

        // 样本区间
        var segs: [Segment] = []
        segs.reserveCapacity(s.count)
        var off = Int64(s.first ?? headerData.count)
        for i in 0..<s.count {
            let iv = ivData.subdata(in: (i * 8)..<((i + 1) * 8))
            segs.append(Segment(start: off, size: sizes[i], iv: iv))
            off += sizes[i]
        }

        // 空洞区间（服务端给的 "start:size,..."）
        if let g = bundle.gaps, !g.isEmpty {
            for pair in g.split(separator: ",") {
                let parts = pair.split(separator: ":")
                guard parts.count == 2,
                      let st = Int64(parts[0]), let sz = Int64(parts[1]), sz > 0 else { continue }
                segs.append(Segment(start: st, size: sz, iv: nil))
            }
        }
        segs.sort { $0.start < $1.start }
        self.segments = segs
    }

    /// 解密/透传 [range] 区间（原始文件坐标）
    /// 返回的数据长度严格等于 range.count
    func produce(cipher: Data, cipherStart: Int64, range: Range<Int64>) -> Data {
        var out = Data(count: range.count)
        let headerLen = Int64(header.count)

        // 1) header 区间：用本地清理版（去掉了 encv/sinf/senc/saiz/saio）
        if range.lowerBound < headerLen {
            let from = Int(range.lowerBound)
            let to = Int(min(range.upperBound, headerLen))
            if to > from {
                let piece = header.subdata(in: from..<to)
                out.replaceSubrange(0..<piece.count, with: piece)
            }
        }

        // 2) 样本 / 空洞区间
        for seg in segments {
            let segEnd = seg.start + seg.size
            if segEnd <= range.lowerBound { continue }
            if seg.start >= range.upperBound { break }

            let from = max(seg.start, range.lowerBound)
            let to = min(segEnd, range.upperBound)
            guard to > from else { continue }

            let cFrom = Int(from - cipherStart)
            let cTo = Int(to - cipherStart)
            guard cFrom >= 0, cTo <= cipher.count, cFrom < cTo else { continue }

            let chunk = cipher.subdata(in: cFrom..<cTo)
            let dFrom = Int(from - range.lowerBound)

            if let iv = seg.iv {
                // 样本：解密
                let skip = Int(from - seg.start)
                if let plain = Self.ctr(key: key, iv: iv, skip: skip, data: chunk) {
                    out.replaceSubrange(dFrom..<(dFrom + plain.count), with: plain)
                }
            } else {
                // 空洞：原样透传
                out.replaceSubrange(dFrom..<(dFrom + chunk.count), with: chunk)
            }
        }
        return out
    }

    /// AES-128-CTR（CommonCrypto，硬件加速）
    static func ctr(key: Data, iv: Data, skip: Int, data: Data) -> Data? {
        guard key.count == 16, !data.isEmpty else { return nil }

        // CENC 的 8 字节 IV 右补 0 成 16 字节 counter（IV || 0^8）
        // 注意：不是左补零。左补零解出来是垃圾数据，
        // AVPlayer 会报「操作已停止」。实测对比服务端输出确认：
        //   iv=1b6729055b854570
        //   右补0 -> 00000111 0079...  ✓ 正确 HEVC NAL 头
        //   左补0 -> 1ad7d07e...       ✗ 垃圾
        var counter = [UInt8](repeating: 0, count: 16)
        let ivb = [UInt8](iv)
        let n = min(ivb.count, 16)
        for i in 0..<n { counter[i] = ivb[i] }

        // 把 skip 加进 counter（大端）
        var carry = skip
        var idx = 15
        while carry > 0 && idx >= 0 {
            let sum = Int(counter[idx]) + (carry & 0xFF)
            counter[idx] = UInt8(sum & 0xFF)
            carry = (carry >> 8) + (sum >> 8)
            idx -= 1
        }

        let outCount = data.count
        var buffer = [UInt8](repeating: 0, count: outCount)
        var moved = 0
        var cryptorRef: CCCryptorRef?

        let status: CCCryptorStatus = buffer.withUnsafeMutableBytes { outPtr in
            guard let outBase = outPtr.baseAddress else { return CCCryptorStatus(kCCParamError) }
            return data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { kPtr in
                    counter.withUnsafeBytes { ivPtr in
                        var st = CCCryptorCreateWithMode(
                            CCOperation(kCCEncrypt),
                            CCMode(kCCModeCTR),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCPadding(ccNoPadding),
                            ivPtr.baseAddress,
                            kPtr.baseAddress,
                            key.count,
                            nil, 0, 0,
                            CCModeOptions(kCCModeOptionCTR_BE),
                            &cryptorRef
                        )
                        guard st == kCCSuccess, let c = cryptorRef else { return st }

                        st = CCCryptorUpdate(
                            c,
                            inPtr.baseAddress, data.count,
                            outBase, outCount, &moved
                        )
                        CCCryptorRelease(c)
                        cryptorRef = nil
                        return st
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(buffer)
    }
}

// MARK: - ResourceLoader

/// 拦截 custom scheme 请求，去 CDN 拉密文并本地解密
final class CENCResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "hgstream"

    private let decryptor: CENCDecryptor
    private let cdnURL: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "hg.cenc", qos: .userInitiated)
    private let ua = "com.phoenix.read/74232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"

    init(decryptor: CENCDecryptor, cdnURL: URL) {
        self.decryptor = decryptor
        self.cdnURL = cdnURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    static func makeAssetURL() -> URL {
        URL(string: "\(scheme)://stream/index.mp4")!
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource
                        loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let info = loadingRequest.contentInformationRequest,
              let dataReq = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        info.contentType = "video/mp4"
        info.contentLength = decryptor.totalSize
        info.isByteRangeAccessSupported = true

        let start = dataReq.requestedOffset
        let length = dataReq.requestedLength > 0
            ? Int64(dataReq.requestedLength)
            : decryptor.totalSize - start
        let end = min(start + length - 1, decryptor.totalSize - 1)
        guard start <= end, start >= 0 else {
            loadingRequest.finishLoading()
            return true
        }

        // 整段都在 header 内 → 本地直接给
        let headerLen = Int64(decryptor.header.count)
        if start < headerLen {
            let from = Int(start)
            let to = Int(min(end + 1, headerLen))
            if to > from {
                dataReq.respond(with: decryptor.header.subdata(in: from..<to))
            }
            if end < headerLen {
                loadingRequest.finishLoading()
                return true
            }
        }

        // 其余部分从 CDN 拉（密文），本地解密/透传
        let cdnFrom = max(start, headerLen)
        let cdnTo = end
        guard cdnTo >= cdnFrom else {
            loadingRequest.finishLoading()
            return true
        }

        var req = URLRequest(url: cdnURL)
        req.setValue("bytes=\(cdnFrom)-\(cdnTo)", forHTTPHeaderField: "Range")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")

        let task = session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.queue.async {
                defer { loadingRequest.finishLoading() }

                guard let data, !data.isEmpty else {
                    // CDN 失败：给零填充，避免播放器卡死（会表现为静音/黑帧，
                    // 但不会像之前那样整段停摆）
                    if err != nil {
                        let need = Int(end - max(start, headerLen) + 1)
                        if need > 0 {
                            dataReq.respond(with: Data(count: need))
                        }
                    }
                    return
                }

                // 校验 CDN 返回的长度；不足时补齐，避免越界
                let want = Int(cdnTo - cdnFrom + 1)
                var cipher = data
                if cipher.count < want {
                    cipher.append(Data(count: want - cipher.count))
                }

                let plain = self.decryptor.produce(
                    cipher: cipher,
                    cipherStart: cdnFrom,
                    range: start..<(end + 1)
                )

                // header 部分已单独 respond 过，这里只发其后
                if start < headerLen {
                    let skip = Int(headerLen - start)
                    if skip < plain.count {
                        dataReq.respond(with: plain.subdata(in: skip..<plain.count))
                    }
                } else {
                    dataReq.respond(with: plain)
                }
            }
        }
        task.resume()
        return true
    }
}

// MARK: - Data hex

extension Data {
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count % 2 == 0, !s.isEmpty else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = Data(out)
    }
}
