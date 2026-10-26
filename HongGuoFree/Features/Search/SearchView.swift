// 搜索页
//
// 服务端没有上游搜索接口（红果 App 未公开），
// 所以在服务端建本地索引（4 个 tab 全量 feed），搜索时本地匹配。
// 首次搜索若索引未热，要等十几秒；服务端启动时会后台预热。
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: HGLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [HGFeedItem] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var indexedTotal = 0
    @State private var playerSeries: HGFeedItem?

    @FocusState private var focused: Bool

    private var client: HGServerClient { HGServerClient(config: settings.resolverConfig) }

    /// 热门搜索词（本地索引里出现频率高的题材）
    private let suggestions = [
        "末世", "总裁", "重生", "穿越", "豪门",
        "战神", "逆袭", "甜宠", "复仇", "系统",
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar

                    if let errorText {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 24)).foregroundStyle(.orange)
                            Text(errorText)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .frame(maxHeight: .infinity)
                    } else if searching {
                        VStack(spacing: 12) {
                            ProgressView().tint(Palette.accent)
                            Text(indexedTotal == 0 ? "首次搜索要建索引，约 10 秒…" : "搜索中…")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .frame(maxHeight: .infinity)
                    } else if results.isEmpty {
                        emptyState
                    } else {
                        resultGrid
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .fullScreenCover(item: $playerSeries) { item in
                ResolverPlayerView(seriesID: item.seriesID,
                                   seriesTitle: item.title ?? "红果短剧")
                    .environmentObject(settings)
                    .environmentObject(library)
            }
        }
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textTertiary)
                TextField("搜剧名、题材", text: $query)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textPrimary)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await runSearch() } }
                if !query.isEmpty {
                    Button { query = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                Task { await runSearch() }
            } label: {
                Text("搜索")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(query.isEmpty ? Palette.surface : Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(query.isEmpty || searching)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("试试这些")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)

            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        query = s
                        Task { await runSearch() }
                    } label: {
                        Text(s)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(Palette.surface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 结果

    private var resultGrid: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("\(results.count) 个结果")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ], spacing: 14) {
                    ForEach(results) { item in
                        Button { playerSeries = item } label: {
                            card(item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                library.toggleFavorite(item)
                            } label: {
                                Label(library.isFavorite(item.seriesID)
                                      ? "取消收藏" : "收藏",
                                      systemImage: library.isFavorite(item.seriesID)
                                        ? "bookmark.slash" : "bookmark")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func card(_ item: HGFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            AsyncImage(url: URL(string: item.cover ?? "")) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Palette.gradient(for: item.seriesID))
                        .overlay(
                            Text(String((item.title ?? "?").prefix(1)))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        )
                }
            }
            .frame(height: 168)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Text(item.title ?? "未命名")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 搜索

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        focused = false
        searching = true
        errorText = nil
        defer { searching = false }

        do {
            let resp = try await client.search(q)
            results = resp.items ?? []
            indexedTotal = resp.totalIndexed ?? 0
            if results.isEmpty {
                errorText = nil
            }
        } catch {
            errorText = error.localizedDescription
            results = []
        }
    }
}

// MARK: - 简单流式布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 {
                x = 0
                y += lineH + spacing
                lineH = 0
            }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineH + spacing
                lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
