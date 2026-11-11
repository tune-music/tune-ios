import SwiftUI
import UIKit

/// Проверка новой версии. AltStore и SideStore не показывают обновление приложению,
/// установленному из файла, поэтому Tune сам смотрит в свой источник и открывает установку.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Номер версии новее установленной; nil, если обновляться не на что.
    @Published private(set) var latest: String?

    private static let source = "https://github.com/tune-music/tune-ios/releases/latest/download/altstore.json"
    static let file = "https://github.com/tune-music/tune-ios/releases/latest/download/Tune.ipa"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        if Demo.on, Demo.screen == "settings" { latest = "0.1.99" }
    }

    func check() async {
        guard !Demo.on, let url = URL(string: Self.source) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [[String: Any]],
              let versions = apps.first?["versions"] as? [[String: Any]],
              let version = versions.first?["version"] as? String
        else { return }
        // Сравнение по числам: 0.1.10 новее, чем 0.1.9.
        latest = version.compare(Self.current, options: .numeric) == .orderedDescending ? version : nil
    }

    /// Открывает AltStore или SideStore сразу на установке свежего файла поверх текущего.
    func install(with scheme: String) {
        guard let url = URL(string: "\(scheme)://install?url=\(Self.file)") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened {
                Task { @MainActor in Player.shared.errorText = "Не удалось открыть установщик. Скачайте файл и откройте его в AltStore или SideStore." }
            }
        }
    }

    func download() {
        if let url = URL(string: Self.file) { UIApplication.shared.open(url) }
    }
}
