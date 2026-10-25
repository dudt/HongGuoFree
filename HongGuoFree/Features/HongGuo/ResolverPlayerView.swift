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

    private var client: HGServerClient {
        HGServerClient(config: settings.resolverConfig)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 8

            let p = player ?? AVPlayer()
            p.replaceCurrentItem(with: item)
            p.automaticallyWaitsToMinimizeStalling = true
            p.play()
            player = p
            current = ep
            duration = 0
            progress = 0
            installObservers(on: p, item: item)
        } catch {
            errorText = error.localizedDescription
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
