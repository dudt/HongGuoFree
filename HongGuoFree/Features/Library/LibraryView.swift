// 追剧页：收藏 + 观看历史
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var tab = 0
    @State private var path: [Drama] = []

    private var favorites: [Drama] { store.favorites }
    private var history: [Drama] { store.historyDramas }
    private var list: [Drama] { tab == 0 ? favorites : history }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: $tab) {
                            Text("收藏 \(favorites.count)").tag(0)
                            Text("历史 \(history.count)").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)

                        if list.isEmpty {
                            EmptyStateView(icon: tab == 0 ? "bookmark" : "clock.arrow.circlepath",
                                           title: tab == 0 ? "还没有收藏" : "还没有观看记录",
                                           message: tab == 0
                                                 ? "在详情页点右上角的书签，就能把剧集存到这里。"
                                                 : "看过的短剧会自动出现在这里，方便接着追。")
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                                      spacing: 16) {
                                ForEach(list) { drama in
                                    gridCell(drama)
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Color.clear.frame(height: 24)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("追剧")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Drama.self) { drama in
                DramaDetailView(drama: drama)
            }
        }
    }

    private func gridCell(_ drama: Drama) -> some View {
        Button {
            path.append(drama)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                PosterView(title: drama.title, urlString: drama.coverURL)
                    .frame(height: 150)
                    .overlay(alignment: .bottomLeading) {
                        if let record = store.library.record(for: drama.id) {
                            ProgressBar(value: record.progress)
                                .padding(6)
                        }
                    }
                Text(drama.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text("全 \(drama.episodeCount) 集")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button {
                play(from: drama)
            } label: {
                Label("立即播放", systemImage: "play.fill")
            }
            Button {
                store.library.toggleFavorite(drama.id)
            } label: {
                Label(store.library.isFavorite(drama.id) ? "取消收藏" : "加入收藏",
                      systemImage: store.library.isFavorite(drama.id) ? "bookmark.slash" : "bookmark")
            }
            Button(role: .destructive) {
                store.library.clearProgress(for: drama.id)
            } label: {
                Label("清除播放进度", systemImage: "trash")
            }
        }
    }

    private func play(from drama: Drama) {
        guard let first = drama.episodes.sorted(by: { $0.index < $1.index }).first else { return }
        player.play(drama: drama, episode: first)
        player.isFullScreen = true
    }
}
