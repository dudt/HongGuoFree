// 播放器界面（原生 App 观感）
//
// 参考红果/抖音短剧的布局：
//   - 全屏视频，控制层半透明浮层
//   - 顶部：返回 + 标题 + 集数，右侧清晰度/更多
//   - 右侧竖排：点赞/收藏/选集（短剧常见）
//   - 底部：进度条 + 时间 + 倍速 + 全屏
//   - 中央：播放/暂停大按钮 + 左右各 15 秒
//   - 手势：双击左右、横向拖动进度、纵向调亮度/音量
import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

// MARK: - 清晰度

struct HGVariant: Identifiable, Hashable {
    var vid: String
    var label: String
    var url: URL
    var id: String { vid + label }
}

// MARK: - 播放器

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
    @State private var bufferedEnd: Double = 0

    // 弹幕
    @StateObject private var danmaku = DanmakuEngine()

    // UI
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showEpisodes = false
    @State private var showQuality = false
    @State private var showDanmakuSettings = false
    @State private var showDebug = false
    @State private var showRateMenu = false

    // 手势
    @State private var dragAxis: DragAxis = .none
    @State private var dragStartTime: Double = 0
    @State private var isDraggingSeek = false
    @State private var hudText: String?
    @State private var hudTask: Task<Void, Never>?
    @State private var brightness: CGFloat = 0.5
    @State private var volume: CGFloat = 0.5
    @State private var hudKind: HudKind = .none

    private enum DragAxis { case none, horizontal, vertical }
    private enum HudKind { case none, seek, brightness, volume }

    // 观察器
    @State private var timeObserver: Any?
    @State private var statusObs: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?
    @State private var bufferObs: NSKeyValueObservation?

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoSurface(player: player).ignoresSafeArea()
                DanmakuLayerView(engine: danmaku, playerTime: progress,
                                 isPaused: !isPlaying)
                    .ignoresSafeArea()
            }

            gestureLayer

            if controlsVisible {
                controlsLayer.transition(.opacity)
            }

            // HUD
            if let hudText {
                hudOverlay(hudText)
            }

            if loading {
                ProgressView().tint(.white).scaleEffect(1.4)
            }

            if let errorText {
                errorOverlay(errorText)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task { await loadDetail() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showQuality) { qualitySheet }
        .sheet(isPresented: $showDanmakuSettings) { danmakuSettingsSheet }
        .onDisappear { teardown() }
    }

    // MARK: - 手势

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { loc in
                    if loc.x < geo.size.width / 2 {
                        skip(-10); showHud("« 10秒", .seek)
                    } else {
                        skip(10); showHud("10秒 »", .seek)
                    }
                }
                .onTapGesture { toggleControls() }
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { v in handleDrag(v, in: geo.size) }
                        .onEnded { v in endDrag(v, in: geo.size) }
                )
        }
    }

    private func handleDrag(_ v: DragGesture.Value, in size: CGSize) {
        if dragAxis == .none {
            dragAxis = abs(v.translation.width) > abs(v.translation.height)
                ? .horizontal : .vertical
            if dragAxis == .horizontal {
                dragStartTime = progress
                isDraggingSeek = true
            } else {
                brightness = UIScreen.main.brightness
                volume = CGFloat(AVAudioSession.sharedInstance().outputVolume)
            }
        }

        switch dragAxis {
        case .horizontal:
            let delta = Double(v.translation.width) / 10.0
            let t = min(max(dragStartTime + delta, 0), max(duration, 1))
            scrubValue = t
            showHud("\(fmt(t)) / \(fmt(duration))", .seek)

        case .vertical:
            let delta = -Double(v.translation.height) / Double(size.height)
            if v.startLocation.x < size.width / 2 {
                let b = min(max(Double(brightness) + delta, 0.02), 1.0)
                UIScreen.main.brightness = CGFloat(b)
                showHud("亮度 \(Int(b * 100))%", .brightness)
            } else {
                let target = min(max(Double(volume) + delta, 0.0), 1.0)
                setSystemVolume(Float(target))
                showHud("音量 \(Int(target * 100))%", .volume)
            }

        case .none:
            break
        }
    }

    private func endDrag(_ v: DragGesture.Value, in size: CGSize) {
        if dragAxis == .horizontal, isDraggingSeek {
            player?.seek(to: CMTime(seconds: scrubValue, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
            progress = scrubValue
            isDraggingSeek = false
        }
        dragAxis = .none
        hideHudSoon()
    }

    private func setSystemVolume(_ v: Float) {
        let mpv = MPVolumeView()
        for sub in mpv.subviews where sub is UISlider {
            (sub as? UISlider)?.value = v
            break
        }
    }

    private func showHud(_ s: String, _ kind: HudKind) {
        hudTask?.cancel()
        hudText = s
        hudKind = kind
        if kind == .seek { hideHudSoon() }
    }

    private func hideHudSoon() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { hudText = nil; hudKind = .none }
        }
    }

    private func hudOverlay(_ text: String) -> some View {
        Group {
            switch hudKind {
            case .brightness, .volume:
                VStack(spacing: 8) {
                    Image(systemName: hudKind == .brightness ? "sun.max.fill" : "speaker.wave.3.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                    Text(text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
                .background(.black.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            default:
                Text(text)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    // MARK: - 控制层

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerRow
            Spacer(minLength: 0)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { teardown(); dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(seriesTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let c = current {
                    Text("第 \(c.index) 集")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Spacer()

            // 清晰度
            if let v = currentVariant {
                Button { showQuality = true } label: {
                    Text(v.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.45))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // 弹幕开关
            Button { danmaku.settings.enabled.toggle() } label: {
                Image(systemName: danmaku.settings.enabled
                      ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(danmaku.settings.enabled
                                     ? .white : .white.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // 更多
            Menu {
                Button { showDanmakuSettings = true } label: {
                    Label("弹幕设置", systemImage: "slider.horizontal.3")
                }
                Button { showEpisodes = true } label: {
                    Label("选集", systemImage: "list.bullet")
                }
                Divider()
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button {
                        setRate(r)
                    } label: {
                        Label(r == 1.0 ? "正常速度" : "\(r)x",
                              systemImage: abs(rate - r) < 0.01
                                ? "checkmark" : "speedometer")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.4))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 26)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var centerRow: some View {
        HStack(spacing: 52) {
            Button { skip(-15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(.black.opacity(0.35))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Button { skip(15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // 进度条
            HStack(spacing: 10) {
                Text(fmt(isDraggingSeek ? scrubValue : progress))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)

                // 自定义进度条（带缓冲）
                GeometryReader { g in
                    let w = g.size.width
                    let total = max(duration, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                        Capsule()
                            .fill(.white.opacity(0.4))
                            .frame(width: w * CGFloat(min(bufferedEnd / total, 1)),
                                   height: 3)
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: w * CGFloat(min((isDraggingSeek ? scrubValue : progress) / total, 1)),
                                   height: 3)
                        Circle()
                            .fill(.white)
                            .frame(width: isDraggingSeek ? 14 : 10,
                                   height: isDraggingSeek ? 14 : 10)
                            .offset(x: w * CGFloat(min((isDraggingSeek ? scrubValue : progress) / total, 1)) - (isDraggingSeek ? 7 : 5))
                    }
                    .frame(height: 20)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                isDraggingSeek = true
                                let ratio = min(max(v.location.x / w, 0), 1)
                                scrubValue = Double(ratio) * total
                            }
                            .onEnded { _ in
                                player?.seek(to: CMTime(seconds: scrubValue,
                                                        preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
                                progress = scrubValue
                                isDraggingSeek = false
                                scheduleHideControls()
                            }
                    )
                }
                .frame(height: 20)

                Text(fmt(duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }

            // 底部操作行
            HStack(spacing: 16) {
                Button { setRate(rate >= 2.0 ? 1.0 : rate + 0.25) } label: {
                    Text(rate == 1.0 ? "倍速" : String(format: "%.2gx", rate))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.16))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button { showEpisodes = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet").font(.system(size: 11))
                        Text("选集").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if danmaku.total > 0 {
                    Text("弹幕 \(danmaku.total)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                Button {
                    library.toggleFavorite(
                        HGFeedItem(seriesID: seriesID, itemID: nil,
                                   title: detail?.title ?? seriesTitle,
                                   cover: detail?.cover, intro: nil, tags: nil,
                                   episodeText: nil, episodeCount: detail?.totalEpisodes,
                                   freeEpisodes: nil, playCount: nil, followedCount: nil)
                    )
                } label: {
                    Image(systemName: library.isFavorite(seriesID)
                          ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(library.isFavorite(seriesID)
                                         ? Palette.accent : .white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 22)
        .padding(.top, 30)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 错误

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

    // MARK: - 弹层

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
                    VStack(alignment: .leading, spacing: 20) {
                        slider("显示区域", value: $danmaku.settings.areaRatio,
                               range: 0.15...1.0, fmt: "\(Int(danmaku.settings.areaRatio * 100))%",
                               hint: "弹幕占屏幕的高度比例")
                        slider("顶部留白", value: $danmaku.settings.topInset,
                               range: 0...220, fmt: "\(Int(danmaku.settings.topInset))pt",
                               hint: "避开顶部按钮")
                        slider("字号", value: $danmaku.settings.fontSize,
                               range: 11...30, fmt: "\(Int(danmaku.settings.fontSize))",
                               hint: nil)
                        slider("滚动时长", value: $danmaku.settings.duration,
                               range: 3...14, fmt: String(format: "%.1fs", danmaku.settings.duration),
                               hint: "越小滚得越快")
                        slider("不透明度", value: $danmaku.settings.opacity,
                               range: 0.2...1.0, fmt: "\(Int(danmaku.settings.opacity * 100))%",
                               hint: nil)

                        Toggle("文字描边", isOn: $danmaku.settings.stroke)
                            .font(.system(size: 14)).tint(Palette.accent)

                        Button { Task { await reloadDanmaku() } } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text(danmaku.loading ? "拉取中…" : "重新拉取弹幕")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Palette.surface)
                            .foregroundStyle(Palette.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        Text("共 \(danmaku.total) 条")
                            .font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showDanmakuSettings = false }
                }
            }
            .onChange(of: danmaku.settings) { _ in
                danmaku.rebuild(laneCount: 10)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, fmt: String,
                        hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(fmt).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
            }
            Slider(value: value, in: range).tint(Palette.accent)
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    // MARK: - 加载

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
            bufferedEnd = 0
            p.rate = rate

            if let rec = library.record(for: seriesID),
               rec.lastEpisode == ep.index,
               let pos = rec.position, pos > 3 {
                await p.seek(to: CMTime(seconds: pos, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
                progress = pos
            }

            p.play()
            isPlaying = true
            installTimeObserver()
            installEndObserver()
            scheduleHideControls()

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

            danmaku.clear()
            Task { await loadDanmaku(for: ep) }
        } catch {
            errorText = error.localizedDescription
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
            danmaku.rebuild(laneCount: 10)
        } catch {
            debugLines.append("弹幕失败 \(error.localizedDescription)")
        }
    }

    private func loadVariants(for ep: HGServerEpisode) async {
        do {
            let p = try await client.play(vid: ep.vid)
            guard let url = try? client.streamURL(vid: ep.vid) else { return }
            let v = HGVariant(vid: ep.vid, label: p.quality ?? "自动", url: url)
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
    }

    // MARK: - 观察

    private func observe(item: AVPlayerItem) {
        statusObs?.invalidate()
        statusObs = item.observe(\.status, options: [.initial, .new]) { obj, _ in
            Task { @MainActor in
                switch obj.status {
                case .readyToPlay:
                    let d = obj.duration.seconds
                    if d.isFinite, d > 0 { duration = d }
                case .failed:
                    errorText = "播放失败：\(obj.error?.localizedDescription ?? "未知")"
                default: break
                }
            }
        }
        bufferObs?.invalidate()
        bufferObs = item.observe(\.loadedTimeRanges, options: [.new]) { obj, _ in
            Task { @MainActor in
                if let r = obj.loadedTimeRanges.last?.timeRangeValue {
                    bufferedEnd = (r.start + r.duration).seconds
                }
            }
        }
    }

    private func installTimeObserver() {
        guard let p = player, timeObserver == nil else { return }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { t in
            guard !isDraggingSeek else { return }
            let s = t.seconds
            if s.isFinite { progress = s }
            let d = p.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { duration = d }

            if let ep = current, Int(s) % 5 == 0, Int(s) != lastSavedSecond {
                lastSavedSecond = Int(s)
                library.saveProgress(seriesID: seriesID, episode: ep.index,
                                     position: s, duration: d)
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
        bufferObs?.invalidate(); bufferObs = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
    }

    // MARK: - 控制

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause() } else { p.play() }
        isPlaying.toggle()
        scheduleHideControls()
    }

    private func skip(_ seconds: Double) {
        guard let p = player else { return }
        let target = min(max(p.currentTime().seconds + seconds, 0), max(duration, 1))
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        progress = target
    }

    private func setRate(_ r: Float) {
        rate = r
        player?.rate = r
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
        hudTask?.cancel()
        removeObservers()
        player?.pause()
        player = nil
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
