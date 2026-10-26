// 首页：真实短剧流（数据来自自建解析服务 /api/discover）
import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var feed: HGFeedStore
    @EnvironmentObject private var library: HGLibraryStore

    @State private var playerSeries: HGFeedItem?

    // 服务端 tab 语义：201 推荐 / 202 追剧 / 203 榜单 / 204 新剧
    private let tabs: [(id: Int, name: String)] = [
        (201, "推荐"),
        (202, "热播"),
        (203, "榜单"),
        (204, "新剧"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 16) {
                        header

                        // 继续观看
                        if !library.continueWatching().isEmpty {
                            continueSection
                        }

                        tabRow

                        if let msg = feed.errorText {
                            errorBanner(msg)
                        }

                        if feed.isLoading && feed.items.isEmpty {
                            loadingRow
                        }

                        ForEach(feed.items) { item in
                            FeedCard(item: item) {
                                play(item)
                            } onDetail: {
                                playerSeries = item
                            }
                            .padding(.horizontal, 16)
                            .contextMenu {
                                Button {
                                    library.toggleFavorite(item)
                                } label: {
                                    Label(
                                        library.isFavorite(item.seriesID) ? "取消收藏" : "收藏",
                                        systemImage: library.isFavorite(item.seriesID)
                                            ? "bookmark.slash" : "bookmark"
                                    )
                                }
                                Button {
                                    playerSeries = item
                                } label: {
                                    Label("播放", systemImage: "play.fill")
                                }
                            }
                            .onAppear {
                                if item.seriesID == feed.items.suffix(2).first?.seriesID {
                                    Task { await feed.loadMore(config: settings.resolverConfig) }
                                }
                            }
                        }

                        if feed.items.isEmpty && !feed.isLoading && feed.errorText == nil {
                            EmptyStateView(
                                icon: "sparkles.tv",
                                title: "还没有内容",
                                message: settings.hasResolver
                                    ? "下拉刷新试试。"
                                    : "先在「我的 → 解析服务」填好服务地址。"
                            )
                        }

                        if !feed.items.isEmpty && !feed.hasMore {
                            Text("— 已经到底了 —")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textTertiary)
                                .padding(.vertical, 12)
                        }

                        Color.clear.frame(height: 24)
                    }
                    .padding(.top, 8)
                }
                .refreshable {
                    await feed.reload(config: settings.resolverConfig)
                }
            }
            .navigationTitle("红果免广告")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if feed.items.isEmpty {
                    await feed.reload(config: settings.resolverConfig)
                }
            }
            .onChange(of: settings.resolverBaseURL) { _ in
                Task { await feed.reload(config: settings.resolverConfig) }
            }
            .fullScreenCover(item: $playerSeries) { item in
                ResolverPlayerView(
                    seriesID: item.seriesID,
                    seriesTitle: item.title ?? "红果短剧"
                )
                .environmentObject(settings)
                .environmentObject(library)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text("红果短剧")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                if settings.hasResolver {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("1080P")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.surface)
                    .clipShape(Capsule())
                }
            }
            Text("无开屏 · 无插播 · 全集合集")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 16)
    }

    // MARK: 继续观看

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.accent)
                Text("继续观看")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(library.continueWatching()) { rec in
                        Button {
                            resume(rec)
                        } label: {
                            continueCard(rec)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                library.removeHistory(rec.seriesID)
                            } label: { Label("从历史移除", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func continueCard(_ rec: HGRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: rec.cover ?? "")) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Palette.gradient(for: rec.seriesID))
                            .overlay(
                                Text(String(rec.title.prefix(1)))
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.85))
                            )
                    }
                }
                .frame(width: 128, height: 172)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 进度条
                if rec.progressRatio > 0 {
                    VStack {
                        Spacer()
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5)).frame(height: 3)
                                Rectangle().fill(Palette.accent)
                                    .frame(width: g.size.width * rec.progressRatio, height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // 集数角标
                if let e = rec.lastEpisode {
                    Text("看到第\(e)集")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .frame(width: 128, height: 172)

            Text(rec.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)

            if !rec.progressText.isEmpty {
                Text(rec.progressText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private func resume(_ rec: HGRecord) {
        playerSeries = HGFeedItem(
            seriesID: rec.seriesID, itemID: nil, title: rec.title,
            cover: rec.cover, intro: nil, tags: nil, episodeText: nil,
            episodeCount: rec.episodeCount, freeEpisodes: nil,
            playCount: nil, followedCount: nil
        )
    }

    // MARK: 分类

    private var tabRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.id) { t in
                    Button {
                        Task { await feed.selectTab(t.id) }
                    } label: {
                        Text(t.name)
                            .font(.system(size: 13, weight: feed.tab == t.id ? .semibold : .regular))
                            .foregroundStyle(feed.tab == t.id ? .white : Palette.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(feed.tab == t.id ? Palette.accent : Palette.surface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: 状态

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.gold)
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(3)
            Spacer()
            Button("重试") {
                Task { await feed.reload(config: settings.resolverConfig) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.accent)
        }
        .padding(12)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    private var loadingRow: some View {
        VStack(spacing: 10) {
            ProgressView().tint(Palette.accent)
            Text("正在拉取真实剧库…")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func play(_ item: HGFeedItem) {
        playerSeries = item
    }
}

// MARK: - 卡片

private struct FeedCard: View {
    let item: HGFeedItem
    let onPlay: () -> Void
    let onDetail: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                poster
                info
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var poster: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: URL(string: item.cover ?? "")) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                case .empty:
                    placeholder.overlay(ProgressView().tint(.white.opacity(0.6)))
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 96, height: 132)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let c = item.episodeCount, c > 0 {
                Text("\(c)集")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(5)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Palette.gradient(for: item.seriesID))
            .overlay(
                Text(String((item.title ?? "?").prefix(1)))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            )
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title ?? "未命名")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let tags = item.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { t in
                        Text(t)
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Palette.background.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            if let intro = item.intro, !intro.isEmpty {
                Text(intro)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if !item.playText.isEmpty {
                    Label(item.playText, systemImage: "play.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.textTertiary)
                }
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                    Text("1080P")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Palette.accent)
            }
        }
        .frame(height: 132, alignment: .top)
    }
}
