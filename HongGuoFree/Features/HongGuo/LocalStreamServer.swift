// 本地 HTTP 流服务
//
// 为什么不再用 AVAssetResourceLoader：
//   自定义 scheme + resourceLoader 在 MP4 渐进式播放上非常脆弱，
//   AVPlayer 内部会做大量 Range 探测，稍有偏差就整段放弃并报
//   「操作已停止」。这条路反复调不通。
//
// 现在的做法：在 App 内起一个只监听 127.0.0.1 的 HTTP 服务，
//   AVPlayer 连 http://127.0.0.1:PORT/stream.mp4，
//   服务端按 Range 去 CDN 拉密文 → 本地解密 → 返回明文。
//
//   AVPlayer 走的是它最熟悉的原生 HTTP 栈，Range/HEAD/keep-alive
//   全部按标准行为处理，不存在私有 API 的坑。
//   带宽依旧不经过自建服务器（只有几十 KB 的密钥包）。
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

    /// 并发处理多个连接；每个连接内部按需阻塞等 CDN
    private let queue = DispatchQueue(label: "hg.localstream",
                                      qos: .userInitiated,
                                      attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "hg.localstream.state")

    private var listener: NWListener?
    private var blocks: [Int64: Data] = [:]
    private var blockOrder: [Int64] = []

    /// 缓存块大小（AVPlayer 会反复请求相近区间）
    private let blockSize: Int64 = 128 * 1024
    /// 单次响应上限，避免一次吐太多
    private let maxResponse: Int64 = 4 * 1024 * 1024
    private let maxCachedBlocks = 120

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

    // MARK: 启停

    /// 启动并返回实际端口
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只绑回环，避免局域网可访问 + 触发本地网络权限弹窗
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: .any)

        let l: NWListener
        do {
            l = try NWListener(using: params)
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

            // 3 秒兜底
            self.queue.asyncAfter(deadline: .now() + 3) {
                guard once.claim() else { return }
                cont.resume(throwing: ServerError.timeout)
            }
        }
        self.listener = l
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

    // MARK: 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let d = data, !d.isEmpty { buf.append(d) }

            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf.subdata(in: 0..<r.lowerBound)
                self.respond(conn, head: head)
                return
            }
            if error != nil || isComplete || buf.count > 32 * 1024 {
                conn.cancel()
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, head: Data) {
        let text = String(decoding: head, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { conn.cancel(); return }
        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0]).uppercased()

        var start: Int64 = 0
        var end: Int64 = -1
        var hasRange = false
        var wantsClose = false

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
            } else if low.hasPrefix("connection:") {
                if low.contains("close") { wantsClose = true }
            }
        }

        let total = decryptor.totalSize
        guard total > 0 else { conn.cancel(); return }

        if !hasRange { start = 0; end = total - 1 }
        if end < 0 || end >= total { end = total - 1 }
        if start < 0 { start = 0 }
        if start > end { conn.cancel(); return }
        if end - start + 1 > maxResponse { end = start + maxResponse - 1 }

        // HEAD：只回头
        if method == "HEAD" {
            let h = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: video/mp4\r\n"
                + "Content-Length: \(total)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Connection: \(wantsClose ? "close" : "keep-alive")\r\n\r\n"
            send(conn, Data(h.utf8), close: wantsClose)
            return
        }

        // GET：拼数据
        let body = assemble(from: start, to: end)
        var h = "HTTP/1.1 206 Partial Content\r\n"
        h += "Content-Type: video/mp4\r\n"
        h += "Content-Length: \(body.count)\r\n"
        h += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        h += "Accept-Ranges: bytes\r\n"
        h += "Connection: \(wantsClose ? "close" : "keep-alive")\r\n\r\n"

        var packet = Data(h.utf8)
        packet.append(body)
        send(conn, packet, close: wantsClose)
    }

    private func send(_ conn: NWConnection, _ data: Data, close: Bool) {
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil || close {
                conn.cancel()
                return
            }
            // keep-alive：继续读下一个请求
            self.readRequest(conn, buffer: Data())
        })
    }

    // MARK: 数据组装

    private func assemble(from start: Int64, to end: Int64) -> Data {
        let need = Int(end - start + 1)
        var out = Data()
        out.reserveCapacity(need)

        let firstBlock = start / blockSize
        let lastBlock = end / blockSize
        var b = firstBlock
        while b <= lastBlock {
            guard let block = blockData(b) else { break }
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
        if out.count < need { out.append(Data(count: need - out.count)) }
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
            cipher = fetchCDN(from: cdnStart, to: bEnd)
                ?? Data(count: Int(bEnd - cdnStart + 1))
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

    /// 同步拉一段 CDN 密文（连接队列是并发的，阻塞可接受）
    private func fetchCDN(from: Int64, to: Int64) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?

        var req = URLRequest(url: cdnURL)
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 25

        let task = session.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let data, !data.isEmpty else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 200/206 都接受；206 时若起始不符则放弃（避免错位）
            if code == 206 || code == 200 {
                result = data
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 28)
        return result
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
