import SwiftUI
import WebKit

struct HumanChallengeView: View {
    let challenge: AloAppModel.HumanChallenge
    let onToken: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Проверка действия")
                            .font(.title2.bold())
                            .foregroundStyle(AloTheme.text)
                        Text(challenge.message)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AloTheme.muted)
                    }
                    Spacer()
                    AloIconButton(systemName: "xmark", action: onClose)
                }
                TurnstileWebView(url: challenge.url, onToken: onToken)
                    .frame(height: 240)
                    .background(AloTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(18)
            .aloCard(radius: 30)
            .padding(18)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct TurnstileWebView: UIViewRepresentable {
    let url: URL
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "aloTurnstile")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.backgroundColor = .clear
        webView.isOpaque = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onToken: (String) -> Void

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let token = message.body as? String, !token.isEmpty {
                onToken(token)
            }
        }
    }
}
