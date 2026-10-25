// 我的 / 设置页：内容源配置、播放偏好、免责声明
import SwiftUI
import UIKit
import Foundation

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var draftURL = ""
    @State private var showResetAlert = false
    @State private var showAbout = false
    @State private var copiedHint = false

    // 解析服务
    @State private var draftResolverURL = ""
    @State private var draftResolverToken = ""
    @State private var resolverStatus: ResolverStatus = .unknown

    enum ResolverStatus: Equatable {
        case unknown
        case checking
        case ok
        case failed(String)

        var text: String {
            switch self {
            case .unknown: return "未检测"
            case .checking: return "检测中…"
            case .ok: return "连接正常"
            case .failed(let m): return "失败：\(m)"
            }
        }

        var color: Color {
            switch self {
            case .unknown: return Palette.textSecondary
            case .checking: return Palette.textSecondary
            case .ok: return .green
            case .failed: return .red
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        profileCard
                        resolverSection
                        sourceSection
                        playbackSection
                        aboutSection
                        disclaimer
                        Color.clear.frame(height: player.hasActiveItem ? 110 : 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .alert("清空本地数据？", isPresented: $showResetAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.library.clearAll()
                }
            } message: {
                Text("会删除收藏、观看历史和播放进度，内容源设置不受影响。")
            }
            .sheet(isPresented: $showAbout) {
                AboutSheet()
            }
        }
    }

    // MARK: - 区块

    // MARK: 解析服务

    private var resolverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "解析服务",
                          subtitle: "填自建服务地址，红果专区可看全集 1080P")

            VStack(alignment: .leading, spacing: 10) {
                TextField("http://192.168.1.10:8787", text: $draftResolverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                SecureField("访问口令（可选，服务端设了 ACCESS_TOKEN 才需要）",
                            text: $draftResolverToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    Button {
                        saveResolver()
                    } label: {
                        Text("保存")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Palette.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await checkResolver() }
                    } label: {
                        Text("测试连接")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Palette.surface)
                            .foregroundStyle(Palette.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    Circle().fill(resolverStatus.color).frame(width: 6, height: 6)
                    Text(resolverStatus.text)
                        .font(.system(size: 11))
                        .foregroundStyle(resolverStatus.color)
                    Spacer()
                }

                Text("部署：node server/hongguo-server.mjs（默认 :8787）。同一局域网填内网 IP；公网建议套 HTTPS 并设 ACCESS_TOKEN。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Palette.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .onAppear {
            draftResolverURL = settings.resolverBaseURL
            draftResolverToken = settings.resolverToken
        }
    }

    private func saveResolver() {
        settings.resolverBaseURL = draftResolverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.resolverToken = draftResolverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await checkResolver() }
    }

    private func checkResolver() async {
        let cfg = ResolverConfig(baseURL: draftResolverURL, token: draftResolverToken)
        guard cfg.isConfigured else {
            await MainActor.run { resolverStatus = .failed("地址为空") }
            return
        }
        await MainActor.run { resolverStatus = .checking }
        let client = HGServerClient(config: cfg)
        let ok = await client.health()
        await MainActor.run {
            resolverStatus = ok ? .ok : .failed("服务未响应")
        }
    }

    private var profileCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.gradient(for: "hongguo"))
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("红果免广告")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("无开屏 · 无插播 · 无倒计时")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "内容源",
                          subtitle: "默认使用本地演示数据；填自己的 JSON 接口即可接入真实内容")

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.errorMessage == nil ? Color.green : Palette.gold)
                        .frame(width: 6, height: 6)
                    Text("当前：\(store.activeSourceName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                }

                TextField("https://example.com/feed.json", text: $draftURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )

                HStack(spacing: 8) {
                    Button {
                        settings.feedURLString = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await store.reloadAll() }
                    } label: {
                        Text("保存并刷新")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Palette.accent))
                    }
                    .buttonStyle(PressableStyle())

                    Button {
                        draftURL = ""
                        settings.feedURLString = ""
                        Task { await store.reloadAll() }
                    } label: {
                        Text("恢复默认")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(PressableStyle())
                }

                Button {
                    UIPasteboard.general.string = Self.feedTemplate
                    copiedHint = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        copiedHint = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedHint ? "checkmark" : "doc.on.doc")
                        Text(copiedHint ? "已复制到剪贴板" : "复制 JSON 格式模板")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                }

                if let updated = store.lastUpdated {
                    Text("最后更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
        }
        .onAppear {
            draftURL = settings.feedURLString
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "播放偏好")

            VStack(spacing: 0) {
                ToggleRow(title: "自动播放下一集", subtitle: "播完自动接上下一集", isOn: $settings.autoplayNext)
                Divider().background(Palette.stroke)
                ToggleRow(title: "单集循环", subtitle: "只重复播放当前这一集", isOn: $settings.loopEpisode)
                Divider().background(Palette.stroke)
                ToggleRow(title: "记住播放进度", subtitle: "下次打开从上次位置继续", isOn: $settings.rememberProgress)
                Divider().background(Palette.stroke)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("默认倍速")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                        Text(String(format: "%.2fx", settings.playbackRate))
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    Picker("", selection: $settings.playbackRate) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Text(String(format: "%.2fx", rate)).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.accent)
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "其它")

            VStack(spacing: 0) {
                Button {
                    showAbout = true
                } label: {
                    rowLabel(title: "关于这个 App", value: "v1.0.0", icon: "info.circle")
                }
                Divider().background(Palette.stroke)

                Button {
                    if let url = URL(string: "https://github.com") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    rowLabel(title: "GitHub 项目主页", value: "", icon: "link")
                }
                Divider().background(Palette.stroke)

                Button {
                    showResetAlert = true
                } label: {
                    rowLabel(title: "清空本地数据", value: "", icon: "trash", destructive: true)
                }
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("免责声明")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text("本 App 只是一个短剧播放器外壳，自身不提供、不存储、不分发任何影视内容。内置演示数据仅用于展示界面与交互，视频为公开测试流。请仅接入你拥有合法授权的内容源，并遵守当地法律法规。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textTertiary)
                .lineSpacing(2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private func rowLabel(title: String, value: String, icon: String, destructive: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? Palette.accent : Palette.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? Palette.accent : Palette.textPrimary)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    static let feedTemplate = """
    {
      "name": "我的内容源",
      "categories": [{ "id": "hot", "title": "热播" }],
      "dramas": [
        {
          "id": "demo-001",
          "title": "剧名",
          "tagline": "一句话卖点",
          "synopsis": "剧情简介",
          "tags": ["总裁", "甜宠"],
          "categoryIDs": ["hot"],
          "coverURL": "https://example.com/cover.jpg",
          "episodes": [
            {
              "id": "demo-001-1",
              "index": 1,
              "title": "第 1 集",
              "duration": 90,
              "sources": [
                { "url": "https://example.com/ep1.m3u8", "quality": "1080P", "kind": "hls", "priority": 10 }
              ]
            }
          ]
        }
      ]
    }
    """
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Palette.accent)
        }
        .padding(.vertical, 10)
    }
}

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("红果免广告 v1.0.0")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("一个纯短剧播放器：没有开屏广告、没有中插广告、没有“再看 30 秒”的倒计时。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)

                        Text("如何接入内容")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("1. 准备一个返回 JSON 的接口（格式见“我的 → 复制 JSON 格式模板”）。\n2. 在“我的 → 内容源”里填入地址并保存。\n3. App 会拉取剧集列表，点开即可播放，进度自动保存。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                            .lineSpacing(3)

                        Text("技术说明")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("SwiftUI + AVPlayer，支持 HLS(m3u8) 与 MP4 直链，支持后台播放进度记录、倍速、选集、收藏。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }.tint(.white)
                }
            }
        }
    }
}
