import AppIntents

@available(iOS 17.0, *)
struct ToggleTunePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Пауза или продолжить в Tune"

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !TUNE_WIDGET_EXTENSION
        Player.shared.toggle()
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextTuneTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Следующий трек в Tune"

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !TUNE_WIDGET_EXTENSION
        Player.shared.next()
        #endif
        return .result()
    }
}
