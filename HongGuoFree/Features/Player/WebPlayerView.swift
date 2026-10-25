// 红果网页播放器封装（WKWebView）
//
// 为什么用网页播放器而不是原生 AVPlayer：
// 红果的视频是 CENC 加密的 DASH 分片，解密依赖它自己的播放器 SDK，
// 原生 AVPlayer 拿不到解密密钥。用官方网页播放器既不需要破解 DRM，
// 又天然没有广告（网页版本身就没有开屏/中插广告）。
import SwiftUI
import WebKit

struct WebPlayerView: UIViewRepresentable {
    let url: URL
    var onClose: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true

        // 伪装成手机浏览器，拿到移动版布局
        let userScript = WKUserScript(
            source: """
            Object.defineProperty(navigator, 'userAgent', {
              get: function () { return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'; }
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = true
        webView.customUserAgent = HongGuoClient.webUA

        var request = URLRequest(url: url)
        request.setValue(HongGuoClient.webUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://hongguoduanju.com/", forHTTPHeaderField: "Referer")
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 地址变化时重新加载
        if uiView.url != url, !uiView.isLoading {
            var request = URLRequest(url: url)
            request.setValue(HongGuoClient.webUA, forHTTPHeaderField: "User-Agent")
            uiView.load(request)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 隐藏网页自带的顶部导航，只留播放器
            let js = """
            (function(){
              var style = document.createElement('style');
              style.textContent = `
                header, nav, [class*="header"], [class*="Header"],
                [class*="footer"], [class*="Footer"],
                [class*="download"], [class*="Download"],
                [class*="app-guide"], [class*="launch-app"] { display: none !important; }
                body { background: #000 !important; }
              `;
              document.head.appendChild(style);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}
    }
}

/// 播放页（红果网页播放器模式）
struct HongGuoWebPlayerScreen: View {
    let url: URL
    let title: String
    let episodeTitle: String
    var onNext: (() -> Void)? = nil
    var onSelectEpisode: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WebPlayerView(url: url)
                .ignoresSafeArea(edges: .horizontal)

            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(episodeTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    Spacer()

                    if let onSelectEpisode {
                        Button {
                            onSelectEpisode()
                        } label: {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}
