// 直连播放：整集下载 + 本地解密到文件 + 本地 HTTP 播放
//
// 为什么不再「边下边解」：
//   实测日志显示 AVPlayer 一次要 0-8388607（8MB），
//   而按 256KB 块串行去 CDN 拉 32 次，总耗时超过它的容忍上限，
//   直接报「请求超时 / 未知错误」。
//
// 现在改成两段式，彻底消除播放期的网络延迟：
//   1. EpisodeCache 并行分片下载整集密文 → 本地解密 → 写入临时文件
//   2. LocalStreamServer 从内存映射文件按 Range 提供 HTTP 服务
//      AVPlayer 拿到的是纯本地数据，响应是微秒级
//
// 代价：开始播放前要等 1~3 秒（下载 + 解密），有进度提示。
// 收益：播放过程零抖动，不会再超时。服务器带宽依旧只有几十 KB。
import Foundation
import Network

// MARK: - 整集缓存

final class EpisodeCache {

    enum CacheError: LocalizedError {
        case badBundle
        case tooLarge(Int64)
        case downloadFailed(String)
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .badBundle: return "密钥包无效"
            case .tooLarge(let n): return "文件过大（\(n / 1024 / 1024)MB），请改用转发模式"
            case .downloadFailed(let s): return "下载失败：\(s)"
            case .decryptFailed: return "解密失败"
            }
        }
    }

    struct Progress {
        var done: Int64
        var total: Int64
        var phase: String

        var fraction: Double {
            total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0
        }
    }

    /// 超过这个大小就放弃直连，避免内存和临时空间压力
    private static let maxBytes: Int64 = 120 * 1024 * 1024
    /// 并行分片数
    private static let slices = 6

    private let session: URLSession
    private let ua = "com.phoenix.read/74232 (Linux; U; Android 16; zh_CN; "
        + "25053RT47C; Build/BP2A.250605.031.A3)"

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg)
    }

    private var cacheDir: URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("hgcache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 已缓存的明文文件（同 vid 直接复用）
    func cachedFile(vid: String) -> URL? {
        let f = cacheDir.appendingPathComponent("\(vid).mp4")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0
        return size > 1024 ? f : nil
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    /// 下载 + 解密，返回本地明文文件 URL
    func prepare(vid: String,
                 bundle: HGKeyBundle,
                 progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {

        if let hit = cachedFile(vid: vid) { return hit }

        guard let decryptor = CENCDecryptor(bundle: bundle),
              let cdn = bundle.cdnURL, let cdnURL = URL(string: cdn) else {
            throw CacheError.badBundle
        }

        let total = decryptor.totalSize
        guard total > 0 else { throw CacheError.badBundle }
        guard total <= Self.maxBytes else { throw CacheError.tooLarge(total) }

        // 1) 并行分片下载密文
        progress(Progress(done: 0, total: total, phase: "下载"))
        let cipher = try await downloadAll(url: cdnURL, total: total, progress: progress)

        // 2) 整段解密（header 用清理版 / 样本 AES-CTR / 空洞透传）
        progress(Progress(done: total, total: total, phase: "解密"))
        var plain = decryptor.produce(cipher: cipher, cipherStart: 0, range: 0..<total)
        guard Int64(plain.count) == total else { throw CacheError.decryptFailed }

        // 3) 直接写入文件句柄，避免 Data.write 再复制一份
        let final = cacheDir.appendingPathComponent("\(vid).mp4")
        let part = cacheDir.appendingPathComponent("\(vid).part")
        do {
            FileManager.default.createFile(atPath: part.path, contents: nil)
            let fh = try FileHandle(forWritingTo: part)
            try fh.write(contentsOf: plain)
            try fh.close()
            plain.removeAll(keepingCapacity: false)

            if FileManager.default.fileExists(atPath: final.path) {
                try? FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: part, to: final)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw CacheError.downloadFailed(error.localizedDescription)
        }
        progress(Progress(done: total, total: total, phase: "就绪"))
        return final
    }

    // MARK: 并行下载

    private func downloadAll(url: URL,
                             total: Int64,
                             progress: @escaping @Sendable (Progress) -> Void) async throws -> Data {
        let n = Self.slices
        let chunk = (total + Int64(n) - 1) / Int64(n)

        var parts = [Data?](repeating: nil, count: n)
        let counter = AtomicCounter()

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for i in 0..<n {
                let s = Int64(i) * chunk
                let e = min(s + chunk, total) - 1
                guard e >= s else { continue }
                group.addTask { [session, ua] in
                    let d = try await Self.fetch(session: session, ua: ua,
                                                 url: url, from: s, to: e)
                    return (i, d)
                }
            }
            for try await (i, d) in group {
                parts[i] = d
                let done = counter.add(Int64(d.count))
                progress(Progress(done: done, total: total, phase: "下载"))
            }
        }

        var out = Data(capacity: Int(total))
        for i in 0..<n {
            guard let p = parts[i] else {
                throw CacheError.downloadFailed("分片 \(i) 缺失")
            }
            out.append(p)
        }
        guard Int64(out.count) == total else {
            throw CacheError.downloadFailed("长度 \(out.count) ≠ \(total)")
        }
        return out
    }

    private static func fetch(session: URLSession,
                              ua: String,
                              url: URL,
                              from: Int64,
                              to: Int64) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 30

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let want = Int(to - from + 1)

        if code == 206 {
            guard data.count >= want else {
                throw CacheError.downloadFailed("分片长度不足 \(data.count)/\(want)")
            }
            return data.prefix(want)
        }
        if code == 200 {
            // CDN 忽略 Range 整段返回，自己切
            let s = Int(from)
            let e = Int(min(to + 1, Int64(data.count)))
            guard s < e, e <= data.count else {
                throw CacheError.downloadFailed("分片越界")
            }
            return data.subdata(in: s..<e)
        }
        throw CacheError.downloadFailed("HTTP \(code)")
    }
}

// MARK: - 本地 HTTP 文件服务

final class LocalStreamServer: @unchecked Sendable {

    enum ServerError: LocalizedError {
        case listenFailed(String)
        case timeout
        case fileUnreadable

        var errorDescription: String? {
            switch self {
            case .listenFailed(let s): return "监听失败：\(s)"
            case .timeout: return "监听超时"
            case .fileUnreadable: return "文件不可读"
            }
        }
    }

    private let queue = DispatchQueue(label: "hg.localstream",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "hg.localstream.state")

    private var listener: NWListener?
    /// 内存映射，避免把整集读进 RAM
    private var mapped: Data?
    private var logLines: [String] = []

    func start(fileURL: URL) async throws -> UInt16 {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw ServerError.fileUnreadable
        }
        guard data.count > 0 else { throw ServerError.fileUnreadable }
        stateQueue.sync { mapped = data }

        let l: NWListener
        do {
            l = try NWListener(using: .tcp)
        } catch {
            throw ServerError.listenFailed(error.localizedDescription)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    if let p = l.port?.rawValue {
                        cont.resume(returning: p)
                    } else {
                        cont.resume(throwing: ServerError.listenFailed("未分配端口"))
                    }
                case .failed(let e):
                    guard once.claim() else { return }
                    cont.resume(throwing: ServerError.listenFailed(e.localizedDescription))
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + 4) {
                guard once.claim() else { return }
                cont.resume(throwing: ServerError.timeout)
            }
        }
        self.listener = l
        log("listen :\(port)  size=\(data.count)")
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateQueue.sync { mapped = nil }
    }

    func recentLog() -> [String] {
        stateQueue.sync { logLines }
    }

    private func log(_ s: String) {
        stateQueue.sync {
            logLines.append(s)
            if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
        }
    }

    // MARK: 连接

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let d = data, !d.isEmpty { buf.append(d) }

            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(conn, head: buf.subdata(in: 0..<r.lowerBound))
                return
            }
            if error != nil || isComplete || buf.count > 65536 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { conn.cancel(); return }
        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0]).uppercased()

        guard let data = stateQueue.sync(execute: { mapped }) else {
            conn.cancel()
            return
        }
        let total = Int64(data.count)

        var start: Int64 = 0
        var end: Int64 = -1
        var hasRange = false

        for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
            hasRange = true
            let v = l.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if let eq = v.firstIndex(of: "=") {
                let comps = v[v.index(after: eq)...]
                    .split(separator: "-", maxSplits: 1,
                           omittingEmptySubsequences: false)
                if comps.count == 2 {
                    if let s = Int64(comps[0]) { start = s }
                    if let e = Int64(comps[1]) { end = e }
                }
            }
        }

        if !hasRange {
            start = 0
            end = total - 1
        } else if end < 0 || end >= total {
            end = total - 1
        }
        if start < 0 { start = 0 }
        if start > end { conn.cancel(); return }

        // 本地文件，响应是微秒级，单次上限可以给到 16MB
        let maxChunk: Int64 = 16 * 1024 * 1024
        if end - start + 1 > maxChunk { end = start + maxChunk - 1 }

        log("\(method) \(start)-\(end)")

        if method == "HEAD" {
            let status = hasRange ? "206 Partial Content" : "200 OK"
            var h = "HTTP/1.1 \(status)\r\n"
            h += "Content-Type: video/mp4\r\n"
            h += "Content-Length: \(end - start + 1)\r\n"
            h += "Accept-Ranges: bytes\r\n"
            if hasRange {
                h += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
            }
            h += "Connection: close\r\n\r\n"
            sendAndClose(conn, Data(h.utf8))
            return
        }

        let body = data.subdata(in: Int(start)..<Int(end + 1))

        var h = "HTTP/1.1 206 Partial Content\r\n"
        h += "Content-Type: video/mp4\r\n"
        h += "Content-Length: \(body.count)\r\n"
        h += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        h += "Accept-Ranges: bytes\r\n"
        h += "Connection: close\r\n\r\n"

        var packet = Data(h.utf8)
        packet.append(body)
        sendAndClose(conn, packet)
    }

    private func sendAndClose(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - 小工具

final class AtomicCounter: @unchecked Sendable {
    private var value: Int64 = 0
    private let lock = NSLock()

    func add(_ n: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        value += n
        return value
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
