// 全屏播放页：点击显隐控件、进度条、倍速、选集、下一集
import SwiftUI
import AVKit
import UIKit
import Foundation

struct PlayerScreen: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var scrubValue: Double = 0
    @State private var showEpisodes = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoLayer(player: player.player)
                .ignoresSafeArea()

            // 点击任意位置切换控件显隐
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible.toggle()
                    }
                    if controlsVisible { scheduleHide() }
                }
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onChanged { value in
                            dragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            dragOffset = 0
                            if value.translation.height > 110 {
                                dismiss()
                            } else if value.translation.height < -110 {
                                showEpisodes = true
                            }
                        }
                )

            if player.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if let message = player.failedMessage {
                errorOverlay(message: message)
            }
        }
        .offset(y: dragOffset * 0.35)
        .onAppear {
            controlsVisible = true
            scheduleHide()
        }
        .onDisappear { hideWorkItem?.cancel() }
        .sheet(isPresented: $showEpisodes) {
            EpisodePickerSheet()
                .environmentObject(player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 控件

    private var controls: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentDrama?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(player.episodeTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Button {
                showEpisodes = true
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(player.isScrubbing ? scrubValue.timeText : player.currentTime.timeText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 48, alignment: .leading)

                Slider(value: Binding(
                    get: { player.isScrubbing ? scrubValue : player.currentTime },
                    set: { newValue in
                        player.isScrubbing = true
                        scrubValue = newValue
                    }
                ), in: 0...max(player.duration, 1), onEditingChanged: { editing in
                    if !editing {
                        player.seek(to: scrubValue)
                        player.isScrubbing = false
                        scheduleHide()
                    }
                })
                .tint(Palette.accent)

                Text(player.duration.timeText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 48, alignment: .trailing)
            }

            HStack(spacing: 20) {
                Button {
                    player.skip(by: -15)
                    scheduleHide()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

                Button {
                    player.togglePlayPause()
                    scheduleHide()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Palette.accent))
                }

                Button {
                    player.playNext()
                    scheduleHide()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(player.upNext == nil ? Color.white.opacity(0.3) : Color.white)
                }
                .disabled(player.upNext == nil)

                Spacer()

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(String(format: "%.2fx", rate)) {
                            settings.playbackRate = rate
                            player.setRate(rate)
                        }
                    }
                } label: {
                    Text(String(format: "%.2fx", settings.playbackRate))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
            }
        }
    }

    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Palette.gold)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("重试") {
                    player.dismissError()
                    if let episode = player.currentEpisode {
                        player.select(episode: episode)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Palette.accent))

                Button("下一集") {
                    player.dismissError()
                    player.playNext()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.15)))
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Color.black.opacity(0.82)))
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) {
                controlsVisible = false
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
    }
}

// MARK: - 视频渲染层

struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - 选集面板

struct EpisodePickerSheet: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                if let drama = player.currentDrama {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                                  spacing: 8) {
                            ForEach(drama.episodes.sorted { $0.index < $1.index }) { episode in
                                Button {
                                    player.select(episode: episode)
                                    dismiss()
                                } label: {
                                    Text("\(episode.index)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(player.currentEpisode?.id == episode.id
                                                         ? Palette.accent : Palette.textPrimary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(player.currentEpisode?.id == episode.id
                                                      ? Palette.accent.opacity(0.16)
                                                      : Color.white.opacity(0.06))
                                        )
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(16)
                    }
                } else {
                    EmptyStateView(icon: "film", title: "没有正在播放的剧", message: "先回到首页挑一部吧。")
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .tint(.white)
                }
            }
        }
    }
}
