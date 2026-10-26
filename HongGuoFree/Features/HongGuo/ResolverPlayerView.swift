// 播放页
//
// 播放本身交给系统 AVPlayerViewController（自带控制层/手势/AirPlay/画中画），
// 外层只负责：拉数据、选集、清晰度、弹幕设置、进度保存、自动连播。
import SwiftUI
import AVKit
import AVFoundation

struct HGVariant: Identifiable, Hashable {
    var vid: String
    var label: String
    var url: URL
    var id: String { vid + label }
}

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
    @State private var lastSavedSecond = -1

    // 弹幕
    @StateObject private var danmaku = DanmakuEngine()

    // UI
    @State private var showEpisodes = false
    @State private var showQuality = false
    @State private var showDanmakuSettings = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    // 观察
    @State private var timeObserver: Any?
    @State private var statusObs: NSKeyValueObservation?
    @State private var endObserver: NSObjectProtocol?

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            NativePlayerView(
                player: player,
                danmakuItems: danmaku.scheduled,
                danmakuSettings: danmaku.settings,
                showsControls: true
            )
            .ignoresSafeArea()

            // 自定义顶部/底部（系统控制层之外的补充入口）
            if controlsVisible {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
                .allowsHitTesting(true)
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
        .task { await loadDetail() }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showQuality) { qualitySheet }
        .sheet(isPresented: $showDanmakuSettings) { danmakuSettingsSheet }
        .onDisappear { teardown() }
    }

    // MARK: 顶部

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { teardown(); dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45))
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

            Button { danmaku.settings.enabled.toggle() } label: {
                Image(systemName: danmaku.settings.enabled
                      ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(danmaku.settings.enabled ? .white : .white.opacity(0.45))
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45))
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
                    Button {
                        player.rate = r
                    } label: {
                        Label(r == 1.0 ? "正常速度" : "\(r)x",
                              systemImage: abs(player.rate - r) < 0.01
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
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 30)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: 底部

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(fmt(progress))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

            // 简洁进度条（可拖）
            GeometryReader { g in
                let w = g.size.width
                let total = max(duration, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                    Capsule().fill(Palette.accent)
                        .frame(width: w * CGFloat(min(progress / total, 1)), height: 3)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let ratio = min(max(v.location.x / w, 0), 1)
                            let t = Double(ratio) * total
                            progress = t
                            player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                )
            }
            .frame(height: 18)

            Text(fmt(duration))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))

            Button { showEpisodes = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet").font(.system(size: 10))
                    Text("选集").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.18))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 20)
        .padding(.top, 34)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
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
            Button("重试") { Task { await loadDetail() } }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Palette.accent).foregroundStyle(.white)
                .clipShape(Capsule()).buttonStyle(.plain)
        }
        .padding(20)
        .background(.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 弹层

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
            lastSavedSecond = -1

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
            // 静默失败，不打扰播放
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

    // MARK: 观察

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
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { t in
            let s = t.seconds
            if s.isFinite { progress = s }
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
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
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
