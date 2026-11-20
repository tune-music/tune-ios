import SwiftUI
import UIKit

/// Проверка новой версии. AltStore и SideStore не показывают обновление приложению,
/// установленному из файла, поэтому Tune сам смотрит в свой источник и открывает установку.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Номер версии новее установленной; nil, если обновляться не на что.
    @Published private(set) var latest: String?
    /// Что изменилось в новой версии: из источника обновлений.
    @Published private(set) var notes = ""

    #if TUNE_DEV
    private static let source = Bundle.main.object(forInfoDictionaryKey: "TuneDevSourceURL") as? String ?? ""
    private static let bundleID = "dev.tune.music.dev"
    private var file: String?
    #else
    private static let source = "https://github.com/tune-music/tune-ios/releases/latest/download/altstore.json"
    private static let bundleID = "dev.tune.music"
    private var file: String? = "https://github.com/tune-music/tune-ios/releases/latest/download/Tune.ipa"
    #endif

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        if Demo.on, Demo.screen == "settings" {
            latest = "0.1.99"
            notes = Change.all.first.map { $0.items.map { "• " + $0 }.joined(separator: "\n") } ?? ""
        }
    }

    func check() async {
        guard !Demo.on, let url = URL(string: Self.source), url.scheme == "https" else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [[String: Any]],
              let app = apps.first(where: { $0["bundleIdentifier"] as? String == Self.bundleID }),
              let versions = app["versions"] as? [[String: Any]],
              let version = versions.first?["version"] as? String
        else { return }
        #if TUNE_DEV
        guard let download = versions.first?["downloadURL"] as? String,
              let downloadURL = URL(string: download), downloadURL.scheme == "https", downloadURL.host != nil else { return }
        file = download
        #endif
        // Сравнение по числам: 0.1.10 новее, чем 0.1.9.
        latest = version.compare(Self.current, options: .numeric) == .orderedDescending ? version : nil
        notes = versions.first?["localizedDescription"] as? String ?? ""
    }

    /// Открывает AltStore или SideStore сразу на установке свежего файла поверх текущего.
    func install(with scheme: String) {
        guard let file, let url = URL(string: "\(scheme)://install?url=\(file)") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened {
                Task { @MainActor in Player.shared.errorText = "Не удалось открыть установщик. Скачайте файл и откройте его в AltStore или SideStore." }
            }
        }
    }

    func download() {
        if let file, let url = URL(string: file) { UIApplication.shared.open(url) }
    }
}
