import SwiftUI
import WebKit

/// Вход как в официальном клиенте: страница OAuth Яндекса возвращает токен на адрес
/// music-application://desktop/oauth. Пароль видит только страница Яндекса.
struct LoginScreen: View {
    @EnvironmentObject private var session: Session
    @State private var showWeb = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("Tune")
                .font(.system(size: 40, weight: .bold))
            Text("Яндекс Музыка без цензуры\nи с офлайн-библиотекой")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            if failed {
                Text("Войти не получилось. Попробуйте ещё раз.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                failed = false
                showWeb = true
            } label: {
                Text("Войти через Яндекс")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showWeb) {
            NavigationStack {
                LoginWeb { token in
                    showWeb = false
                    if let token {
                        session.login(token: token)
                    } else {
                        failed = true
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Вход в Яндекс")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { showWeb = false }
                    }
                }
            }
        }
    }
}

private struct LoginWeb: UIViewRepresentable {
    private static let clientId = "97fe03033fa34407ac9bcf91d5afed5b"
    private static let redirect = "music-application://desktop/oauth"

    let done: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(done: done)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .black
        var parts = URLComponents(string: "https://oauth.yandex.ru/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "display", value: "popup"),
            URLQueryItem(name: "scope", value: "music:content"),
            URLQueryItem(name: "scope", value: "music:read"),
            URLQueryItem(name: "scope", value: "music:write"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "state", value: context.coordinator.state),
            URLQueryItem(name: "origin", value: "music_desktop"),
            URLQueryItem(name: "language", value: "ru"),
        ]
        if let url = parts.url {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        private let done: (String?) -> Void
        private var finished = false

        init(done: @escaping (String?) -> Void) {
            self.done = done
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, url.scheme == "music-application" else { return .allow }
            if !finished {
                finished = true
                done(token(in: url.absoluteString))
            }
            return .cancel
        }

        /// Токен из адреса возврата. Чужой state — не наш ответ.
        private func token(in address: String) -> String? {
            guard let hash = address.firstIndex(of: "#") else { return nil }
            var values: [String: String] = [:]
            for pair in address[address.index(after: hash)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
            }
            guard values["state"] == state, let token = values["access_token"], !token.isEmpty else { return nil }
            return token
        }
    }
}
