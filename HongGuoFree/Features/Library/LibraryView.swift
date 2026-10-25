// 追剧 / 历史
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: HGLibraryStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var tab = 0
    @State private var playing: HGRecord?

    private var list: [HGRecord] {
        tab == 0 ? library.favorites : library.history
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        segmented

                        if list.isEmpty {
                            EmptyStateView(
                                icon: tab == 0 ? "bookmark" : "clock.arrow.circlepath",
                                title: tab == 0 ? "还没有追剧" : "还没有观看记录",
                                message: tab == 0
                                    ? "在首页长按或进入详情页可以收藏。"
                                    : "看过的短剧会出现在这里。"
                            )
                            .padding(.top, 60)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 104), spacing: 12)],
                                spacing: 16
                            ) {
                                ForEach(list) { rec in
                                    Button { playing = rec } label: {
                                        cell(rec)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            if tab == 0 { library.removeFavorite(rec.seriesID) }
                                            else { library.removeHistory(rec.seriesID) }
                                        } label: {
                                            Label("移除", systemImage: "trash")
                                        }
                                    }
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
            .toolbar {
                if tab == 1 && !library.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空") { library.clearHistory() }
                            .font(.system(size: 13))
                    }
                }
            }
            .fullScreenCover(item: $playing) { rec in
                ResolverPlayerView(
                    seriesID: rec.seriesID,
                    seriesTitle: rec.title,
                    startIndex: rec.lastEpisode ?? 1
                )
                .environmentObject(settings)
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { i in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { tab = i }
                } label: {
                    VStack(spacing: 6) {
                        Text(i == 0 ? "收藏 \(library.favorites.count)"
                                    : "历史 \(library.history.count)")
                            .font(.system(size: 13, weight: tab == i ? .semibold : .regular))
                            .foregroundStyle(tab == i ? Palette.textPrimary : Palette.textSecondary)
                        Rectangle()
                            .fill(tab == i ? Palette.accent : .clear)
                            .frame(height: 2)
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func cell(_ rec: HGRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: rec.cover ?? "")) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder(rec)
                    case .empty:
                        placeholder(rec).overlay(ProgressView().tint(.white.opacity(0.5)))
                    @unknown default:
                        placeholder(rec)
                    }
                }
                .frame(height: 148)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if let ep = rec.lastEpisode {
                    Text("看到 \(ep)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }
            Text(rec.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func placeholder(_ rec: HGRecord) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Palette.gradient(for: rec.seriesID))
            .overlay(
                Text(String(rec.title.prefix(1)))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            )
    }
}
