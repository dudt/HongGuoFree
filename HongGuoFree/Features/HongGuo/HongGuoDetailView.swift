// 红果详情页：简介 + 选集 + 网页播放
import SwiftUI

struct HongGuoDetailView: View {
    let drama: Drama

    @EnvironmentObject private var hongguo: HongGuoStore
    @EnvironmentObject private var store: AppStore

    @State private var fullDrama: Drama?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var playerEpisode: Episode?
    @State private var selectedRange = 0

    private var current: Drama { fullDrama ?? drama }

    private var orderedEpisodes: [Episode] {
        current.episodes.sorted { $0.index < $1.index }
    }

    private var freeCount: Int {
        orderedEpisodes.filter { $0.isFree == true }.count
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
        guard !ranges.isEmpty else { return orderedEpisodes }
        let range = ranges[min(selectedRange, ranges.count - 1)]
        return orderedEpisodes.filter { range.contains($0.index) }
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if isLoading {
                        ProgressView().tint(Palette.accent).padding(.horizontal, 16)
                    }
                    if let loadError {
                        Text(loadError)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.gold)
                            .padding(.horizontal, 16)
                    }
                    playBanner
                    synopsis
                    episodeSection
                    Color.clear.frame(height: 24)
                }
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadFullDetail()
        }
        .fullScreenCover(item: $playerEpisode) { episode in
            if let url = playerURL(for: episode) {
                HongGuoWebPlayerScreen(
                    url: url,
                    title: current.title,
                    episodeTitle: episode.displayTitle,
                    onNext: nil,
                    onSelectEpisode: nil
                )
            } else {
                EmptyStateView(icon: "exclamationmark.triangle",
                               title: "无法打开播放页",
                               message: "这一集缺少播放标识，换一集试试。")
            }
        }
    }

    /// 从 Episode 反解出红果播放页地址
    private func playerURL(for episode: Episode) -> URL? {
        // PlaySource.url 形如 hg://<seriesID>/<vid>/<index>
        guard let raw = episode.sources.first?.url else { return nil }
        let parts = raw.replacingOccurrences(of: "hg://", with: "").split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let vid = String(parts[1])
        return hongguo.playerURL(seriesID: current.id, vid: vid)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterView(title: current.title, urlString: current.coverURL)
                .frame(width: 110, height: 150)

            VStack(alignment: .leading, spacing: 7) {
                Text(current.title)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundStyle(Palette.textPrimary)

                if !current.displayTagline.isEmpty {
                    Text(current.displayTagline)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    Text("全 \(current.episodeCount) 集")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                    if !current.heatText.isEmpty {
                        Text(current.heatText)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }

                HStack(spacing: 6) {
                    ForEach(Array(current.displayTags.prefix(3)), id: \.self) { tag in
                        TagChip(text: tag, highlighted: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var playBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: freeCount > 0 ? "checkmark.seal.fill" : "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(freeCount > 0 ? Color.green : Palette.gold)
                Text(freeCount > 0 ? "网页端可免费看前 \(freeCount) 集" : "网页端暂未开放本剧")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
            }
            Text("超出部分请在「红果短剧」官方 App 内观看。本 App 不做破解。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)

            if let first = orderedEpisodes.first(where: { $0.isFree == true }) {
                Button {
                    playerEpisode = first
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放第 1 集")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.accent))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .padding(.horizontal, 16)
    }

    private var synopsis: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("简介")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            Text(current.synopsis ?? current.displayTagline)
                .font(.system(size: 12))
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
                Text("共 \(orderedEpisodes.count) 集")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, 16)

            if ranges.count > 1 {
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
                        if episode.isFree == true {
                            playerEpisode = episode
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(episode.index)")
                                .font(.system(size: 14, weight: .semibold))
                            if episode.isFree == true {
                                Text("免费")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Palette.accent)
                            } else {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .foregroundStyle(episode.isFree == true ? Palette.textPrimary : Palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(episode.isFree == true ? 0.06 : 0.02))
                        )
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(episode.isFree != true)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func loadFullDetail() async {
        guard fullDrama == nil else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            fullDrama = try await hongguo.loadDetail(seriesID: drama.id)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
