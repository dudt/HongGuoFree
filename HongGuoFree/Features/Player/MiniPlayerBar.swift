// 底部迷你播放条
import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.isFullScreen = true
            } label: {
                HStack(spacing: 10) {
                    PosterView(title: player.currentDrama?.title ?? "",
                               urlString: player.currentDrama?.coverURL)
                        .frame(width: 34, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentDrama?.title ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Text(player.episodeTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 34, height: 34)
            }

            Button {
                player.playNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.upNext == nil ? Palette.textTertiary : Palette.textPrimary)
                    .frame(width: 30, height: 34)
            }
            .disabled(player.upNext == nil)

            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 28, height: 34)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.surfaceHigh)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        )
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: geo.size.width * CGFloat(player.progressFraction), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
