// 直连播放器：客户端自己解 CENC，视频流不经过自建服务器
//
// 带宽对比（实测一集 7.22 MB）：
//   转发模式  /api/stream   → 服务器上传 7.57 MB
//   直连模式  /api/keys     → 服务器上传 0.05 MB（gzip 后）
//   省 146 倍
//
// 原理：
//   1. /api/keys 拿到 CDN 地址、AES-128 密钥、每样本 IV、去加密标记的头部
//   2. AVAssetResourceLoader 拦截播放器对 custom scheme 的请求
//   3. 按 Range 去 CDN 拉密文，用样本表逐样本 AES-128-CTR 解密
//   4. 把明文回给播放器
import Foundation
import AVFoundation
import CommonCrypto

// MARK: - 密钥包

struct HGKeyBundle: Decodable {
    struct Samples: Decodable {
        var count: Int
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
    var samples: Samples?

    enum CodingKeys: String, CodingKey {
        case ok, mode, quality, duration, encrypted, samples
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
    let key: Data
    let header: Data
    /// 每个样本的 (在解密后文件中的起始偏移, 大小, IV)
    let samples: [(offset: Int64, size: Int64, iv: Data)]
    let totalSize: Int64

    init?(bundle: HGKeyBundle) {
        guard let keyHex = bundle.keyHex,
              let keyData = Data(hexString: keyHex), keyData.count == 16 else { return nil }
        guard let hb = bundle.headerB64, let headerData = Data(base64Encoded: hb) else { return nil }
        guard let s = bundle.samples, let ivData = Data(base64Encoded: s.ivs) else { return nil }

        let sizes = s.sizes.split(separator: ",").compactMap { Int64($0) }
        guard sizes.count == s.count, ivData.count >= s.count * 8 else { return nil }

        self.key = keyData
        self.header = headerData

        var list: [(Int64, Int64, Data)] = []
        list.reserveCapacity(s.count)
        var off: Int64 = 0
        for i in 0..<s.count {
            let iv = ivData.subdata(in: (i * 8)..<((i + 1) * 8))
            list.append((off, sizes[i], iv))
            off += sizes[i]
        }
        self.samples = list
        // 头部 + 所有样本 = 解密后文件总长
        self.totalSize = Int64(headerData.count) + off
    }

    /// 解密 [start, end] 区间（解密后文件坐标）
    func decrypt(cipher: Data, cipherStart: Int64, range: Range<Int64>) -> Data {
        var out = Data(count: range.count)

        // 1) 头部区域：直接用清理过的 header
        let headerLen = Int64(header.count)
        if range.lowerBound < headerLen {
            let from = Int(range.lowerBound)
            let to = Int(min(range.upperBound, headerLen))
            if to > from {
                out.replaceSubrange(0..<(to - from), with: header.subdata(in: from..<to))
            }
        }

        // 2) 样本区域
        let sampleBase = headerLen
        for (sOff, sSize, iv) in samples {
            let absStart = sampleBase + sOff
            let absEnd = absStart + sSize
            if absEnd <= range.lowerBound { continue }
            if absStart >= range.upperBound { break }

            let from = max(absStart, range.lowerBound)
            let to = min(absEnd, range.upperBound)
            guard to > from else { continue }

            let cFrom = Int(from - cipherStart)
            let cTo = Int(to - cipherStart)
            guard cFrom >= 0, cTo <= cipher.count, cFrom < cTo else { continue }

            let chunk = cipher.subdata(in: cFrom..<cTo)
            let skip = Int(from - absStart)

            if let plain = Self.ctr(key: key, iv: iv, skip: skip, data: chunk) {
                let dFrom = Int(from - range.lowerBound)
                out.replaceSubrange(dFrom..<(dFrom + plain.count), with: plain)
            }
        }
        return out
    }

    /// AES-128-CTR（CommonCrypto，硬件加速）
    static func ctr(key: Data, iv: Data, skip: Int, data: Data) -> Data? {
        guard key.count == 16, !data.isEmpty else { return nil }

        // CENC 的 8 字节 IV 左补 0 成 16 字节 counter
        var counter = [UInt8](repeating: 0, count: 16)
        let ivb = [UInt8](iv)
        let n = min(ivb.count, 16)
        for i in 0..<n { counter[16 - n + i] = ivb[i] }

        // 把 skip 加进 counter（大端）
        var carry = skip
        var idx = 15
        while carry > 0 && idx >= 0 {
            let sum = Int(counter[idx]) + (carry & 0xFF)
            counter[idx] = UInt8(sum & 0xFF)
            carry = (carry >> 8) + (sum >> 8)
            idx -= 1
        }

        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            guard let outBase = outPtr.baseAddress else { return CCCryptorStatus(kCCParamError) }
            return data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { kPtr in
                    counter.withUnsafeBytes { ivPtr in
                        guard let cryptor = UnsafeMutablePointer<CCCryptorRef?>(
                            .allocate(capacity: 1)) else {
                            return CCCryptorStatus(kCCMemoryFailure)
                        }
                        defer { cryptor.deallocate() }
                        cryptor.pointee = nil

                        var st = CCCryptorCreateWithMode(
                            CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                            CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                            ivPtr.baseAddress, kPtr.baseAddress, key.count,
                            nil, 0, 0,
                            CCModeOptions(kCCModeOptionCTR_BE),
                            cryptor
                        )
                        guard st == kCCSuccess, let c = cryptor.pointee else { return st }

                        st = CCCryptorUpdate(c,
                                             inPtr.baseAddress, data.count,
                                             outBase, out.count, &moved)
                        CCCryptorRelease(c)
                        return st
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out
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

    init(decryptor: CENCDecryptor, cdnURL: URL) {
        self.decryptor = decryptor
        self.cdnURL = cdnURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    static func makeAssetURL() -> URL {
        // 用自定义 scheme 让 AVPlayer 走 resourceLoader
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

        // 填充内容信息
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

        // 头部区域完全在本地，不用请求 CDN
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

        // 需要 CDN 的部分
        let cdnFrom = max(start, headerLen) - headerLen
        let cdnTo = end - headerLen
        guard cdnTo >= cdnFrom else {
            loadingRequest.finishLoading()
            return true
        }

        var req = URLRequest(url: cdnURL)
        req.setValue("bytes=\(cdnFrom)-\(cdnTo)", forHTTPHeaderField: "Range")
        req.setValue("com.phoenix.read/74232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")

        let task = session.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            self.queue.async {
                defer { loadingRequest.finishLoading() }
                guard let data, !data.isEmpty else { return }

                let plain = self.decryptor.decrypt(
                    cipher: data,
                    cipherStart: cdnFrom,
                    range: start..<(end + 1)
                )

                // 头部已单独 respond 过，这里只发样本部分
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
