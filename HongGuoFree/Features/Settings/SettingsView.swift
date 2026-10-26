// 我的 / 设置
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var draftURL = ""
    @State private var draftToken = ""
    @State private var status: ConnStatus = .unknown
    @State private var showAbout = false

    enum ConnStatus: Equatable {
        case unknown, checking, ok, failed(String)

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
            case .unknown, .checking: return Palette.textSecondary
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
                        playbackSection
                        aboutSection
                        disclaimer
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draftURL = settings.resolverBaseURL
                draftToken = settings.resolverToken
                Task { await check() }
            }
            .sheet(isPresented: $showAbout) { aboutSheet }
        }
    }

    // MARK: 资料卡

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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("无开屏 · 无插播 · 无倒计时")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 解析服务

    private var resolverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("解析服务", "填自建服务地址，全站 1080P 直连")

            VStack(alignment: .leading, spacing: 10) {
                TextField("http://192.168.1.10:8787", text: $draftURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                SecureField("访问口令（服务端设了 ACCESS_TOKEN 才需要）", text: $draftToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 10) {
                    Button { save() } label: {
                        Text("保存")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Palette.accent)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)

                    Button { Task { await check() } } label: {
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
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.text)
                        .font(.system(size: 11))
                        .foregroundStyle(status.color)
                    Spacer()
                    Button("官网") { showAbout = true }
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textTertiary)
                }

                Divider().overlay(Palette.textTertiary.opacity(0.15)).padding(.vertical, 2)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("直连模式")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text(settings.directMode
                             ? "视频走 CDN，服务器只发密钥（省 146 倍带宽）"
                             : "视频经服务器转发（服务器上传 = 观看码率之和）")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $settings.directMode)
                        .labelsHidden()
                        .tint(Palette.accent)
                }

                Text("部署：node server/hongguo-server.mjs（默认 :8787）。同一局域网填内网 IP；公网建议 HTTPS + ACCESS_TOKEN。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Palette.surface.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func save() {
        settings.resolverBaseURL = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.resolverToken = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await check() }
    }

    private func check() async {
        let cfg = ResolverConfig(baseURL: draftURL, token: draftToken)
        guard cfg.isConfigured else {
            await MainActor.run { status = .failed("地址为空") }
            return
        }
        await MainActor.run { status = .checking }
        let ok = await HGServerClient(config: cfg).health()
        await MainActor.run { status = ok ? .ok : .failed("服务未响应") }
    }

    // MARK: 播放偏好

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("播放偏好", nil)

            VStack(spacing: 0) {
                toggleRow("自动播放下一集", "播完自动接上下一集", $settings.autoplayNext)
                Divider().overlay(Palette.textTertiary.opacity(0.15))
                toggleRow("记住播放进度", "下次从上次位置继续", $settings.rememberProgress)
                Divider().overlay(Palette.textTertiary.opacity(0.15))
                toggleRow("单集循环", "只重复播放当前这一集", $settings.loopEpisode)
            }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Palette.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: 关于 / 免责

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("其它", nil)
            VStack(spacing: 0) {
                Button { showAbout = true } label: {
                    row("使用说明", "接口部署与排错")
                }
                .buttonStyle(.plain)
                Divider().overlay(Palette.textTertiary.opacity(0.15))
                row("版本", Bundle.main.appVersion)
            }
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var disclaimer: some View {
        Text("本 App 仅用于个人学习与技术研究，内容版权归原权利人所有。请勿用于商业用途。")
            .font(.system(size: 10))
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var aboutSheet: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("部署解析服务")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Palette.textPrimary)
                        code("""
                        # 需要 Node.js 18+
                        node server/hongguo-server.mjs
                        # 默认监听 0.0.0.0:8787
                        """)
                        Text("带口令")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        code("""
                        ACCESS_TOKEN=your-secret \\
                          node server/hongguo-server.mjs
                        """)
                        Text("确认部署成功")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("浏览器打开 http://<服务器IP>:8787/ ，应看到 \"version\": \"5\"。")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                        Text("排错")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        Text("• 黑屏/无画面：检查 Info.plist 的 NSAllowsArbitraryLoadsForMedia\n• 卡住不动：看服务端日志有没有收到 Range 请求\n• 404：确认 URL 里 ? 没被编码成 %3F")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("使用说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showAbout = false }
                }
            }
        }
    }

    private func code(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.textSecondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeader(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
