// 解析服务播放页
//
// 直接拿服务端的 /api/stream?vid=xxx 喂给 AVPlayer —— 服务端已经把 CENC 解好，
// 所以这里就是最普通的 AVPlayer 播放，没有任何解密逻辑。
import SwiftUI
import AVKit

struct ResolverPlayerView: View {
    let seriesID: String
    let seriesTitle: String
    /// 从第几集开始（1 起）
    var startIndex: Int = 1

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var detail: HGServerDetail?
    @State private var current: HGServerEpisode?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var errorText: String?
    @State private var showEpisodes = false
    @State private var timeObserver: Any?
    @State private var duration: Double = 0
    @State private var progress: Double = 0
    @State private var statusObservation: NSKeyValueObservation?
    @State private var keepUpObservation: NSKeyValueObservation?
    @State private var debugLines: [String] = []
    @State private var showDebug = false

    private func debugLog(_ s: String) {
        #if DEBUG
        print("[Resolver] \(s)")
        #endif
        let stamp = String(format: "%.1f", Date().timeIntervalSince1970
            .truncatingRemainder(dividingBy: 1000))
        debugLines.append("[\(stamp)] \(s)")
        if debugLines.count > 14 { debugLines.removeFirst() }
    }

    private var client: HGServerClient {
        HGServerClient(config: settings.resolverConfig)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 关键：player 未就绪时不要挂 VideoSurface，
            // 否则 AVPlayerLayer 可能绑定到 nil 就再也不更新。
            if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
            }

            // 顶部信息 / 关闭
            VStack {
                HStack(alignment: .top) {
                    Button {
                        teardown()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(seriesTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let current {
                            Text("第 \(current.index) 集"
                                 + (detail.map { " / 共 \($0.totalEpisodes ?? 0) 集" } ?? ""))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    if let d = detail {
                        Button {
                            showEpisodes = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet")
                                Text("选集")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.45))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(d.episodes?.isEmpty == false ? 1 : 0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // 底部进度
                if let player {
                    VStack(spacing: 8) {
                        Slider(value: $progress, in: 0...max(duration, 1)) { editing in
                            if !editing {
                                player.seek(to: CMTime(seconds: progress,
                                                       preferredTimescale: 600))
                            }
                        }
                        .tint(Palette.accent)

                        HStack {
                            Text(fmt(progress))
                            Spacer()
                            Text(fmt(duration))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                }
            }

            if loading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            }

            // 常驻调试条：黑屏时点一下就能看到 AVPlayer 到底卡在哪
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        showDebug.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "ladybug.fill")
                            Text(showDebug ? "收起诊断" : "诊断")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if showDebug {
                    VStack(alignment: .leading, spacing: 3) {
                        if debugLines.isEmpty {
                            Text("暂无日志（点「重试」生成）")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        ForEach(Array(debugLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
            }

            if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 12) {
                        Button("重试") {
                            Task { await loadDetail() }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(Palette.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)

                        Button(showDebug ? "隐藏详情" : "查看详情") {
                            showDebug.toggle()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.15))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                    }

                    if showDebug, !debugLines.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(debugLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: 160)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .task { await loadDetail() }
        .sheet(isPresented: $showEpisodes) {
            episodeSheet
        }
        .onDisappear { teardown() }
    }

    // MARK: 选集

    private var episodeSheet: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                             count: 5), spacing: 8) {
                        ForEach(detail?.episodes ?? []) { ep in
                            Button {
                                showEpisodes = false
                                Task { await playEpisode(ep) }
                            } label: {
                                Text("\(ep.index)")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(current?.vid == ep.vid
                                                ? Palette.accent
                                                : Palette.surface)
                                    .foregroundStyle(current?.vid == ep.vid
                                                     ? .white
                                                     : Palette.textPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 加载

    private func loadDetail() async {
        guard settings.hasResolver else {
            errorText = "还没配置解析服务。请到「我的 → 解析服务」填写地址。"
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }

        do {
            let d = try await client.detail(seriesID: seriesID)
            detail = d
            let eps = d.episodes ?? []
            guard !eps.isEmpty else {
                errorText = "这部剧没有拿分集列表。"
                return
            }
            let target = eps.first(where: { $0.index == startIndex }) ?? eps[0]
            await playEpisode(target)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func playEpisode(_ ep: HGServerEpisode) async {
        loading = true
        errorText = nil
        defer { loading = false }

        do {
            let url = try client.streamURL(vid: ep.vid)
            debugLog("stream url = \(url.absoluteString)")

            let asset = AVURLAsset(url: url, options: [
                // 明确告诉 AVPlayer 这是普通的渐进式 MP4
                "AVURLAssetHTTPHeaderFieldsKey": ["Accept": "*/*"],
            ])
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 8
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

            // 监听失败原因，否则黑屏没有任何线索
            observeItemStatus(item)

            let p = player ?? AVPlayer()
            p.replaceCurrentItem(with: item)
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            current = ep
            duration = 0
            progress = 0
            installObservers(on: p, item: item)

            p.play()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 监听 AVPlayerItem 状态与错误，把失败原因显示到界面上
    private func observeItemStatus(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.initial, .new]) { obj, _ in
            Task { @MainActor in
                switch obj.status {
                case .readyToPlay:
                    let d = obj.duration.seconds
                    debugLog("status=readyToPlay dur=\(d)")
                    if d.isFinite, d > 0 { duration = d }
                    let ranges = obj.loadedTimeRanges
                        .compactMap { $0.timeRangeValue }
                        .map { String(format: "%.0f-%.0f",
                                      $0.start.seconds,
                                      ($0.start + $0.duration).seconds) }
                    debugLog("buffered: \(ranges.joined(separator: ","))")
                    if errorText?.hasPrefix("播放失败") == true { errorText = nil }
                case .failed:
                    let msg = obj.error?.localizedDescription ?? "未知错误"
                    let ns = obj.error as NSError?
                    debugLog("status=failed \(msg) [\(ns?.domain ?? "?") \(ns?.code ?? 0)]")
                    // ATS 拦截的典型特征
                    if let ns, ns.domain == NSURLErrorDomain, ns.code == -1022 {
                        errorText = "被 App Transport Security 拦截（-1022）\n需要 NSAllowsArbitraryLoadsForMedia"
                    } else {
                        errorText = "播放失败：\(msg)\n(\(ns?.domain ?? "") \(ns?.code ?? 0))"
                    }
                case .unknown:
                    debugLog("status=unknown（仍在加载）")
                @unknown default:
                    break
                }
            }
        }

        // 也监听 playbackLikelyToKeepUp 和 bufferEmpty，黑屏时能看出卡在哪
        keepUpObservation?.invalidate()
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp,
                                          options: [.new]) { obj, _ in
            Task { @MainActor in
                debugLog("keepUp=\(obj.isPlaybackLikelyToKeepUp) "
                         + "bufferEmpty=\(obj.isPlaybackBufferEmpty) "
                         + "bufferFull=\(obj.isPlaybackBufferFull)")
            }
        }
    }

    private func installObservers(on player: AVPlayer, item: AVPlayerItem) {
        removeObservers()

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { t in
            let secs = t.seconds
            if secs.isFinite {
                progress = secs
                let d = player.currentItem?.duration.seconds ?? 0
                if d.isFinite, d > 0 { duration = d }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { await playNext() }
        }
    }

    private func removeObservers() {
        if let t = timeObserver, let p = player {
            p.removeTimeObserver(t)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        keepUpObservation?.invalidate()
        keepUpObservation = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func playNext() async {
        guard let d = detail, let c = current,
              let eps = d.episodes,
              let idx = eps.firstIndex(where: { $0.vid == c.vid }),
              idx + 1 < eps.count else { return }
        await playEpisode(eps[idx + 1])
    }

    private func teardown() {
        removeObservers()
        player?.pause()
        player = nil
    }

    private func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - AVPlayerLayer 包装

/// SwiftUI 里最轻的 AVPlayer 显示层
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.attach(player)
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.attach(player)
    }
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    func attach(_ player: AVPlayer) {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }
}
