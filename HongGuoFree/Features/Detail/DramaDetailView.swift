// 详情页：简介、选集、收藏
import SwiftUI

struct DramaDetailView: View {
    let drama: Drama

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var selectedRange = 0
    @State private var showAllEpisodes = false

    private var orderedEpisodes: [Episode] {
        drama.episodes.sorted { $0.index < $1.index }
    }

    private var ranges: [ClosedRange<Int>] {
        let total = orderedEpisodes.count
        guard total > 0 else { return [] }
        var result: [ClosedRange<Int>] = []
        var start = 1
        while start <= total {
            let end = min(start + 29, total)
            result.append(start...end)
            start = end + 1
        }
        return result
    }

    private var visibleEpisodes: [Episode] {
        guard showAllEpisodes || ranges.isEmpty else {
            let range = ranges[min(selectedRange, ranges.count - 1)]
            return drama.filteredEpisodes(in: range)
        }
        return orderedEpisodes
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actionRow
                    synopsis
                    episodeSection
                    Color.clear.frame(height: player.hasActiveItem ? 110 : 24)
                }
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(drama.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.library.toggleFavorite(drama.id)
                } label: {
                    Image(systemName: store.library.isFavorite(drama.id) ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(store.library.isFavorite(drama.id) ? Palette.accent : Color.white)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterView(title: drama.title, urlString: drama.coverURL)
                .frame(width: 118, height: 160)

            VStack(alignment: .leading, spacing: 8) {
                Text(drama.title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Palette.textPrimary)

                if !drama.displayTagline.isEmpty {
                    Text(drama.displayTagline)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    if let rating = drama.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.gold)
                    }
                    Text(drama.isFinished == true ? "已完结" : "更新中")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                    Text("全 \(drama.episodeCount) 集")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }

                if !drama.heatText.isEmpty {
                    Text(drama.heatText)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }

                HStack(spacing: 6) {
                    ForEach(drama.displayTags.prefix(3), id: \.self) { tag in
                        TagChip(text: tag, highlighted: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                guard let first = orderedEpisodes.first else { return }
                player.play(drama: drama, episode: first)
                player.isFullScreen = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("从第 1 集开始")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.accent))
            }
            .buttonStyle(PressableStyle())

            if let record = store.library.record(for: drama.id) {
                Button {
                    if let episode = orderedEpisodes.first(where: { $0.id == record.episodeID }) {
                        player.play(drama: drama, episode: episode)
                        player.isFullScreen = true
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text("继续看")
                            .font(.system(size: 13, weight: .semibold))
                        Text("第 \(record.episodeIndex) 集")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 92)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 16)
    }

    private var synopsis: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("简介")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(drama.synopsis ?? drama.displayTagline)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
        }
        .padding(.horizontal, 16)
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选集")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if ranges.count > 1 {
                    Button(showAllEpisodes ? "分段显示" : "展开全部") {
                        showAllEpisodes.toggle()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.horizontal, 16)

            if !showAllEpisodes && ranges.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ranges.indices, id: \.self) { index in
                            let range = ranges[index]
                            Button {
                                selectedRange = index
                            } label: {
                                TagChip(text: "\(range.lowerBound)-\(range.upperBound)",
                                        highlighted: selectedRange == index)
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(visibleEpisodes) { episode in
                    Button {
                        player.play(drama: drama, episode: episode)
                        player.isFullScreen = true
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(episode.index)")
                                .font(.system(size: 14, weight: .semibold))
                            if player.currentEpisode?.id == episode.id {
                                Text("播放中")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                        .foregroundStyle(player.currentEpisode?.id == episode.id ? Palette.accent : Palette.textPrimary)
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
            .padding(.horizontal, 16)
        }
    }
}
