// 首页：竖向沉浸流
import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var selectedCategory: String?
    @State private var path: [Drama] = []

    private var filtered: [Drama] {
        store.filtered(byCategory: selectedCategory)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 18) {
                        heroHeader

                        if let message = store.errorMessage {
                            ErrorBanner(message: message) {
                                Task { await store.reloadAll() }
                            }
                        }

                        if !store.continueWatching().isEmpty {
                            continueSection
                        }

                        categoryRow

                        if store.isLoading && store.dramas.isEmpty {
                            loadingRow
                        }

                        ForEach(filtered) { drama in
                            DramaCard(drama: drama) {
                                play(drama: drama)
                            } onOpenDetail: {
                                path.append(drama)
                            }
                            .padding(.horizontal, 16)
                        }

                        if filtered.isEmpty && !store.isLoading {
                            EmptyStateView(icon: "film",
                                           title: "这里还没有内容",
                                           message: "换个分类看看，或在“我的 → 内容源”里填入你自己的 JSON 接口。")
                        }

                        Color.clear.frame(height: player.hasActiveItem ? 118 : 24)
                    }
                    .padding(.top, 8)
                }
                .refreshable {
                    await store.reloadAll()
                }
            }
            .navigationTitle("红果免广告")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Drama.self) { drama in
                DramaDetailView(drama: drama)
            }
        }
    }

    // MARK: - 区块

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 6, height: 6)
                Text("无广告 · 纯短剧")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(store.activeSourceName)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            Text("一口气追完整部剧")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text("没有开屏、没有插播、没有倒计时。")
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "继续观看", subtitle: "接着上次的进度")
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.continueWatching()) { item in
                        Button {
                            play(drama: item.drama, resume: item.record)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                PosterView(title: item.drama.title, urlString: item.drama.coverURL)
                                    .frame(width: 116, height: 156)
                                    .overlay(alignment: .bottom) {
                                        ProgressBar(value: item.record.progress)
                                            .padding(6)
                                    }
                                Text(item.drama.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                    .frame(width: 116, alignment: .leading)
                                Text("第 \(item.record.episodeIndex) 集")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedCategory = nil
                } label: {
                    TagChip(text: "全部", highlighted: selectedCategory == nil)
                }
                .buttonStyle(PressableStyle())

                ForEach(store.categories) { category in
                    Button {
                        selectedCategory = (selectedCategory == category.id) ? nil : category.id
                    } label: {
                        TagChip(text: category.title, highlighted: selectedCategory == category.id)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var loadingRow: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
                    .frame(height: 150)
                    .padding(.horizontal, 16)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private func play(drama: Drama, resume: PlaybackRecord? = nil) {
        let ordered = drama.episodes.sorted { $0.index < $1.index }
        guard !ordered.isEmpty else { return }
        if let resume,
           let episode = drama.episodes.first(where: { $0.id == resume.episodeID }) {
            player.play(drama: drama, episode: episode)
        } else if let first = ordered.first {
            player.play(drama: drama, episode: first)
        }
        player.isFullScreen = true
        store.library.touchHistory(drama.id)
    }
}

// MARK: - 组件

struct PosterView: View {
    let title: String
    let urlString: String?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            PosterPlaceholder(title: title)
                        }
                    }
                } else {
                    PosterPlaceholder(title: title)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Radius.poster, style: .continuous))
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
            }
        }
        .frame(height: 3)
    }
}

struct DramaCard: View {
    let drama: Drama
    let onPlay: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpenDetail) {
                PosterView(title: drama.title, urlString: drama.coverURL)
                    .frame(width: 96, height: 132)
                    .overlay(alignment: .topLeading) {
                        if let rating = drama.rating {
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Palette.gold))
                                .padding(6)
                        }
                    }
            }
            .buttonStyle(PressableStyle())

            VStack(alignment: .leading, spacing: 6) {
                Text(drama.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                if !drama.displayTagline.isEmpty {
                    Text(drama.displayTagline)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text("全 \(drama.episodeCount) 集")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.accent)
                    if !drama.heatText.isEmpty {
                        Text("·").foregroundStyle(Palette.textTertiary)
                        Text(drama.heatText)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                    }
                }

                HStack(spacing: 6) {
                    ForEach(Array(drama.displayTags.prefix(3)), id: \.self) { tag in
                        TagChip(text: tag)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button(action: onPlay) {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("立即播放")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Palette.accent))
                    }
                    .buttonStyle(PressableStyle())

                    Button(action: onOpenDetail) {
                        Text("选集")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
        )
    }
}

struct ErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text("内容源加载失败")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(3)
            }
            Spacer()
            Button("重试", action: onRetry)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.accent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Palette.gold.opacity(0.12))
        )
        .padding(.horizontal, 16)
    }
}
