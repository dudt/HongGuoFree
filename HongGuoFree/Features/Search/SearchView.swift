// 发现页：搜索 + 热门榜
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var keyword = ""
    @State private var path: [Drama] = []
    @FocusState private var focused: Bool

    private var results: [Drama] {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? store.trending
            : store.search(keyword)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        searchField

                        if keyword.isEmpty {
                            hotTags
                        }

                        SectionHeader(title: keyword.isEmpty ? "热播榜" : "搜索结果",
                                      subtitle: keyword.isEmpty ? "按播放量排序" : "\(results.count) 部相关短剧")
                            .padding(.horizontal, 16)

                        ForEach(results.indices, id: \.self) { index in
                            rankRow(index: index, drama: results[index])
                                .padding(.horizontal, 16)
                        }

                        if results.isEmpty {
                            EmptyStateView(icon: "magnifyingglass",
                                           title: "没有找到相关短剧",
                                           message: "换个关键词试试，比如“总裁”“重生”“甜宠”。")
                        }

                        Color.clear.frame(height: 24)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Drama.self) { drama in
                DramaDetailView(drama: drama)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            TextField("搜索剧名、标签、剧情", text: $keyword)
                .focused($focused)
                .submitLabel(.search)
                .foregroundStyle(Palette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .stroke(Palette.stroke, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private var hotTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["总裁", "重生", "甜宠", "逆袭", "古装", "悬疑"], id: \.self) { tag in
                    Button {
                        keyword = tag
                    } label: {
                        TagChip(text: tag)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func rankRow(index: Int, drama: Drama) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(index < 3 ? Palette.accent : Palette.textTertiary)
                .frame(width: 22)

            HStack(spacing: 12) {
                PosterView(title: drama.title, urlString: drama.coverURL)
                    .frame(width: 56, height: 76)

                VStack(alignment: .leading, spacing: 4) {
                    Text(drama.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    Text(drama.displayTagline)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("全 \(drama.episodeCount) 集")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textTertiary)
                        if !drama.heatText.isEmpty {
                            Text(drama.heatText)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                path.append(drama)
            }

            Button {
                play(drama)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.accent.opacity(0.9)))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
    }

    private func play(_ drama: Drama) {
        guard let first = drama.episodes.sorted(by: { $0.index < $1.index }).first else { return }
        player.play(drama: drama, episode: first)
        player.isFullScreen = true
    }
}
