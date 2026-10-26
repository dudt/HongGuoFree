// 解析服务播放器
//
// 能力：
//   - 1080P / 多清晰度切换（服务端每个清晰度一个 vid 条目）
//   - 快进 15s / 倒退 15s
//   - 播放暂停
//   - 可拖动进度条
//   - 选集 + 自动连播
//
// 服务端已经把 CENC 解好，这里就是最普通的 AVPlayer。
import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - 清晰度

struct HGVariant: Identifiable, Hashable {
    var vid: String
    var label: String       // "1080P"
    var height: Int
    var url: URL

    var id: String { vid + label }
}

// MARK: - 播放器页

struct ResolverPlayerView: View {
    let seriesID: String
    let seriesTitle: String
    var startIndex: Int = 1

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var detail: HGServerDetail?
    @State private var current: HGServerEpisode?
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var errorText: String?
    @State private var showEpisodes = false
    @State private var showDebug = false
    @State private var debugLines: [String] = []

    // 播放状态
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    // 清晰度
    @State private var variants: [HGVariant] = []
    @State private var currentVariant: HGVariant?
    @State private var showQuality = false

    // 弹幕
    @StateObject private var danmaku = DanmakuEngine()
    @State private var dmCursor = ""
    @State private var dmLoading = false
    @State private var dmTotal = 0

    // 观察器
    @State private var timeObserver: Any?
    @State private var statusObs: NSKeyValueObservation?
    @State private var rateObs: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoSurface(player: player).ignoresSafeArea()
            }

            // 弹幕层（在视频之上、控制层之下）
            if danmaku.isEnabled, !danmaku.active.isEmpty {
                DanmakuOverlay(engine: danmaku, currentTime: progress)
                    .ignoresSafeArea()
            }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }

            if loading {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.3)
            }

            if let errorText {
                errorOverlay(errorText)
            }

            // 底部诊断入口
            VStack {
                Spacer()
                debugBar
            }
        }
        .statusBarHidden(true)
        .task { await loadDetail() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showQuality) { qualitySheet }
        .onDisappear { teardown() }
        .onTapGesture { toggleControls() }
    }

    // MARK: 控制层

    private var controlsOverlay: some View {
        VStack {
            // 顶部
            HStack(alignment: .top) {
                Button { teardown(); dismiss() } label: {
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
                    if let c = current {
                        Text("第 \(c.index) 集 / 共 \(detail?.totalEpisodes ?? 0) 集")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()

                // 弹幕开关
                Button {
                    danmaku.isEnabled.toggle()
                    log("弹幕 \(danmaku.isEnabled ? "开" : "关")")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: danmaku.isEnabled
                              ? "text.bubble.fill" : "text.bubble")
                        Text(danmaku.isEnabled ? "弹幕开" : "弹幕关")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(danmaku.isEnabled ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if !variants.isEmpty {
                    Button { showQuality = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.on.rectangle")
                            Text(currentVariant?.label ?? "清晰度")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.45))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button { showEpisodes = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                        Text("选集")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity((detail?.episodes?.isEmpty == false) ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer()

            // 中央：倒退 / 播放暂停 / 快进
            HStack(spacing: 44) {
                Button { skip(-15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button { togglePlay() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.plain)

                Button { skip(15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // 底部：进度条
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : progress },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            scrubValue = progress
                        } else {
                            player?.seek(to: CMTime(seconds: scrubValue,
                                                    preferredTimescale: 600),
                                         toleranceBefore: .zero,
                                         toleranceAfter: .zero)
                            progress = scrubValue
                        }
                    }
                )
                .tint(Palette.accent)

                HStack {
                    Text(fmt(isScrubbing ? scrubValue : progress))
                    Spacer()
                    Text(fmt(duration))
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 34)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }

    // MARK: 诊断条

    private var debugBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showDebug.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "ladybug.fill")
                        Text(showDebug ? "收起" : "诊断")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.4))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)

            if showDebug {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(debugLines.enumerated()), id: \.offset) { _, l in
                            Text(l)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 100)
                .background(.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
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
                                    .background(current?.vid == ep.vid ? Palette.accent : Palette.surface)
                                    .foregroundStyle(current?.vid == ep.vid ? .white : Palette.textPrimary)
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

    // MARK: 清晰度

    private var qualitySheet: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(variants) { v in
                            Button {
                                showQuality = false
                                Task { await switchQuality(v) }
                            } label: {
                                HStack {
                                    Text(v.label)
                                        .font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    if currentVariant?.vid == v.vid,
                                       currentVariant?.label == v.label {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Palette.accent)
                                    }
                                }
                                .foregroundStyle(Palette.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("清晰度")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 错误

    private func errorOverlay(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28)).foregroundStyle(.orange)
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("重试") { Task { await loadDetail() } }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20).padding(.vertical, 9)
                .background(Palette.accent).foregroundStyle(.white)
                .clipShape(Capsule()).buttonStyle(.plain)
        }
    }

    // MARK: 加载

    private func loadDetail() async {
        guard settings.hasResolver else {
            errorText = "还没配置解析服务。请到「我的 → 解析服务」填写。"
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let d = try await client.detail(seriesID: seriesID)
            detail = d
            let eps = d.episodes ?? []
            guard !eps.isEmpty else { errorText = "这部剧没有分集列表。"; return }
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
        debugLines.removeAll()

        do {
            let url = try client.streamURL(vid: ep.vid)
            log("播放 第\(ep.index)集 vid=\(ep.vid)")
            log("url=\(url.absoluteString)")

            // 拉清晰度列表（每个清晰度是一个独立 vid，服务端 /api/play 会告诉我们）
            await loadVariants(for: ep)

            removeAllObservers()

            let p = player ?? AVPlayer()
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 8
            observe(item: item)
            p.replaceCurrentItem(with: item)
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            current = ep
            duration = 0
            progress = 0

            // 时间轴 + 自动连播观察器必须在 replaceCurrentItem 之后装，
            // 否则 currentItem 还是旧的，回调绑不上。
            installTimeObserver()
            installEndObserver()

            p.play()
            isPlaying = true
            scheduleHideControls()

            // 弹幕：换集时清空并重新拉
            danmaku.clear()
            dmCursor = ""
            dmTotal = 0
            Task { await loadDanmaku(for: ep, reset: true) }
        } catch {
            errorText = error.localizedDescription
            log("ERR \(error.localizedDescription)")
        }
    }

    /// 清晰度：服务端 /api/play 返回当前质量，这里用「重新请求不同 preferredHeight」
    /// 简化实现——先拿到主 vid 的可用质量（服务端给最高），
    /// 其余档位由服务端按 vid 变化，交给 /api/play 的 quality 字段。
    private func loadVariants(for ep: HGServerEpisode) async {
        do {
            let p = try await client.play(vid: ep.vid)
            guard let url = try? client.streamURL(vid: ep.vid) else { return }
            let label = p.quality ?? "自动"
            let v = HGVariant(vid: ep.vid, label: label, height: Self.heightOf(label), url: url)
            variants = [v]
            currentVariant = v
            log("质量=\(label) (\(p.totalBytes ?? 0) 字节)")
        } catch {
            variants = []
        }
    }

    /// 拉整集弹幕。
    ///
    /// 上游按「时间窗」返回（一页约 30~90 秒窗口），而且很多剧的弹幕
    /// 集中在片尾，只拉第一页会拿到空结果。所以这里按 30 秒步长
    /// 遍历整集时长，把每个窗口都拉一遍再去重。
    private func loadDanmaku(for ep: HGServerEpisode, reset: Bool = false) async {
        guard !dmLoading else { return }
        dmLoading = true
        defer { dmLoading = false }

        // duration 此时可能还是 0（AVPlayer 未就绪），优先用服务端给的时长
        var secs = duration
        if secs <= 0 {
            if let p = try? await client.play(vid: ep.vid), let d = p.duration, d > 0 {
                secs = d
            }
        }
        let total = max(Int(secs.rounded()), 120)
        let step = 30
        var collected: [String: HGDmakuItem] = [:]
        var reportedTotal = 0

        // 从 0 开始，每 30 秒一个窗口
        var offset = 0
        while offset <= total + step {
            do {
                let page = try await client.danmaku(
                    vid: ep.vid, seriesID: seriesID, cursor: "", offsetMs: offset * 1000
                )
                if reportedTotal == 0 { reportedTotal = page.total ?? 0 }
                for it in page.items ?? [] {
                    collected[it.id] = it
                }
                // 该窗口还有更多：沿 cursor 继续
                var cur = page.nextCursor ?? ""
                var guardCount = 0
                while page.hasMore == true, !cur.isEmpty, guardCount < 2 {
                    guardCount += 1
                    let more = try await client.danmaku(
                        vid: ep.vid, seriesID: seriesID, cursor: cur
                    )
                    for it in more.items ?? [] { collected[it.id] = it }
                    if more.nextCursor == cur { break }
                    cur = more.nextCursor ?? ""
                }
            } catch {
                log("弹幕 offset=\(offset)s 失败 \(error.localizedDescription)")
            }
            offset += step
        }

        let items = collected.values.sorted { $0.offsetMs < $1.offsetMs }
        dmTotal = max(reportedTotal, items.count)
        danmaku.load(items)
        log("弹幕 \(items.count) 条 / 上游报告 \(dmTotal)")
    }

    private func switchQuality(_ v: HGVariant) async {
        guard let p = player else { return }
        let t = p.currentTime().seconds
        let wasPlaying = isPlaying
        let item = AVPlayerItem(url: v.url)
        item.preferredForwardBufferDuration = 8
        observe(item: item)
        p.replaceCurrentItem(with: item)
        currentVariant = v
        // 换了 item，结束通知要重新绑定到新的 currentItem
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        installEndObserver()
        if t.isFinite, t > 0 {
            await p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying { p.play() }
        log("切清晰度 -> \(v.label)")
    }

    private static func heightOf(_ label: String) -> Int {
        let digits = label.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    // MARK: 观察

    private func observe(item: AVPlayerItem) {
        statusObs?.invalidate()
        statusObs = item.observe(\.status, options: [.initial, .new]) { obj, _ in
            Task { @MainActor in
                switch obj.status {
                case .readyToPlay:
                    let d = obj.duration.seconds
                    if d.isFinite, d > 0 { duration = d }
                    log("ready dur=\(String(format: "%.1f", d))")
                case .failed:
                    let ns = obj.error as NSError?
                    log("failed \(obj.error?.localizedDescription ?? "?") [\(ns?.code ?? 0)]")
                    errorText = "播放失败：\(obj.error?.localizedDescription ?? "未知")"
                case .unknown:
                    log("status=unknown")
                @unknown default: break
                }
            }
        }
    }

    private func installTimeObserver() {
        guard let p = player, timeObserver == nil else { return }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { t in
            guard !isScrubbing else { return }
            let s = t.seconds
            if s.isFinite {
                progress = s
                danmaku.tick(currentTime: s)
            }
            let d = p.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { duration = d }
        }
    }

    private func installEndObserver() {
        guard let item = player?.currentItem, endObserver == nil else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            Task { await playNext() }
        }
    }

    private func removeAllObservers() {
        if let t = timeObserver, let p = player { p.removeTimeObserver(t) }
        timeObserver = nil
        statusObs?.invalidate(); statusObs = nil
        rateObs?.invalidate(); rateObs = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
    }

    // MARK: 控制

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        scheduleHideControls()
    }

    private func skip(_ seconds: Double) {
        guard let p = player else { return }
        let t = p.currentTime().seconds + seconds
        let maxT = max(duration, 1)
        let target = min(max(t, 0), maxT)
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        progress = target
        scheduleHideControls()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        if controlsVisible { scheduleHideControls() }
    }

    private func scheduleHideControls() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !showEpisodes, !showQuality, !isScrubbing else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
            }
        }
    }

    private func playNext() async {
        guard let d = detail, let c = current,
              let eps = d.episodes,
              let i = eps.firstIndex(where: { $0.vid == c.vid }),
              i + 1 < eps.count else { return }
        await playEpisode(eps[i + 1])
    }

    private func teardown() {
        hideTask?.cancel()
        removeAllObservers()
        player?.pause()
        player = nil
    }

    private func log(_ s: String) {
        debugLines.append(s)
        if debugLines.count > 40 { debugLines.removeFirst() }
        #if DEBUG
        print("[Resolver] \(s)")
        #endif
    }

    private func fmt(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "00:00" }
        let s = Int(sec)
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, ss)
            : String(format: "%02d:%02d", m, ss)
    }
}

// MARK: - AVPlayerLayer

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
