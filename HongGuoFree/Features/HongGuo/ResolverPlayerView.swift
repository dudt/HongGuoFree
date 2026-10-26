// 播放器（稳定版）
//
// 三个症状的根因与修法：
//
// 1. 没声音
//    从未调用 AVAudioSession.setCategory(.playback)。
//    iOS 默认 .ambient，会被静音拨片静音、也不支持后台。
//    → PlaybackAudioSession.activate() 在播放前调用。
//
// 2. 黑屏
//    AVPlayerLayer 挂在 SwiftUI 的 UIViewRepresentable 里，
//    在 fullScreenCover + ignoresSafeArea 组合下偶尔拿不到正确 bounds。
//    → 改用 UIViewControllerRepresentable，在 viewDidLayoutSubviews
//      里显式同步 playerLayer.frame，并监听 readyToPlay 再 play()。
//
// 3. 点不动
//    多个手势识别器叠加互相抢占。
//    → 单一 DragGesture + 显式状态机；控制层用 overlay 且自身可点。
import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

// MARK: - 音频会话

enum PlaybackAudioSession {
    private static var activated = false

    /// 必须在播放前调用，否则静音拨片会静音、也无法后台播放
    static func activate() {
        guard !activated else { return }
        activated = true
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .moviePlayback,
                              options: [.allowAirPlay, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch {
            // 失败不阻断播放
        }
    }

    static func deactivate() {
        guard activated else { return }
        activated = false
        try? AVAudioSession.sharedInstance().setActive(false,
            options: [.notifyOthersOnDeactivation])
    }
}

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
    @State private var controller = PlayerController()
    @State private var progress: Double = 0
    @State private var duration: Double = 0
    @State private var bufferedEnd: Double = 0
    @State private var isPlaying = false
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

    // 手势状态机
    @State private var touchStart: Date = .distantPast
    @State private var lastTap: Date = .distantPast
    @State private var lastTapX: CGFloat = 0
    @State private var gestureMode: GMode = .idle
    @State private var seekBase: Double = 0
    @State private var seekTarget: Double = 0
    @State private var brightBase: CGFloat = 0.5
    @State private var volBase: CGFloat = 0.5
    @State private var boosted = false
    @State private var rateBeforeBoost: Float = 1.0
    @State private var longPressTask: Task<Void, Never>?

    // HUD
    @State private var hud: (text: String, icon: String?)?
    @State private var hudTask: Task<Void, Never>?

    private enum GMode { case idle, seeking, brightness, volume, boosting, done }

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 视频层
            VideoLayer(player: controller.player)
                .ignoresSafeArea()

            // 弹幕层
            DanmakuCanvas(engine: danmaku, player: controller.player)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // 手势层（唯一识别器）
            gestureLayer

            // 控制层
            if controlsVisible {
                controlsLayer.transition(.opacity)
            }

            if let hud {
                hudView(hud.text, icon: hud.icon).allowsHitTesting(false)
            }

            if loading {
                ProgressView().tint(.white).scaleEffect(1.4).allowsHitTesting(false)
            }

            if let errorText {
                errorOverlay(errorText)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { PlaybackAudioSession.activate() }
        .task { await loadDetail() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showQuality) { qualitySheet }
        .sheet(isPresented: $showDanmakuSettings) { danmakuSettingsSheet }
        .onDisappear {
            teardown()
            PlaybackAudioSession.deactivate()
        }
    }

    // MARK: - 手势（单一识别器）

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in handleTouch(v, in: geo.size) }
                        .onEnded { v in endTouch(v, in: geo.size) }
                )
        }
    }

    private func handleTouch(_ v: DragGesture.Value, in size: CGSize) {
        let dx = v.translation.width
        let dy = v.translation.height
        let dist = max(abs(dx), abs(dy))

        // 第一次回调：记录起点时间，启动长按计时
        if gestureMode == .idle, touchStart == .distantPast {
            touchStart = Date()
            startLongPressTimer()
        }

        if gestureMode == .idle {
            if dist > 14 {
                // 有明显位移 → 取消长按，判定方向
                cancelLongPressTimer()
                if abs(dx) > abs(dy) {
                    gestureMode = .seeking
                    seekBase = progress
                    seekTarget = progress
                    showHud(fmt(progress), icon: "arrow.left.and.right")
                } else if v.startLocation.x < size.width / 2 {
                    gestureMode = .brightness
                    brightBase = UIScreen.main.brightness
                } else {
                    gestureMode = .volume
                    volBase = CGFloat(AVAudioSession.sharedInstance().outputVolume)
                }
            }
            return
        }

        switch gestureMode {
        case .seeking:
            let delta = Double(dx) / 10.0
            let t = min(max(seekBase + delta, 0), max(duration, 1))
            seekTarget = t
            progress = t
            showHud("\(fmt(t)) / \(fmt(duration))", icon: "arrow.left.and.right")

        case .brightness:
            let delta = -Double(dy) / Double(size.height)
            let b = min(max(Double(brightBase) + delta, 0.02), 1.0)
            UIScreen.main.brightness = CGFloat(b)
            showHud("\(Int(b * 100))%", icon: "sun.max.fill")

        case .volume:
            let delta = -Double(dy) / Double(size.height)
            let t = min(max(Double(volBase) + delta, 0), 1)
            setSystemVolume(Float(t))
            showHud("\(Int(t * 100))%", icon: "speaker.wave.3.fill")

        default:
            break
        }
    }

    /// 长按计时器：0.5 秒内没有明显位移且没松手 → 进入 2 倍速
    private func startLongPressTimer() {
        longPressTask?.cancel()
        longPressTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 只有还在 idle（没位移、没松手）才触发
                guard gestureMode == .idle, !boosted else { return }
                boosted = true
                gestureMode = .boosting
                rateBeforeBoost = rate
                controller.setRate(2.0)
                showHud("2x 倍速", icon: "forward.fill", sticky: true)
            }
        }
    }

    private func cancelLongPressTimer() {
        longPressTask?.cancel()
        longPressTask = nil
    }

    private func endTouch(_ v: DragGesture.Value, in size: CGSize) {
        let dist = max(abs(v.translation.width), abs(v.translation.height))
        let elapsed = touchStart == .distantPast ? 0 : Date().timeIntervalSince(touchStart)
        cancelLongPressTimer()

        switch gestureMode {
        case .seeking:
            controller.seek(to: seekTarget)
            progress = seekTarget
            hideHudSoon()

        case .brightness, .volume:
            hideHudSoon()

        case .boosting:
            controller.setRate(rateBeforeBoost)
            hideHudSoon()

        case .idle:
            // 没有位移、没有长按 → 点击类
            if dist < 12, elapsed < 0.5, !boosted {
                let now = Date()
                if now.timeIntervalSince(lastTap) < 0.32,
                   abs(v.startLocation.x - lastTapX) < 80 {
                    // 双击
                    lastTap = .distantPast
                    if v.startLocation.x < size.width / 2 {
                        skip(-10); showHud("« 10秒", icon: "gobackward.10")
                    } else {
                        skip(10); showHud("10秒 »", icon: "goforward.10")
                    }
                } else {
                    // 单击
                    lastTap = now
                    lastTapX = v.startLocation.x
                    toggleControls()
                }
            }

        default:
            break
        }

        gestureMode = .idle
        boosted = false
        touchStart = .distantPast
    }

    private func setSystemVolume(_ v: Float) {
        let mpv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        for sub in mpv.subviews where sub is UISlider {
            (sub as? UISlider)?.value = v
            break
        }
    }

    // MARK: - HUD

    private func showHud(_ text: String, icon: String?, sticky: Bool = false) {
        hudTask?.cancel()
        hud = (text, icon)
        if !sticky { hideHudSoon() }
    }

    private func hideHudSoon() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { hud = nil }
        }
    }

    private func hudView(_ text: String, icon: String?) -> some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white)
            }
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
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
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(seriesTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                if let c = current {
                    Text("第 \(c.index) 集 / 共 \(detail?.totalEpisodes ?? 0) 集")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer()

            if let v = currentVariant {
                Button { showQuality = true } label: {
                    Text(v.label)
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.45)).clipShape(Capsule())
                }.buttonStyle(.plain)
            }

            Button { danmaku.settings.enabled.toggle() } label: {
                Image(systemName: danmaku.settings.enabled ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(danmaku.settings.enabled ? .white : .white.opacity(0.45))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45)).clipShape(Circle())
            }.buttonStyle(.plain)

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
                              systemImage: abs(rate - r) < 0.01 ? "checkmark" : "speedometer")
                    }
                }
                Divider()
                Button {
                    library.toggleFavorite(
                        HGFeedItem(seriesID: seriesID, itemID: nil,
                                   title: detail?.title ?? seriesTitle,
                                   cover: detail?.cover, intro: nil, tags: nil,
                                   episodeText: nil, episodeCount: detail?.totalEpisodes,
                                   freeEpisodes: nil, playCount: nil, followedCount: nil))
                } label: {
                    Label(library.isFavorite(seriesID) ? "取消收藏" : "收藏",
                          systemImage: library.isFavorite(seriesID) ? "bookmark.slash" : "bookmark")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45)).clipShape(Circle())
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 28)
        .background(LinearGradient(colors: [.black.opacity(0.72), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var centerRow: some View {
        HStack(spacing: 50) {
            Button { skip(-15) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            }.buttonStyle(.plain)

            Button { togglePlay() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32)).foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(.black.opacity(0.32)).clipShape(Circle())
            }.buttonStyle(.plain)

            Button { skip(15) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.white)
            }.buttonStyle(.plain)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text(fmt(progress))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white).frame(width: 46, alignment: .leading)

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
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let ratio = min(max(v.location.x / w, 0), 1)
                                progress = Double(ratio) * total
                            }
                            .onEnded { _ in
                                controller.seek(to: progress)
                                scheduleHideControls()
                            }
                    )
                }
                .frame(height: 18)

                Text(fmt(duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7)).frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Button { setRate(rate >= 2.0 ? 1.0 : rate + 0.25) } label: {
                    Text(rate == 1.0 ? "倍速" : String(format: "%.2gx", rate))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.white.opacity(0.16)).clipShape(Capsule())
                }.buttonStyle(.plain)

                Button { showEpisodes = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet").font(.system(size: 10))
                        Text("选集").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.white.opacity(0.16)).clipShape(Capsule())
                }.buttonStyle(.plain)

                if danmaku.total > 0 {
                    Text("弹幕 \(danmaku.total)")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 20).padding(.top, 30)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.78)],
                                   startPoint: .top, endPoint: .bottom))
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
        .padding(20).background(.black.opacity(0.75))
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
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(current?.vid == ep.vid ? Palette.accent : Palette.surface)
                                    .foregroundStyle(current?.vid == ep.vid ? .white : Palette.textPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
            .navigationTitle("选集").navigationBarTitleDisplayMode(.inline)
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
                                        Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                    }
                                }
                                .foregroundStyle(Palette.textPrimary)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(Palette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }.padding(16)
                }
            }
            .navigationTitle("清晰度").navigationBarTitleDisplayMode(.inline)
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
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Palette.surface).foregroundStyle(Palette.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                        Text("共 \(danmaku.total) 条")
                            .font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
                    }.padding(16)
                }
            }
            .navigationTitle("弹幕设置").navigationBarTitleDisplayMode(.inline)
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
                ?? eps.first(where: { $0.index == startIndex }) ?? eps[0]
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
            await loadVariants(for: ep)

            current = ep
            duration = 0
            progress = 0
            bufferedEnd = 0
            lastSavedSecond = -1

            PlaybackAudioSession.activate()
            controller.onTime = { t, d in
                if gestureMode != .seeking { progress = t }
                if d > 0 { duration = d }
                if let e = current, Int(t) % 5 == 0, Int(t) != lastSavedSecond {
                    lastSavedSecond = Int(t)
                    library.saveProgress(seriesID: seriesID, episode: e.index,
                                         position: t, duration: d)
                }
            }
            controller.onBuffer = { bufferedEnd = $0 }
            controller.onEnd = { Task { await playNext() } }
            controller.onFail = { errorText = $0 }
            controller.onState = { playing in
                isPlaying = playing
            }

            var resume: Double = 0
            if let rec = library.record(for: seriesID),
               rec.lastEpisode == ep.index,
               let pos = rec.position, pos > 3 {
                resume = pos
            }

            if settings.directMode {
                // 直连：只取密钥，视频走 CDN
                if let bundle = try? await client.keys(vid: ep.vid) {
                    await controller.loadDirect(bundle: bundle, startAt: resume, rate: rate)
                } else {
                    // 回退到转发
                    let url = try client.streamURL(vid: ep.vid)
                    controller.load(url: url, startAt: resume, rate: rate)
                }
            } else {
                let url = try client.streamURL(vid: ep.vid)
                controller.load(url: url, startAt: resume, rate: rate)
            }

            if let d = detail {
                library.touchHistory(
                    HGFeedItem(seriesID: seriesID, itemID: nil,
                               title: d.title ?? seriesTitle, cover: d.cover,
                               intro: nil, tags: nil, episodeText: nil,
                               episodeCount: d.totalEpisodes, freeEpisodes: nil,
                               playCount: nil, followedCount: nil),
                    episode: ep.index)
            }

            danmaku.clear()
            Task { await loadDanmaku(for: ep) }
            scheduleHideControls()
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
        } catch {}
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
        let t = progress
        let wasPlaying = isPlaying
        currentVariant = v
        controller.load(url: v.url, startAt: t, rate: rate)
        if !wasPlaying { controller.pause() }
    }

    // MARK: - 控制

    private func togglePlay() {
        controller.togglePlay()
        isPlaying = controller.isPlaying
        scheduleHideControls()
    }

    private func skip(_ s: Double) {
        let t = min(max(progress + s, 0), max(duration, 1))
        controller.seek(to: t)
        progress = t
    }

    private func setRate(_ r: Float) {
        rate = r
        if gestureMode != .boosting { controller.setRate(r) }
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
        guard let d = detail, let c = current, let eps = d.episodes,
              let i = eps.firstIndex(where: { $0.vid == c.vid }),
              i + 1 < eps.count else { return }
        await playEpisode(eps[i + 1])
    }

    private func teardown() {
        hideTask?.cancel()
        hudTask?.cancel()
        cancelLongPressTimer()
        controller.teardown()
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00" }
        let i = Int(s), h = i / 3600, m = (i % 3600) / 60, ss = i % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }
}

// MARK: - 播放控制器（AVPlayer 封装）

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    var onTime: ((Double, Double) -> Void)?
    var onBuffer: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onFail: ((String) -> Void)?
    var onState: ((Bool) -> Void)?

    private(set) var isPlaying = false
    private var timeObs: Any?
    private var statusObs: NSKeyValueObservation?
    private var bufferObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var pendingSeek: Double = 0

    init() {
        player.actionAtItemEnd = .pause
        installTimeObserver()
    }

    private func installTimeObserver() {
        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            guard s.isFinite else { return }
            let d = self.player.currentItem?.duration.seconds ?? 0
            self.onTime?(s, d.isFinite ? d : 0)
        }
    }

    /// 直连模式：本地起 HTTP 服务，AVPlayer 走标准 http://127.0.0.1
    private var localServer: LocalStreamServer?

    func loadDirect(bundle: HGKeyBundle, startAt: Double = 0,
                    rate: Float = 1.0) async {
        guard let decryptor = CENCDecryptor(bundle: bundle),
              let cdn = bundle.cdnURL, let cdnURL = URL(string: cdn) else {
            onFail?("直连解密初始化失败")
            return
        }

        stopLocalServer()
        let server = LocalStreamServer(decryptor: decryptor, cdnURL: cdnURL)
        do {
            let port = try await server.start()
            localServer = server
            guard let url = URL(string: "http://127.0.0.1:\(port)/stream.mp4") else {
                onFail?("本地流地址无效")
                return
            }
            load(url: url, startAt: startAt, rate: rate)
        } catch {
            onFail?("本地流服务启动失败：\(error.localizedDescription)")
        }
    }

    private func stopLocalServer() {
        localServer?.stop()
        localServer = nil
    }

    func load(url: URL, startAt: Double = 0, rate: Float = 1.0) {
        removeItemObservers()
        pendingSeek = startAt

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        installObservers(item: item, rate: rate)
        player.replaceCurrentItem(with: item)
    }

    private func installObservers(item: AVPlayerItem, rate: Float) {
        statusObs = item.observe(\.status, options: [.initial, .new]) { [weak self] obj, _ in
            Task { @MainActor in
                guard let self else { return }
                switch obj.status {
                case .readyToPlay:
                    // 关键：等 readyToPlay 之后再 seek + play，否则黑屏
                    if self.pendingSeek > 0.1 {
                        await self.player.seek(to: CMTime(seconds: self.pendingSeek,
                                                          preferredTimescale: 600),
                                               toleranceBefore: .zero,
                                               toleranceAfter: .zero)
                        self.pendingSeek = 0
                    }
                    self.player.play()
                    self.player.rate = rate
                    self.isPlaying = true
                    self.onState?(true)
                case .failed:
                    self.onFail?(obj.error?.localizedDescription ?? "播放失败")
                default:
                    break
                }
            }
        }

        bufferObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] obj, _ in
            Task { @MainActor in
                if let r = obj.loadedTimeRanges.last?.timeRangeValue {
                    self?.onBuffer?((r.start + r.duration).seconds)
                }
            }
        }

        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.onState?(false)
                self?.onEnd?()
            }
        }
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        player.play()
        isPlaying = true
        onState?(true)
    }

    func pause() {
        player.pause()
        isPlaying = false
        onState?(false)
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ r: Float) {
        player.rate = r
    }

    private func removeItemObservers() {
        statusObs?.invalidate(); statusObs = nil
        bufferObs?.invalidate(); bufferObs = nil
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = nil
    }

    func teardown() {
        if let t = timeObs { player.removeTimeObserver(t) }
        timeObs = nil
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        stopLocalServer()
    }
}

// MARK: - 视频层（UIViewController，显式同步 frame）

struct VideoLayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> VideoHostController {
        let c = VideoHostController()
        c.attach(player)
        return c
    }

    func updateUIViewController(_ c: VideoHostController, context: Context) {
        c.attach(player)
    }
}

final class VideoHostController: UIViewController {
    private let playerLayer = AVPlayerLayer()
    private weak var currentPlayer: AVPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = view.bounds
        CATransaction.commit()
    }

    func attach(_ player: AVPlayer) {
        guard currentPlayer !== player else { return }
        currentPlayer = player
        playerLayer.player = player
        playerLayer.setNeedsLayout()
    }
}
