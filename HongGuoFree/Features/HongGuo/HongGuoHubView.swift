// 红果专区：搜索 + 结果 + 详情 + 网页播放
import SwiftUI

struct HongGuoHubView: View {
    @EnvironmentObject private var hongguo: HongGuoStore
    @EnvironmentObject private var store: AppStore

    @State private var keyword = ""
    @State private var path: [Drama] = []
    @FocusState private var focused: Bool

    private let hotWords = ["重生", "总裁", "战神", "穿越", "甜宠", "逆袭", "古装", "悬疑"]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        banner
                        searchField

                        if hongguo.results.isEmpty && !hongguo.isLoading {
                            hotSection
                        }

                        if hongguo.isLoading {
                            loadingRow
                        }

                        if let message = hongguo.errorMessage, !hongguo.isLoading {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 16)
                        }

                        if !hongguo.results.isEmpty {
                            SectionHeader(title: "搜索结果",
                                          subtitle: "\(hongguo.results.count) 部 · 来自红果短剧")
                                .padding(.horizontal, 16)

                            ForEach(hongguo.results) { drama in
                                HGResultRow(drama: drama) {
                                    path.append(drama)
                                }
                                .padding(.horizontal, 16)
                            }
                        }

                        Color.clear.frame(height: 24)
                    }
                    .padding(.top, 8)
                }
            }
            .navigationTitle("红果专区")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Drama.self) { drama in
                HongGuoDetailView(drama: drama)
            }
        }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text("红果网页版 · 无广告播放")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            Text("搜索你想看的短剧")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text("数据来自红果短剧官方网页。网页端每部剧开放前 3 集，其余需在官方 App 内观看。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
                .lineSpacing(2)
        }
        .padding(14)
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.textTertiary)
            TextField("搜索红果短剧，如：重生", text: $keyword)
                .focused($focused)
                .submitLabel(.search)
                .foregroundStyle(Palette.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { runSearch(keyword) }

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    hongguo.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            Button("搜索") { runSearch(keyword) }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "试试这些", subtitle: "点一下直接搜")
                .padding(.horizontal, 16)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(hotWords, id: \.self) { word in
                    Button {
                        keyword = word
                        runSearch(word)
                    } label: {
                        Text(word)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var loadingRow: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
                    .frame(height: 96)
                    .padding(.horizontal, 16)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private func runSearch(_ text: String) {
        focused = false
        Task { await hongguo.search(text) }
    }
}

// MARK: - 结果行

struct HGResultRow: View {
    let drama: Drama
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                PosterView(title: drama.title, urlString: drama.coverURL)
                    .frame(width: 62, height: 84)

                VStack(alignment: .leading, spacing: 5) {
                    Text(drama.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)

                    if !drama.displayTagline.isEmpty {
                        Text(drama.displayTagline)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        Text("全 \(drama.episodeCount) 集")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.accent)
                        if !drama.heatText.isEmpty {
                            Text(drama.heatText)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
        }
        .buttonStyle(PressableStyle())
    }
}
