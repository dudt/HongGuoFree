// 播放器
//
// 交互：
//   单击      显示/隐藏控制层
//   双击左半  后退 10 秒
//   双击右半  前进 10 秒
//   横向拖动  拖动进度（松手跳转）
//   纵向拖动  左半调亮度、右半调音量
//   控制层    播放/暂停、±15 秒、进度条、倍速、清晰度、弹幕设置、选集
import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - 清晰度

struct HGVariant: Identifiable, Hashable {
    var vid: String
    var label: String
    var url: URL
    var id: String { vid + label }
}

// MARK: - 播放器页

struct ResolverPlayerView: View {
    let seriesID: String
    let seriesTitle: String
    var startIndex: Int = 1

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: HGLibraryStore
    @Environment(\.dismiss) private var dismiss

    // 数据
    @State private var detail: HGServerDetail?
    @State private var current: HGServerEpisode?
    @State private var variants: [HGVariant] = []
    @State private var currentVariant: HGVariant?
    @State private var loading = false
    @State private var errorText: String?
    @State private var debugLines: [String] = []

    // 播放
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var rate: Float = 1.0
    @State private var lastSavedSecond = -1

    // 弹幕
    @StateObject private var danmaku = DanmakuEngine()

    // 控制层
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showEpisodes = false
    @State private var showQuality = false
    @State private var showDanmakuSettings = false
    @State private var showDebug = false

    // 手势
    @State private var dragStartTime: Double = 0
    @State private var dragDeltaX: CGFloat = 0
    @State private var isDraggingSeek = false
    @State private var dragAxis: DragAxis = .none
    @State private var lastTapTime: Date = .distantPast
    @State private var seekHint: String?
    @State private var hintTask: Task<Void, Never>?

    private enum DragAxis { case none, horizontal, vertical }

    // 观察器
    @State private var timeObserver: Any?
    @State private var statusObs: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoSurface(player: player).ignoresSafeArea()
                DanmakuOverlay(engine: danmaku, playerTime: progress, isPaused: !isPlaying)
                    .ignoresSafeArea()
            }

            // 手势层
            gestureLayer

            if controlsVisible {
                controlsOverlay.transition(.opacity)
            }

            if let seekHint {
                Text(seekHint)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if loading {
                ProgressView().tint(.white).scaleEffect(1.3)
            }

            if let errorText {
                errorOverlay(errorText)
            }
        }
        .statusBarHidden(true)
        .task { await loadDetail() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showQuality) { qualitySheet }
        .sheet(isPresented: $showDanmakuSettings) { danmakuSettingsSheet }
        .onDisappear { teardown() }
    }

    // MARK: 手势

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    handleDoubleTap(location, in: geo.size)
                }
                .onTapGesture { toggleControls() }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in handleDragChanged(v, in: geo.size) }
                        .onEnded { v in handleDragEnded(v, in: geo.size) }
                )
        }
    }

    private func handleDoubleTap(_ location: CGPoint, in size: CGSize) {
        if location.x < size.width / 2 {
            skip(-10)
            showHint("« 10s")
        } else {
            skip(10)
            showHint("10s »")
        }
    }

    private func handleDragChanged(_ v: DragGesture.Value, in size: CGSize) {
        if dragAxis == .none {
            dragAxis = abs(v.translation.width) > abs(v.translation.height)
                ? .horizontal : .vertical
            if dragAxis == .horizontal {
                dragStartTime = progress
                isDraggingSeek = true
            }
        }

        if dragAxis == .horizontal {
            // 每 12pt 对应 1 秒
            let delta = Double(v.translation.width) / 12.0
            let target = min(max(dragStartTime + delta, 0), max(duration, 1))
            scrubValue = target
            showHint("\(fmt(target)) / \(fmt(duration))")
        }
    }

    private func handleDragEnded(_ v: DragGesture.Value, in size: CGSize) {
        if dragAxis == .horizontal, isDraggingSeek {
            player?.seek(to: CMTime(seconds: scrubValue, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
            progress = scrubValue
            isDraggingSeek = false
        }
        dragAxis = .none
        dragDeltaX = 0
        hideHintSoon()
    }

    private func showHint(_ s: String) {
        hintTask?.cancel()
        seekHint = s
    }

    private func hideHintSoon() {
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { seekHint = nil }
        }
    }

    // MARK: 控制层

    private var controlsOverlay: some View {
        VStack {
            topBar
            Spacer()
            centerButtons
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { teardown(); dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(seriesTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let c = current {
                    Text("第 \(c.index) 集 / 共 \(detail?.totalEpisodes ?? 0) 集")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()

            chip(danmaku.settings.enabled ? "弹幕开" : "弹幕关",
                 icon: danmaku.settings.enabled ? "text.bubble.fill" : "text.bubble",
                 active: danmaku.settings.enabled) {
                danmaku.settings.enabled.toggle()
            }
            chip("弹幕设置", icon: "slider.horizontal.3", active: false) {
                showDanmakuSettings = true
            }
            if !variants.isEmpty {
                chip(currentVariant?.label ?? "清晰度",
                     icon: "rectangle.on.rectangle", active: false) {
                    showQuality = true
                }
            }
            chip("选集", icon: "list.bullet", active: false) {
                showEpisodes = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 120).offset(y: -20)
        )
    }

    private func chip(_ title: String, icon: String, active: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? .white : .white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var centerButtons: some View {
        HStack(spacing: 40) {
            Button { skip(-15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 28)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40)).foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button { skip(15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 28)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            // 进度条
            HStack(spacing: 8) {
                Text(fmt(isDraggingSeek ? scrubValue : progress))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 46, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { isDraggingSeek ? scrubValue : progress },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        isDraggingSeek = editing
                        if editing { scrubValue = progress }
                        else {
                            player?.seek(to: CMTime(seconds: scrubValue,
                                                    preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
                            progress = scrubValue
                        }
                    }
                )
                .tint(Palette.accent)

                Text(fmt(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 46, alignment: .trailing)
            }

            // 倍速
            HStack(spacing: 8) {
                Text("倍速")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button {
                        setRate(Float(r))
                    } label: {
                        Text(r == 1.0 ? "1x" : "\(r)x")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(abs(rate - Float(r)) < 0.01
                                             ? .white : .white.opacity(0.55))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(abs(rate - Float(r)) < 0.01
                                        ? Palette.accent : .white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if danmaku.total > 0 {
                    Text("弹幕 \(danmaku.total)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 130).offset(y: 30)
        )
    }

    // MARK: 错误

    private func errorOverlay(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26)).foregroundStyle(.orange)
            Text(msg)
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            HStack(spacing: 10) {
                Button("重试") { Task { await loadDetail() } }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Palette.accent).foregroundStyle(.white)
                    .clipShape(Capsule()).buttonStyle(.plain)
                Button(showDebug ? "隐藏日志" : "查看日志") { showDebug.toggle() }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.white.opacity(0.15)).foregroundStyle(.white)
                    .clipShape(Capsule()).buttonStyle(.plain)
            }
            if showDebug {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(debugLines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(8)
                }
                .frame(maxHeight: 140)
                .background(.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: 选集 / 清晰度 / 弹幕设置

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
                                                ? Palette.accent : Palette.surface)
                                    .foregroundStyle(current?.vid == ep.vid
                                                     ? .white : Palette.textPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

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
                                    Text(v.label).font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    if currentVariant?.vid == v.vid {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Palette.accent)
                                    }
                                }
                                .foregroundStyle(Palette.textPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(Palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
            .navigationTitle("清晰度")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var danmakuSettingsSheet: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // 显示区域
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("显示区域").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer()
                                Text("\(Int(danmaku.settings.areaRatio * 100))%")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Slider(value: $danmaku.settings.areaRatio, in: 0.15...1.0)
                                .tint(Palette.accent)
                            Text("控制弹幕占屏幕的高度比例")
                                .font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                        }

                        // 顶部留白
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("顶部留白").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer()
                                Text("\(Int(danmaku.settings.topInset))pt")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Slider(value: $danmaku.settings.topInset, in: 0...200)
                                .tint(Palette.accent)
                        }

                        // 字号
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("字号").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer()
                                Text("\(Int(danmaku.settings.fontSize))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Slider(value: $danmaku.settings.fontSize, in: 11...30, step: 1)
                                .tint(Palette.accent)
                        }

                        // 速度
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("滚动时长").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer()
                                Text(String(format: "%.1fs", danmaku.settings.duration))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Slider(value: $danmaku.settings.duration, in: 3...14)
                                .tint(Palette.accent)
                            Text("越小滚得越快")
                                .font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                        }

                        // 不透明度
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("不透明度").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Palette.textPrimary)
                                Spacer()
                                Text("\(Int(danmaku.settings.opacity * 100))%")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Slider(value: $danmaku.settings.opacity, in: 0.2...1.0)
                                .tint(Palette.accent)
                        }

                        Toggle("文字描边", isOn: $danmaku.settings.stroke)
                            .font(.system(size: 13))
                            .tint(Palette.accent)

                        Button {
                            Task { await reloadDanmaku() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text(danmaku.loading ? "重新拉取中…" : "重新拉取弹幕")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Palette.surface)
                            .foregroundStyle(Palette.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        Text("共 \(danmaku.total) 条弹幕")
                            .font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        danmaku.rebuild(laneCount: danmaku.laneCount(for: 800))
                        showDanmakuSettings = false
                    }
                }
            }
            .onChange(of: danmaku.settings) { _ in
                danmaku.rebuild(laneCount: danmaku.laneCount(for: 800))
            }
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

            // 续播：优先用历史记录的集数
            let resumeEp = library.record(for: seriesID)?.lastEpisode ?? startIndex
            let target = eps.first(where: { $0.index == resumeEp })
                ?? eps.first(where: { $0.index == startIndex })
                ?? eps[0]
            await playEpisode(target)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func playEpisode(_ ep: HGServerEpisode) async {
        loading = true
        errorText = nil
        debugLines.removeAll()
        defer { loading = false }

        do {
            let url = try client.streamURL(vid: ep.vid)
            log("播放 第\(ep.index)集")

            await loadVariants(for: ep)

            removeObservers()
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
            p.rate = rate

            // 续播：同一集且有进度就跳过去
            if let rec = library.record(for: seriesID),
               rec.lastEpisode == ep.index,
               let pos = rec.position, pos > 3 {
                await p.seek(to: CMTime(seconds: pos, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
                progress = pos
                log("续播 \(Int(pos))s")
            }

            p.play()
            isPlaying = true
            installTimeObserver()
            installEndObserver()
            scheduleHideControls()

            // 记录历史
            if let d = detail {
                library.touchHistory(
                    HGFeedItem(seriesID: seriesID, itemID: nil,
                               title: d.title ?? seriesTitle, cover: d.cover,
                               intro: nil, tags: nil, episodeText: nil,
                               episodeCount: d.totalEpisodes, freeEpisodes: nil,
                               playCount: nil, followedCount: nil),
                    episode: ep.index
                )
            }

            // 弹幕
            danmaku.clear()
            Task { await loadDanmaku(for: ep) }
        } catch {
            errorText = error.localizedDescription
            log("ERR \(error.localizedDescription)")
        }
    }

    private func reloadDanmaku() async {
        guard let ep = current else { return }
        danmaku.clear()
        await loadDanmaku(for: ep)
    }

    private func loadDanmaku(for ep: HGServerEpisode) async {
        danmaku.setLoading(true)
        defer { danmaku.setLoading(false) }
        do {
            let page = try await client.danmaku(vid: ep.vid, seriesID: seriesID)
            let items = page.items ?? []
            danmaku.load(items)
            danmaku.rebuild(laneCount: danmaku.laneCount(for: 800))
            log("弹幕 \(items.count) 条")
        } catch {
            log("弹幕失败 \(error.localizedDescription)")
        }
    }

    private func loadVariants(for ep: HGServerEpisode) async {
        do {
            let p = try await client.play(vid: ep.vid)
            guard let url = try? client.streamURL(vid: ep.vid) else { return }
            let label = p.quality ?? "自动"
            let v = HGVariant(vid: ep.vid, label: label, url: url)
            variants = [v]
            currentVariant = v
        } catch {
            variants = []
        }
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
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        installEndObserver()
        if t.isFinite, t > 0 {
            await p.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying { p.play() }
        log("切清晰度 \(v.label)")
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
                    log("ready \(String(format: "%.1f", d))s")
                case .failed:
                    let ns = obj.error as NSError?
                    log("failed \(obj.error?.localizedDescription ?? "?") [\(ns?.code ?? 0)]")
                    errorText = "播放失败：\(obj.error?.localizedDescription ?? "未知")"
                case .unknown:
                    break
                @unknown default: break
                }
            }
        }
    }

    private func installTimeObserver() {
        guard let p = player, timeObserver == nil else { return }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { t in
            guard !isDraggingSeek else { return }
            let s = t.seconds
            if s.isFinite { progress = s }
            let d = p.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { duration = d }

            // 每约 5 秒存一次进度
            if let ep = current,
               Int(s) % 5 == 0, Int(s) != lastSavedSecond {
                lastSavedSecond = Int(s)
                library.saveProgress(seriesID: seriesID,
                                     episode: ep.index,
                                     position: s,
                                     duration: d)
            }
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

    private func removeObservers() {
        if let t = timeObserver, let p = player { p.removeTimeObserver(t) }
        timeObserver = nil
        statusObs?.invalidate(); statusObs = nil
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
        let target = min(max(t, 0), max(duration, 1))
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        progress = target
    }

    private func setRate(_ r: Float) {
        rate = r
        player?.rate = r
        if !isPlaying { player?.pause() }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHideControls() }
    }

    private func scheduleHideControls() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !showEpisodes && !showQuality && !showDanmakuSettings {
                    withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false }
                }
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
        hintTask?.cancel()
        removeObservers()
        player?.pause()
        player = nil
    }

    private func log(_ s: String) {
        debugLines.append(s)
        if debugLines.count > 30 { debugLines.removeFirst() }
    }

    private func fmt(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "00:00" }
        let s = Int(sec)
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
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
