// 播放器（自定义 UI，单一手势层）
//
// 上一版点击失效的根因：多个手势识别器叠在一起互相抢占
//   （onTapGesture + onLongPressGesture + DragGesture + UIKit 桥接）。
//
// 本版原则：整个播放区只有一个 DragGesture(minimumDistance: 0)。
// 所有交互都由它在 onChanged/onEnded 里按「位移 + 时长」判定：
//   位移 < 8pt 且时长 < 0.25s   → 单击（切换控制层）
//   位移 < 8pt 且时长 < 0.28s 的第二次 → 双击（左退/右进 10s）
//   位移 < 12pt 且时长 ≥ 0.3s   → 长按（2 倍速，松手恢复）
//   横向位移 > 14pt             → 拖动进度
//   纵向位移 > 14pt             → 左侧亮度 / 右侧音量
// 因为只有一个识别器，不存在抢占。
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

    // 播放
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var bufferedEnd: Double = 0
    @State private var rate: Float = 1.0
    @State private var lastSavedSecond = -1

    // 弹幕
    @StateObject private var danmaku = DanmakuEngine()

    // UI
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showEpisodes = false
    @State private var showQuality = false
    @State private var showDanmakuSettings = false

    // 手势状态（全部由单一 DragGesture 驱动）
    @State private var touchStart: Date = .distantPast
    @State private var touchStartPoint: CGPoint = .zero
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapX: CGFloat = 0
    @State private var mode: TouchMode = .undecided
    @State private var dragStartProgress: Double = 0
    @State private var scrubTarget: Double = 0
    @State private var brightnessBase: CGFloat = 0.5
    @State private var volumeBase: CGFloat = 0.5
    @State private var longPressFired = false
    @State private var rateBeforeBoost: Float = 1.0

    // HUD
    @State private var hudText: String?
    @State private var hudIcon: String?
    @State private var hudTask: Task<Void, Never>?

    private enum TouchMode {
        case undecided
        case seeking        // 横向拖动
        case brightness     // 纵向左侧
        case volume         // 纵向右侧
        case longPressing   // 长按中
        case ignored        // 已判定为无效（比如拖动后）
    }

    // 观察器
    @State private var timeObserver: Any?
    @State private var statusObs: NSKeyValueObservation?
    @State private var bufferObs: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 视频 + 弹幕
            PlayerSurface(player: player).ignoresSafeArea()
            DanmakuCanvas(engine: danmaku, player: player)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // 唯一手势层
            touchLayer

            // 控制层（自身可点，不吃手势层的触摸）
            if controlsVisible {
                controlsLayer
                    .transition(.opacity)
            }

            // HUD
            if let hudText {
                hudView(hudText)
                    .allowsHitTesting(false)
            }

            if loading {
                ProgressView().tint(.white).scaleEffect(1.4)
                    .allowsHitTesting(false)
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

    // MARK: - 单一手势层

    private var touchLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in onTouchChanged(v, in: geo.size) }
                        .onEnded { v in onTouchEnded(v, in: geo.size) }
                )
        }
    }

    private func onTouchChanged(_ v: DragGesture.Value, in size: CGSize) {
        if mode == .undecided {
            let dx = v.translation.width
            let dy = v.translation.height
            let dist = max(abs(dx), abs(dy))

            if dist > 14 {
                // 判定方向
                if abs(dx) > abs(dy) {
                    mode = .seeking
                    dragStartProgress = progress
                    scrubTarget = progress
                    showHud(fmt(progress), icon: "arrow.left.and.right")
                } else {
                    if v.startLocation.x < size.width / 2 {
                        mode = .brightness
                        brightnessBase = UIScreen.main.brightness
                    } else {
                        mode = .volume
                        volumeBase = CGFloat(AVAudioSession.sharedInstance().outputVolume)
                    }
                }
            }
            return
        }

        switch mode {
        case .seeking:
            // 每 10pt = 1 秒
            let delta = Double(v.translation.width) / 10.0
            let t = min(max(dragStartProgress + delta, 0), max(duration, 1))
            scrubTarget = t
            progress = t
            showHud("\(fmt(t)) / \(fmt(duration))", icon: "arrow.left.and.right")

        case .brightness:
            let delta = -Double(v.translation.height) / Double(size.height)
            let b = min(max(Double(brightnessBase) + delta, 0.02), 1.0)
            UIScreen.main.brightness = CGFloat(b)
            showHud("\(Int(b * 100))%", icon: "sun.max.fill")

        case .volume:
            let delta = -Double(v.translation.height) / Double(size.height)
            let target = min(max(Double(volumeBase) + delta, 0.0), 1.0)
            setSystemVolume(Float(target))
            showHud("\(Int(target * 100))%", icon: "speaker.wave.3.fill")

        case .undecided:
            // 位移还很小，检查是否该触发长按
            if Date().timeIntervalSince(touchStart) >= 0.32, !longPressFired {
                longPressFired = true
                mode = .longPressing
                rateBeforeBoost = rate
                player.rate = 2.0
                showHud("2x 倍速", icon: "forward.fill", sticky: true)
            }

        case .longPressing, .ignored:
            break
        }
    }

    private func onTouchEnded(_ v: DragGesture.Value, in size: CGSize) {
        let dist = max(abs(v.translation.width), abs(v.translation.height))
        let elapsed = Date().timeIntervalSince(touchStart)

        switch mode {
        case .seeking:
            player.seek(to: CMTime(seconds: scrubTarget, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            progress = scrubTarget
            hideHudSoon()

        case .brightness, .volume:
            hideHudSoon()

        case .longPressing:
            player.rate = rateBeforeBoost
            hideHudSoon(immediately: false)

        case .ignored:
            break

        case .undecided:
            // 没有明显位移 → 点击类
            if dist < 12, elapsed < 0.32 {
                let now = Date()
                let isDouble = now.timeIntervalSince(lastTapTime) < 0.30
                if isDouble, abs(v.startLocation.x - lastTapX) < 60 {
                    // 双击
                    lastTapTime = .distantPast
                    if v.startLocation.x < size.width / 2 {
                        skip(-10)
                        showHud("« 10秒", icon: "gobackward.10")
                    } else {
                        skip(10)
                        showHud("10秒 »", icon: "goforward.10")
                    }
                } else {
                    // 单击
                    lastTapTime = now
                    lastTapX = v.startLocation.x
                    toggleControls()
                }
            }
        }

        // 复位
        mode = .undecided
        longPressFired = false
    }

    private func setSystemVolume(_ v: Float) {
        let mpv = MPVolumeView()
        mpv.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        for sub in mpv.subviews where sub is UISlider {
            (sub as? UISlider)?.value = v
            break
        }
    }

    // MARK: - HUD

    private func showHud(_ text: String, icon: String?, sticky: Bool = false) {
        hudTask?.cancel()
        hudText = text
        hudIcon = icon
        if !sticky { hideHudSoon() }
    }

    private func hideHudSoon(immediately: Bool = true) {
        hudTask?.cancel()
        let delay: UInt64 = immediately ? 550_000_000 : 250_000_000
        hudTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run { hudText = nil; hudIcon = nil }
        }
    }

    private func hudView(_ text: String) -> some View {
        VStack(spacing: 6) {
            if let hudIcon {
                Image(systemName: hudIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
            }
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.42))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(seriesTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let c = current {
                    Text("第 \(c.index) 集 / 共 \(detail?.totalEpisodes ?? 0) 集")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer()

            if let v = currentVariant {
                Button { showQuality = true } label: {
                    Text(v.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.42))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button { danmaku.settings.enabled.toggle() } label: {
                Image(systemName: danmaku.settings.enabled
                      ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(danmaku.settings.enabled ? .white : .white.opacity(0.45))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.42))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Menu {
                Button { showDanmakuSettings = true } label: {
                    Label("弹幕设置", systemImage: "slider.horizontal.3")
                }
                Button { showEpisodes = true } label: {
                    Label("选集", systemImage: "list.bullet")
                }
                Divider()
                ForEach([Float(0.75), 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button { setRate(r) } label: {
                        Label(r == 1.0 ? "正常速度" : "\(r)x",
                              systemImage: abs(rate - r) < 0.01
                                ? "checkmark" : "speedometer")
                    }
                }
                Divider()
                Button {
                    library.toggleFavorite(
                        HGFeedItem(seriesID: seriesID, itemID: nil,
                                   title: detail?.title ?? seriesTitle,
                                   cover: detail?.cover, intro: nil, tags: nil,
                                   episodeText: nil, episodeCount: detail?.totalEpisodes,
                                   freeEpisodes: nil, playCount: nil, followedCount: nil)
                    )
                } label: {
                    Label(library.isFavorite(seriesID) ? "取消收藏" : "收藏",
                          systemImage: library.isFavorite(seriesID)
                            ? "bookmark.slash" : "bookmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.42))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [.black.opacity(0.72), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var centerRow: some View {
        HStack(spacing: 48) {
            Button { skip(-15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(.black.opacity(0.32))
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
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(fmt(progress))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 46, alignment: .leading)

                GeometryReader { g in
                    let w = g.size.width
                    let total = max(duration, 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22)).frame(height: 3)
                        Capsule().fill(.white.opacity(0.38))
                            .frame(width: w * CGFloat(min(bufferedEnd / total, 1)), height: 3)
                        Capsule().fill(Palette.accent)
                            .frame(width: w * CGFloat(min(progress / total, 1)), height: 3)
                        Circle().fill(.white).frame(width: 10, height: 10)
                            .offset(x: w * CGFloat(min(progress / total, 1)) - 5)
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                }
                .frame(height: 18)

                Text(fmt(duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Button { setRate(rate >= 2.0 ? 1.0 : rate + 0.25) } label: {
                    Text(rate == 1.0 ? "倍速" : String(format: "%.2gx", rate))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.white.opacity(0.16))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button { showEpisodes = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet").font(.system(size: 10))
                        Text("选集").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .padding(.top, 30)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.78)],
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
            Button("重试") { Task { await loadDetail() } }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Palette.accent).foregroundStyle(.white)
                .clipShape(Capsule()).buttonStyle(.plain)
        }
        .padding(20)
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                        dSlider("显示区域", $danmaku.settings.areaRatio, 0.15...1.0,
                                "\(Int(danmaku.settings.areaRatio * 100))%", "弹幕占屏幕高度比例")
                        dSlider("顶部留白", $danmaku.settings.topInset, 0...220,
                                "\(Int(danmaku.settings.topInset))pt", "避开顶部按钮")
                        dSlider("字号", $danmaku.settings.fontSize, 11...30,
                                "\(Int(danmaku.settings.fontSize))", nil)
                        dSlider("滚动时长", $danmaku.settings.duration, 3...14,
                                String(format: "%.1fs", danmaku.settings.duration), "越小越快")
                        dSlider("不透明度", $danmaku.settings.opacity, 0.2...1.0,
                                "\(Int(danmaku.settings.opacity * 100))%", nil)
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

    private func dSlider(_ title: String, _ value: Binding<Double>,
                         _ range: ClosedRange<Double>, _ label: String,
                         _ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(label).font(.system(size: 12, design: .monospaced))
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
        defer { loading = false }

        do {
            let url = try client.streamURL(vid: ep.vid)
            await loadVariants(for: ep)

            removeObservers()
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 8
            observe(item: item)
            player.replaceCurrentItem(with: item)
            player.automaticallyWaitsToMinimizeStalling = true
            current = ep
            duration = 0
            progress = 0
            bufferedEnd = 0
            lastSavedSecond = -1
            player.rate = rate

            if let rec = library.record(for: seriesID),
               rec.lastEpisode == ep.index,
               let pos = rec.position, pos > 3 {
                await player.seek(to: CMTime(seconds: pos, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                progress = pos
            }

            player.play()
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
            danmaku.load(page.items ?? [])
            danmaku.rebuild(laneCount: 10)
        } catch {
            // 静默
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
        let t = player.currentTime().seconds
        let wasPlaying = isPlaying
        let item = AVPlayerItem(url: v.url)
        item.preferredForwardBufferDuration = 8
        observe(item: item)
        player.replaceCurrentItem(with: item)
        currentVariant = v
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        installEndObserver()
        if t.isFinite, t > 0 {
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if wasPlaying { player.play() }
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
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { t in
            let s = t.seconds
            if s.isFinite, mode != .seeking { progress = s }
            let d = player.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { duration = d }

            if let ep = current, Int(s) % 5 == 0, Int(s) != lastSavedSecond {
                lastSavedSecond = Int(s)
                library.saveProgress(seriesID: seriesID, episode: ep.index,
                                     position: s, duration: d)
            }
        }
    }

    private func installEndObserver() {
        guard let item = player.currentItem, endObserver == nil else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            Task { await playNext() }
        }
    }

    private func removeObservers() {
        if let t = timeObserver { player.removeTimeObserver(t) }
        timeObserver = nil
        statusObs?.invalidate(); statusObs = nil
        bufferObs?.invalidate(); bufferObs = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
    }

    // MARK: - 控制

    private func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        scheduleHideControls()
    }

    private func skip(_ seconds: Double) {
        let target = min(max(player.currentTime().seconds + seconds, 0), max(duration, 1))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        progress = target
    }

    private func setRate(_ r: Float) {
        rate = r
        if mode != .longPressing { player.rate = r }
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
        player.pause()
    }

    private func fmt(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "00:00" }
        let s = Int(sec)
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }
}

// MARK: - 视频层

private struct PlayerSurface: UIViewRepresentable {
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
