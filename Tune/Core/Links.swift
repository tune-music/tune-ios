import AppIntents
import SwiftUI

/// Ссылки на музыку: адреса music.yandex.ru и свои `tune://album/123`.
@MainActor
enum Links {
    /// Что открыть по ссылке. Трек не просто находится, а сразу начинает играть.
    enum Target {
        case album(String)
        case artist(String)
        case playlist(owner: String, kind: String)
        case track(String)
    }

    /// Ссылка на Яндекс Музыку в тексте: её вставляют в поиск.
    static func url(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") || trimmed.hasPrefix("tune://"), !trimmed.contains(" "), let url = URL(string: trimmed) else { return nil }
        return target(of: url) == nil ? nil : url
    }

    static func target(of url: URL) -> Target? {
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "tune" {
            // В своих адресах первое слово стоит на месте сервера: tune://album/123.
            if let host = url.host { parts.insert(host, at: 0) }
        } else {
            guard let host = url.host, host.contains("music.yandex") else { return nil }
        }
        func value(after name: String) -> String? {
            guard let index = parts.firstIndex(of: name), parts.indices.contains(index + 1) else { return nil }
            return parts[index + 1]
        }
        if let track = value(after: "track") { return .track(track) }
        if let album = value(after: "album") { return .album(album) }
        if let artist = value(after: "artist") { return .artist(artist) }
        if let owner = value(after: "users"), let kind = value(after: "playlists") { return .playlist(owner: owner, kind: kind) }
        return nil
    }

    /// Открывает ссылку: возвращает страницу, на которую надо перейти.
    static func route(for url: URL) async -> Route? {
        guard let target = target(of: url) else { return nil }
        switch target {
        case .album(let id):
            return .album(id)
        case .artist(let id):
            return .artist(id, "")
        case .playlist(let owner, let kind):
            return .playlist(Playlist(owner: owner, kind: kind, title: "", count: 0, cover: nil))
        case .track(let id):
            guard let track = try? await API.shared.tracks(ids: [id]).first else {
                Session.shared.show("Трек по ссылке не найден")
                return nil
            }
            Player.shared.play([track], context: .various(track.title))
            return track.albumId.map { .album($0) }
        }
    }

    /// Ссылка пришла извне: открывает её на вкладке «Главная».
    static func open(_ url: URL) {
        Task {
            guard let route = await route(for: url) else { return }
            PlayerWindow.shared.hide()
            Router.shared.tab = 0
            Router.shared.push(route)
        }
    }
}

// MARK: - Команды для Siri и «Быстрых команд»

struct PlayWaveIntent: AppIntent {
    static let title: LocalizedStringResource = "Включить Мою волну"
    static let description = IntentDescription("Запускает «Мою волну» в Tune.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Player.shared.playWave()
        return .result()
    }
}

struct TogglePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Пауза или продолжить"
    static let description = IntentDescription("Ставит музыку в Tune на паузу или продолжает её.")

    @MainActor
    func perform() async throws -> some IntentResult {
        Player.shared.toggle()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Следующий трек"
    static let description = IntentDescription("Переключает Tune на следующий трек.")

    @MainActor
    func perform() async throws -> some IntentResult {
        Player.shared.next()
        return .result()
    }
}

struct TuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayWaveIntent(),
            phrases: ["Включи волну в \(.applicationName)", "Моя волна в \(.applicationName)"],
            shortTitle: "Моя волна",
            systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: ["Пауза в \(.applicationName)", "Продолжи в \(.applicationName)"],
            shortTitle: "Пауза или продолжить",
            systemImageName: "playpause.fill")
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: ["Следующий трек в \(.applicationName)"],
            shortTitle: "Следующий трек",
            systemImageName: "forward.fill")
    }
}
