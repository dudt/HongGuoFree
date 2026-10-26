// 本地 HTTP 流服务
//
// 设计要点（都是踩过的坑）：
//
// 1. 为什么不用 AVAssetResourceLoader
//    自定义 scheme 下 AVPlayer 的 Range 探测极其挑剔，稍有偏差就整段
//    放弃并报「操作已停止」。走本地 HTTP 是它最熟悉的路。
//
// 2. 每个连接只处理一个请求，响应后关闭
//    流水线/keep-alive 在自研服务里很容易乱序，AVPlayer 会等超时。
//    它自己会重连，代价可接受，换来的是确定性。
//
// 3. 拉取失败返回 503，绝不补零
//    早期版本 CDN 失败时用 Data(count:) 补零，结果 AVPlayer 拿到
//    全零样本，解码失败后报「未知错误」。返回 503 它会自己重试。
//
// 4. HEAD 带 Range 时返回 206
//    AVPlayer 会用 HEAD+Range 探测是否支持断点，回 200 会让它误判。
//
// 5. 请求日志
//    暴露 /debug 端点，真机出问题时可以直接看服务收到了什么。
import Foundation
import Network

final class LocalStreamServer: @unchecked Sendable {

    enum ServerError: LocalizedError {
        case listenFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .listenFailed(let s): return "监听失败：\(s)"
            case .timeout: return "监听超时"
            }
        }
    }

    private let decryptor: CENCDecryptor
    private let cdnURL: URL
    private let session: URLSession

    private let queue = DispatchQueue(label: "hg.localstream",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "hg.localstream.state")

    private var listener: NWListener?
    private var blocks: [Int64: Data] = [:]
    private var blockOrder: [Int64] = []
    private(set) var logLines: [String] = []

    private let blockSize: Int64 = 256 * 1024
    private let maxResponse: Int64 = 8 * 1024 * 1024
    private let maxCachedBlocks = 80

    private let ua = "com.phoenix.read/74232 (Linux; U; Android 16; zh_CN; "
        + "25053RT47C; Build/BP2A.250605.031.A3)"

    init(decryptor: CENCDecryptor, cdnURL: URL) {
        self.decryptor = decryptor
        self.cdnURL = cdnURL
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg)
    }

    // MARK: 日志

    private func log(_ s: String) {
        stateQueue.sync {
            logLines.append(s)
            if logLines.count > 80 { logLines.removeFirst(logLines.count - 80) }
        }
    }

    func recentLog() -> [String] {
        stateQueue.sync { logLines }
    }

    // MARK: 启停

    func start() async throws -> UInt16 {
        // 不设 requiredLocalEndpoint：那套 API 在部分 iOS 版本上
        // 会让 listener 一直停在 .setup。直接不指定端口让它自己分配。
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
        log("listen :\(port)  total=\(decryptor.totalSize)")
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateQueue.sync {
            blocks.removeAll()
            blockOrder.removeAll()
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
                let head = buf.subdata(in: 0..<r.lowerBound)
                self.respond(conn, head: head)
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
        let path = String(parts[1])

        // /debug：返回服务状态
        if path.hasPrefix("/debug") {
            let body = Data(recentLog().joined(separator: "\n").utf8)
            var h = "HTTP/1.1 200 OK\r\n"
            h += "Content-Type: text/plain; charset=utf-8\r\n"
            h += "Content-Length: \(body.count)\r\n"
            h += "Connection: close\r\n\r\n"
            var p = Data(h.utf8); p.append(body)
            sendAndClose(conn, p)
            return
        }

        var start: Int64 = 0
        var end: Int64 = -1
        var hasRange = false

        for l in lines.dropFirst() {
            let low = l.lowercased()
            if low.hasPrefix("range:") {
                hasRange = true
                let v = l.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if let eq = v.firstIndex(of: "=") {
                    let spec = v[v.index(after: eq)...]
                    let comps = spec.split(separator: "-", maxSplits: 1,
                                           omittingEmptySubsequences: false)
                    if comps.count == 2 {
                        if let s = Int64(comps[0]) { start = s }
                        if let e = Int64(comps[1]) { end = e }
                    }
                }
            }
        }

        let total = decryptor.totalSize
        guard total > 0 else { conn.cancel(); return }

        if !hasRange {
            start = 0
            end = total - 1
        } else if end < 0 || end >= total {
            end = total - 1
        }
        if start < 0 { start = 0 }
        if start > end { conn.cancel(); return }
        if end - start + 1 > maxResponse { end = start + maxResponse - 1 }

        log("\(method) \(hasRange ? "\(start)-\(end)" : "full")")

        // HEAD：只回头
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

        // GET：拼数据。任何一块拉失败就回 503，让 AVPlayer 重试。
        guard let body = assemble(from: start, to: end) else {
            log("503 \(start)-\(end) 拉取失败")
            let h = "HTTP/1.1 503 Service Unavailable\r\n"
                + "Content-Length: 0\r\n"
                + "Retry-After: 1\r\n"
                + "Connection: close\r\n\r\n"
            sendAndClose(conn, Data(h.utf8))
            return
        }

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

    // MARK: 数据组装

    /// 返回 nil 表示有块拉取失败（不要补零）
    private func assemble(from start: Int64, to end: Int64) -> Data? {
        let need = Int(end - start + 1)
        var out = Data()
        out.reserveCapacity(need)

        let firstBlock = start / blockSize
        let lastBlock = end / blockSize
        var b = firstBlock
        while b <= lastBlock {
            guard let block = blockData(b) else { return nil }
            let bStart = b * blockSize
            let bEnd = bStart + Int64(block.count) - 1
            let f = max(bStart, start)
            let t = min(bEnd, end)
            if t >= f {
                let a = Int(f - bStart)
                let z = Int(t - bStart) + 1
                if a >= 0, z <= block.count, a < z {
                    out.append(block.subdata(in: a..<z))
                }
            }
            b += 1
        }
        guard out.count == need else { return nil }
        return out
    }

    private func blockData(_ index: Int64) -> Data? {
        if let hit = stateQueue.sync(execute: { blocks[index] }) { return hit }

        let bStart = index * blockSize
        let bEnd = min(bStart + blockSize, decryptor.totalSize) - 1
        guard bEnd >= bStart else { return nil }

        let headerLen = Int64(decryptor.header.count)
        let cdnStart = max(bStart, headerLen)

        var cipher = Data()
        if bEnd >= cdnStart {
            guard let fetched = fetchCDN(from: cdnStart, to: bEnd) else {
                log("CDN 失败 \(cdnStart)-\(bEnd)")
                return nil
            }
            cipher = fetched
        }

        let plain = decryptor.produce(cipher: cipher,
                                      cipherStart: cdnStart,
                                      range: bStart..<(bEnd + 1))
        stateQueue.sync {
            if blocks[index] == nil {
                blocks[index] = plain
                blockOrder.append(index)
                while blockOrder.count > maxCachedBlocks {
                    let old = blockOrder.removeFirst()
                    blocks.removeValue(forKey: old)
                }
            }
        }
        return plain
    }

    private func fetchCDN(from: Int64, to: Int64) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var code = 0

        var req = URLRequest(url: cdnURL)
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 25

        let task = session.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let d = data, !d.isEmpty { result = d }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 28)

        guard let d = result else {
            log("CDN 空响应 code=\(code)")
            return nil
        }
        // 206 才是精确区间；200 表示服务器忽略了 Range，整段返回
        if code == 206 {
            let want = Int(to - from + 1)
            if d.count < want { return nil }
            return d.prefix(want)
        }
        if code == 200 {
            // 整文件返回：切出需要的段
            let s = Int(from)
            let e = Int(min(to + 1, Int64(d.count)))
            guard s < e, e <= d.count else { return nil }
            return d.subdata(in: s..<e)
        }
        log("CDN code=\(code)")
        return nil
    }
}

/// 保证 continuation 只 resume 一次
private final class OnceFlag: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
