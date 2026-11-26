import AVFoundation
import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var page = HomePage()
    @Published var loading = false
    @Published var failed = false
    private var loaded = false

    init() {
        // Прошлая главная показывается сразу, свежая подменяет её, когда придёт.
        if !Demo.on, let saved = Storage.load("home.json", as: HomePage.self) {
            page = saved
        }
    }

    func load(force: Bool = false) async {
        if loaded && !force { return }
        if !loading { loading = true }
        defer { if loading { loading = false } }
        do {
            let fresh = try await API.shared.home()
            try Task.checkCancellation()
            // Пустой ответ не стирает то, что уже показано.
            if !fresh.blocks.isEmpty || page.blocks.isEmpty { page = fresh }
            loaded = true
            if failed { failed = false }
            if !Demo.on, !fresh.blocks.isEmpty {
                Task.detached(priority: .utility) { Storage.save(fresh, "home.json") }
            }
        } catch {
            if Task.isCancelled { return }
            failed = page.blocks.isEmpty
        }
    }

    func updateUploadedTrack(_ edited: Track) {
        guard let recent = page.recent, recent.contains(where: { $0.id == edited.id }) else { return }
        page.recent = recent.map {
            $0.id == edited.id ? $0.withUploadedMetadata(title: edited.title, artist: edited.artists) : $0
        }
        if !Demo.on, !page.blocks.isEmpty {
            let snapshot = page
            Task.detached(priority: .utility) { Storage.save(snapshot, "home.json") }
        }
    }
}

/// Главная: «Моя волна», волны по настроению, быстрый доступ к своему и полки Яндекса.
struct HomeScreen: View {
    @ObservedObject private var connectivity = Connectivity.shared
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @State private var downloadCount = Downloads.shared.entries.count
    @Environment(\.navigate) private var navigate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = HomeModel()
    @ObservedObject private var now = Player.shared.now
    @ObservedObject private var words = WaveWords.shared
    @State private var tuning = Demo.screen == "wave"
    @State private var waveSettings = Player.waveSettings
    @State private var trending = false
    /// Страница прокручена: под часами нужна дымка, иначе полки сливаются с ними.
    @State private var scrolled = false
    @State private var origin: CGFloat?
    @State private var lastWordCard: (card: WordCard, track: Track)?

    var body: some View {
        let track = player.current
        let card = wordCard(for: track)
        let activeCard = card.flatMap { card in track.map { (card: card, track: $0) } }
        let visibleCard = activeCard ?? (player.isWave && Settings.waveWords && !reduceMotion ? lastWordCard : nil)
        let cardIdentity = visibleCard.map { WordCardView.Identity(cardID: $0.card.id, trackID: $0.track.id) }
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if model.page.trends?.isEmpty == false {
                    Picker("Главная", selection: $trending) {
                        Text("Для вас").tag(false)
                        Text("Тренды").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                }
                if !trending {
                    WaveHero(settings: $waveSettings, waves: model.page.waves, tune: { tuning = true })
                        .zIndex(-1)
                    if let visibleCard, let cardIdentity {
                        ZStack {
                            WordCardView(card: visibleCard.card, track: visibleCard.track)
                                .id(cardIdentity)
                                .transition(.identity)
                        }
                        .opacity(activeCard == nil ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: activeCard == nil)
                        .allowsHitTesting(activeCard != nil)
                        .accessibilityHidden(activeCard == nil)
                        .transition(.opacity)
                    }
                    if connectivity.offline || session.offline || model.failed {
                        offline
                    }
                    Group {
                        if Settings.waveWheel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Волны")
                                        .font(.scaled(size: 22, weight: .bold))
                                        .foregroundStyle(Theme.text)
                                    Spacer(minLength: 8)
                                    Button {
                                        navigate(.stations)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Text("Все")
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Theme.dim)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                WheelStrip(tune: { tuning = true })
                            }
                        } else if !model.page.waves.isEmpty {
                            stations
                        }
                    }
                    .id("homeContent")
                    if let tracks = model.page.recent, !tracks.isEmpty {
                        recentShelf(tracks)
                    }
                }
                let blocks = trending ? model.page.trends ?? [] : model.page.blocks
                ForEach(Demo.screen == "skeleton" ? [] : blocks) { block in
                    homeShelf(block)
                }
                if (model.loading && model.page.blocks.isEmpty) || Demo.screen == "skeleton" {
                    HomeSkeleton()
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: cardIdentity)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .background(alignment: .top) {
                GeometryReader { geometry in
                    let top = geometry.frame(in: .global).minY
                    Color.clear
                        .onAppear { if origin == nil { origin = top } }
                        .onChange(of: top) { value in
                            let moved = value < (origin ?? value) - 16
                            if moved != scrolled { scrolled = moved }
                        }
                }
            }
        }
        .onAppear {
            // Снимок прокрученной главной: по нему проверяется читаемость верха.
            guard Demo.screen == "homescroll" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo("homeContent", anchor: .top) }
        }
        }
        .overlay {
            Color.clear
                .opacity(scrolled ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: scrolled)
                .allowsHitTesting(false)
        }
        .background(Theme.background)
        // Панель навигации пустая, но она есть: под ней прокрученные полки размываются
        // так же, как в поиске и коллекции.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                DevicesToolbarButton {
                    navigate(.devices)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    navigate(.settings)
                } label: {
                    Image(systemName: "person.crop.circle")
                        .accessibilityLabel("Аккаунт")
                }
                .accessibilityLabel("Настройки и аккаунт")
            }
        }
        .sheet(isPresented: $tuning) {
            WaveSettingsSheet()
        }
        .onChange(of: tuning) { open in
            if !open {
                withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84)) {
                    waveSettings = Player.waveSettings
                }
            }
        }
        .task { await model.load() }
        .onReceive(Downloads.shared.$entries.map(\.count).removeDuplicates()) { count in
            if downloadCount != count { downloadCount = count }
        }
        .onReceive(NotificationCenter.default.publisher(for: Session.uploadedTrackEdited)) { note in
            guard let edited = note.object as? Track else { return }
            model.updateUploadedTrack(edited)
        }
        .onChange(of: model.page.trends?.isEmpty ?? true) { empty in
            if empty { trending = false }
        }
        .task(id: card) {
            if let activeCard {
                lastWordCard = activeCard
            } else if player.isWave, Settings.waveWords, !reduceMotion, lastWordCard != nil {
                // Короткая пауза даёт карточке следующего трека прийти без скачка высоты.
                do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                lastWordCard = nil
            } else {
                lastWordCard = nil
            }
        }
        .screenRefresh {
            async let page: Void = model.load(force: true)
            async let wheel: Void = WaveWheel.shared.load(seeds: WheelStrip.seeds(for: now), force: true)
            async let profile: Void = session.refresh(interactive: true)
            _ = await (page, wheel, profile)
        }
    }

    private func recentShelf(_ tracks: [Track]) -> some View {
        Shelf("Вы недавно слушали", more: { navigate(.history) }) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    player.play(tracks, at: index, context: .various("История"))
                } label: {
                    CardView(title: track.fullTitle, subtitle: track.artists, cover: track.cover, size: 116)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func homeShelf(_ block: HomeBlock) -> some View {
        Shelf(block.title, more: block.items.count > 3 ? { navigate(.block(block)) } : nil) {
            ForEach(block.items) { item in
                HomeCard(item: item)
            }
        }
        .task(id: block.items) {
            guard !Demo.on, !Settings.offlineMode, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            let side = ImageLoader.side(for: 148)
            let covers = block.items.dropFirst(3).prefix(4).compactMap(\.coverURI)
            for cover in covers {
                if Task.isCancelled { return }
                _ = await ImageLoader.shared.load(cover, side: side)
            }
        }
    }

    private func wordCard(for track: Track?) -> WordCard? {
        guard Settings.waveWords, let track else { return nil }
        if Demo.on {
            return WordCard(id: "demo", text: "Этот трек записали за одну ночь в домашней студии", big: "big", feedback: "neutral")
        }
        return player.isWave ? words.cards[track.id] : nil
    }

    private var offline: some View {
        Button {
            navigate(.downloads)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Слушать скачанное")
                        .font(.scaled(size: 16, weight: .semibold))
                    Text(downloadCount == 0 ? "Скачанной музыки пока нет" : "Скачано: \(plural(downloadCount, "трек", "трека", "треков"))")
                        .font(.scaled(size: 14))
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .foregroundStyle(Theme.text)
            .padding(16)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    /// Волны по настроению и занятию: лента цветных капсул.
    private var stations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    navigate(.stations)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Все волны")
                            .font(.scaled(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 15)
                    .frame(height: 40)
                    .overlay(Capsule().strokeBorder(Theme.text.opacity(0.22)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                ForEach(model.page.waves) { wave in
                    let active = now.from("radio", wave.id)
                    Button {
                        player.tapWave(seeds: wave.seeds, name: wave.title, color: wave.color)
                    } label: {
                        HStack(spacing: 7) {
                            if active {
                                PlayingBars(playing: now.playing, size: 13, color: .black)
                            } else {
                                WaveDot(wave: wave)
                            }
                            Text(wave.title)
                                .font(.scaled(size: 15, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(active ? Color.black : Theme.text)
                        .padding(.horizontal, 15)
                        .frame(height: 40)
                        .background {
                            Capsule().fill(active ? Theme.accent : Theme.raised)
                        }
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.horizontal, 16)
            // Запас по высоте: кнопка под пальцем сжимается и не должна обрезаться краем ленты.
            .padding(.vertical, 6)
        }
        .padding(.vertical, -6)
    }
}

/// Кнопка устройств Ynison в верхней панели главной.
private struct DevicesToolbarButton: View {
    let action: () -> Void
    @ObservedObject private var sync = Ynison.shared

    private var activeRemote: Bool {
        sync.enabled && sync.connection == .connected && sync.state.active != nil && sync.state.active != sync.deviceID
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "hifispeaker.and.homepod")
                .foregroundStyle(activeRemote ? Theme.accentText : Theme.text)
                .accessibilityLabel("Устройства")
        }
    }
}

/// Заглушка полок, пока главная грузится в первый раз.
private struct HomeSkeleton: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: 170, height: 22)
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.surface)
                                .frame(width: 148, height: 148)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        // Заглушка шире экрана. Рамка с нулевой нижней границей не даёт ей растянуть всю
        // страницу вместе с плитками: без minWidth рамка подстраивалась под содержимое.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
    }
}

/// Системная громкость устройства (0...1), чтобы волна откликалась яркостью и размахом.
@MainActor
private final class DeviceVolume: ObservableObject {
    @Published private(set) var level: Double
    private var observation: NSKeyValueObservation?

    init() {
        let session = AVAudioSession.sharedInstance()
        level = Double(session.outputVolume)
        observation = session.observe(\.outputVolume, options: [.initial, .new]) { session, _ in
            let value = Double(session.outputVolume)
            Task { @MainActor [weak self] in
                guard let self, abs(self.level - value) > 0.005 else { return }
                self.level = value
            }
        }
    }

    func refresh() {
        let value = Double(AVAudioSession.sharedInstance().outputVolume)
        if abs(level - value) > 0.005 {
            level = value
        }
    }

    deinit {
        observation?.invalidate()
    }
}

/// «Моя волна»: органическое свечение с откликом на звук и громкость, кнопка запуска, настройка и съёмные фильтры.
private struct WaveHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme
    @Binding var settings: [String]
    let waves: [Wave]
    let tune: () -> Void

    @EnvironmentObject private var player: Player
    @ObservedObject private var now = Player.shared.now
    @ObservedObject private var wheel = WaveWheel.shared
    @StateObject private var volume = DeviceVolume()
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var active: Bool { now.from("radio", "user:onyourwave") }

    private var waveHex: String? {
        guard now.kind == "radio", let item = now.item, item != "user:onyourwave" else { return nil }
        if let color = now.color, !color.isEmpty { return color }
        if let wheelColor = wheel.items.first(where: {
            if case .wave(let seeds) = $0.action { return seeds.joined(separator: ",") == item }
            return false
        })?.color, !wheelColor.isEmpty {
            return wheelColor
        }
        if let stationColor = waves.first(where: { $0.id == item })?.color, !stationColor.isEmpty {
            return stationColor
        }
        return nil
    }

    private var waveKey: String {
        "\(now.kind):\(now.item ?? "")"
    }

    /// Подпись под названием: что играет, если это не сама «Моя волна».
    private var other: String? {
        guard !active, !now.name.isEmpty else { return nil }
        switch now.kind {
        case "radio": return now.name.hasPrefix("Волна") ? now.name : "Волна «\(now.name)»"
        case "album": return "Альбом «\(now.name)»"
        case "playlist": return "Плейлист «\(now.name)»"
        case "artist": return now.name
        default: return now.name
        }
    }

    var body: some View {
        let playing = active && now.playing
        VStack(spacing: 14) {
            if let other {
                HStack(spacing: 7) {
                    PlayingBars(playing: now.playing, size: 13)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accentText)
                    Text("Сейчас играет: \(other)")
                        .font(.scaled(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Text("Моя волна")
                .font(.scaled(size: 35, weight: .bold))
                .foregroundStyle(Theme.text)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.45) : .clear, radius: 12, y: 2)
            HStack(spacing: 12) {
                Button {
                    player.tapWave()
                } label: {
                    HStack(spacing: 8) {
                        PlayGlyph(playing: playing, size: 18)
                        ZStack {
                            Text("Слушать").opacity(0)
                            Text(playing ? "Пауза" : "Слушать")
                                .id(playing)
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                        .font(.scaled(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .frame(height: 48)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: playing)
                }
                .buttonStyle(PressStyle())
                Button(action: tune) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(settings.isEmpty ? Theme.text : Theme.accentText)
                        Text("Настроить")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .glass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
            }
            ZStack {
                if !settings.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(settings, id: \.self) { seed in
                            if let title = WaveSettingsSheet.label(for: seed) {
                                Button {
                                    removeFilter(seed)
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(title)
                                            .font(.scaled(size: 13, weight: .medium))
                                            .foregroundStyle(Theme.text)
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Theme.dim)
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Theme.raised, in: Capsule())
                                }
                                .buttonStyle(PressStyle(scale: 0.94))
                                .transition(.opacity.combined(with: .scale(scale: 0.86)))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.84), value: settings)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(height: 32)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: other)
        .frame(maxWidth: .infinity)
        .frame(height: 244)
        .background(alignment: .center) {
            WaveGlow(
                playing: now.playing,
                animated: phase == .active && !reduceMotion && !lowPower,
                volume: volume.level,
                waveHex: waveHex,
                waveKey: waveKey
            )
            .frame(height: 540)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .onChange(of: phase) { state in
            if state == .active { volume.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private func removeFilter(_ seed: String) {
        let next = settings.filter { $0 != seed }
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84)) {
            settings = next
        }
        Player.waveSettings = next
        if active { player.playWave() }
    }
}

private struct RGB {
    var r: Double
    var g: Double
    var b: Double

    func lerp(to target: RGB, factor: Double) -> RGB {
        RGB(
            r: r + (target.r - r) * factor,
            g: g + (target.g - g) * factor,
            b: b + (target.b - b) * factor
        )
    }

    var color: Color {
        Color(red: r, green: g, blue: b)
    }
}

private struct WavePalette {
    var primary: RGB
    var secondary: RGB
    var deep: RGB
    var highlight: RGB

    static let tuneDefault = WavePalette(
        primary: RGB(r: 1.0, g: 0.78, b: 0.18),
        secondary: RGB(r: 1.0, g: 0.50, b: 0.10),
        deep: RGB(r: 0.90, g: 0.24, b: 0.06),
        highlight: RGB(r: 1.0, g: 0.91, b: 0.58)
    )

    static let tuneLight = WavePalette(
        primary: RGB(r: 0.96, g: 0.62, b: 0.04),
        secondary: RGB(r: 0.95, g: 0.36, b: 0.04),
        deep: RGB(r: 0.84, g: 0.18, b: 0.04),
        highlight: RGB(r: 1.0, g: 0.74, b: 0.10)
    )

    func lerp(to target: WavePalette, factor: Double) -> WavePalette {
        WavePalette(
            primary: primary.lerp(to: target.primary, factor: factor),
            secondary: secondary.lerp(to: target.secondary, factor: factor),
            deep: deep.lerp(to: target.deep, factor: factor),
            highlight: highlight.lerp(to: target.highlight, factor: factor)
        )
    }

    static func from(hex: String?, light: Bool) -> WavePalette {
        guard let hex else { return light ? .tuneLight : .tuneDefault }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return light ? .tuneLight : .tuneDefault }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        let (h, s, v) = rgbToHsb(r: r, g: g, b: b)
        let sat = s < 0.08 ? s : max(s, light ? 0.80 : 0.72)
        let secSat = s < 0.08 ? s : max(s, light ? 0.84 : 0.78)
        let primary = hsbToRgb(h: h, s: sat, b: light ? min(max(v, 0.72), 0.86) : max(v, 0.88))
        let secondary = hsbToRgb(h: (h + 0.06).truncatingRemainder(dividingBy: 1.0), s: secSat, b: light ? min(max(v, 0.68), 0.80) : max(v, 0.82))
        let deep = hsbToRgb(h: (h + 0.95).truncatingRemainder(dividingBy: 1.0), s: min(1.0, s * 1.05 + 0.15), b: light ? max(0.48, v * 0.65) : max(0.55, v * 0.72))
        let highlight = hsbToRgb(h: h, s: light ? max(0.55, s * 0.75) : max(0.18, s * 0.38), b: light ? 0.92 : 1.0)
        return WavePalette(primary: primary, secondary: secondary, deep: deep, highlight: highlight)
    }

    private static func rgbToHsb(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        var h: Double = 0
        if delta > 0.0001 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC > 0 ? delta / maxC : 0
        return (h, s, maxC)
    }

    private static func hsbToRgb(h: Double, s: Double, b: Double) -> RGB {
        let c = b * s
        let hp = h * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        return RGB(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}

private final class WaveMotion {
    var phase: Double = 0
    var lastDate: Date?
    var energy: Double = 0.5
    var activity: Double = 0
    var audioLevel: Double = 0
    var audioBass: Double = 0
    var palette: WavePalette = .tuneDefault
    var lastWaveKey: String = ""
    var surge: Double = 0
}

private struct WaveGlow: View {
    let playing: Bool
    let animated: Bool
    let volume: Double
    let waveHex: String?
    let waveKey: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var motion = WaveMotion()

    private var targetEnergy: Double {
        pow(min(max(volume, 0), 1), 0.85)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animated)) { frame in
            let state = step(at: frame.date)
            Canvas { context, size in
                let isLight = colorScheme == .light
                let energy = state.energy
                let activity = state.activity
                let time = state.phase
                let volScale = 0.22 + 0.78 * energy
                let sonic = state.audioLevel * volScale * activity
                let kick = state.audioBass * volScale * activity
                let surge = state.surge
                let power = (0.24 + 0.34 * energy) + (0.22 + 0.32 * energy) * activity + 0.28 * sonic + 0.16 * surge
                let center = CGPoint(x: size.width * 0.5, y: size.height * 0.48)
                let maxSpread = min(size.width * 0.52, size.height * 0.42)

                let amber = state.palette.primary.color
                let tangerine = state.palette.secondary.color
                let vermilion = state.palette.deep.color
                let champagne = state.palette.highlight.color

                // 1. Дышащее атмосферное свечение без резких границ
                context.drawLayer { layer in
                    layer.blendMode = isLight ? .normal : .plusLighter
                    let speeds = [0.58, 0.37, 0.46]
                    let blobs = [amber, tangerine, vermilion]
                    for index in blobs.indices {
                        let angle = time * speeds[index] + Double(index) * 2.1
                        let orbitX = maxSpread * (0.20 + 0.14 * energy + 0.06 * sonic)
                        let orbitY = maxSpread * (0.10 + 0.08 * energy + 0.04 * kick)
                        let c = CGPoint(
                            x: center.x + CGFloat(cos(angle)) * orbitX,
                            y: center.y + CGFloat(sin(angle * 1.25)) * orbitY
                        )
                        let radius = maxSpread * CGFloat(0.72 + 0.18 * energy + 0.08 * kick + 0.06 * surge + 0.07 * sin(angle + 1.0))
                        let baseAlpha = (isLight ? 0.48 : 0.40) * power
                        let gradient = Gradient(stops: [
                            .init(color: blobs[index].opacity(baseAlpha), location: 0.0),
                            .init(color: blobs[index].opacity(baseAlpha * (isLight ? 0.72 : 0.62)), location: 0.28),
                            .init(color: blobs[index].opacity(baseAlpha * (isLight ? 0.34 : 0.24)), location: 0.58),
                            .init(color: blobs[index].opacity(baseAlpha * (isLight ? 0.09 : 0.05)), location: 0.82),
                            .init(color: .clear, location: 1.0),
                        ])
                        layer.fill(
                            Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(gradient, center: c, startRadius: 0, endRadius: radius)
                        )
                    }
                }

                // 2. Размытые органические контуры волны (полярные гармоники)
                context.drawLayer { layer in
                    layer.blendMode = isLight ? .normal : .plusLighter
                    layer.addFilter(.blur(radius: isLight ? 12 : 18))
                    let contours: [(rx: Double, ry: Double, speed: Double, offset: Double, color: Color, alpha: Double)] = [
                        (0.41, 0.20, 1.0, 0.0, amber, isLight ? 0.46 : 0.40),
                        (0.34, 0.16, -0.82, 1.9, tangerine, isLight ? 0.38 : 0.34),
                    ]
                    let amp = 0.04 + 0.05 * activity + 0.11 * kick + 0.06 * surge
                    for contour in contours {
                        let scale = 0.84 + 0.14 * energy + 0.10 * kick + 0.08 * surge
                        let rx = min(size.width * contour.rx, maxSpread * 1.12) * scale
                        let ry = min(size.height * contour.ry, maxSpread * 0.60) * scale
                        let path = organicLoop(
                            center: center,
                            rx: rx,
                            ry: ry,
                            time: time * contour.speed,
                            offset: contour.offset,
                            amp: amp
                        )
                        layer.fill(path, with: .color(contour.color.opacity(contour.alpha * (isLight ? 0.50 : 0.42) * power)))
                        layer.stroke(
                            path,
                            with: .color(contour.color.opacity(contour.alpha * power)),
                            style: StrokeStyle(lineWidth: 9 + 7 * CGFloat(energy) + 5 * CGFloat(kick), lineCap: .round, lineJoin: .round)
                        )
                    }
                }

                // 3. Шёлковые акустические нити с плавным затуханием к краям
                let ribbons: [(freq: Double, speed: Double, phase: Double, yBias: CGFloat, color: Color, width: CGFloat)] = [
                    (2.1, 1.55, 0.0, -8, champagne, 1.4),
                    (3.0, -1.15, 1.7, 4, amber, 1.2),
                    (1.5, 0.90, 3.3, 12, tangerine, 1.0),
                ]
                let ribbonAmp = CGFloat(4.5 + 4.5 * energy + 12.0 * sonic + 14.0 * kick + 8.0 * surge)
                let leftX = size.width * 0.06
                let rightX = size.width * 0.94
                let spanX = rightX - leftX

                for pass in 0..<2 {
                    let isGlowPass = pass == 0
                    context.drawLayer { layer in
                        layer.blendMode = isLight ? .normal : .plusLighter
                        if isGlowPass { layer.addFilter(.blur(radius: 3.0)) }
                        for ribbon in ribbons {
                            let path = silkWave(
                                leftX: leftX,
                                spanX: spanX,
                                baseY: center.y + ribbon.yBias,
                                amp: ribbonAmp,
                                freq: ribbon.freq,
                                time: time * ribbon.speed + ribbon.phase
                            )
                            let alpha = (isGlowPass ? (isLight ? 0.44 : 0.48) : (isLight ? 0.82 : 0.68)) * power
                            let centerColor = isLight ? ribbon.color : champagne
                            let gradient = Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: ribbon.color.opacity(alpha * 0.8), location: 0.22),
                                .init(color: centerColor.opacity(alpha), location: 0.50),
                                .init(color: ribbon.color.opacity(alpha * 0.8), location: 0.78),
                                .init(color: .clear, location: 1.0),
                            ])
                            layer.stroke(
                                path,
                                with: .linearGradient(gradient, startPoint: CGPoint(x: leftX, y: center.y), endPoint: CGPoint(x: rightX, y: center.y)),
                                style: StrokeStyle(lineWidth: ribbon.width * (isGlowPass ? 3.2 : (isLight ? 1.25 : 1.0)), lineCap: .round)
                            )
                        }
                    }
                }

                // 4. Мягкие тёплые искры вокруг центра
                context.drawLayer { layer in
                    layer.blendMode = isLight ? .normal : .plusLighter
                    let count = 10
                    for i in 0..<count {
                        let seed = Double(i) * 1.6180339
                        let angle = time * (0.28 + Double(i % 3) * 0.14) + seed * 3.1
                        let orbit = maxSpread * CGFloat(0.26 + Double(i % 5) * 0.11) * CGFloat(0.75 + 0.28 * energy + 0.12 * sonic)
                        let px = center.x + CGFloat(cos(angle)) * orbit * 1.08
                        let py = center.y + CGFloat(sin(angle * 1.3 + seed)) * orbit * 0.52
                        let pulse = 0.45 + 0.55 * sin(time * 1.9 + seed * 4.0)
                        let r = CGFloat(1.4 + Double(i % 3) * 0.7) * CGFloat(0.85 + 0.25 * energy + 0.25 * kick)
                        let sparkAlpha = (isLight ? 0.58 : 0.52) * power * pulse
                        let sparkColor = isLight ? (i % 2 == 0 ? amber : tangerine) : (i % 2 == 0 ? champagne : amber)
                        let glowR = r * 2.6
                        layer.fill(
                            Path(ellipseIn: CGRect(x: px - glowR, y: py - glowR, width: glowR * 2, height: glowR * 2)),
                            with: .radialGradient(
                                Gradient(colors: [sparkColor.opacity(sparkAlpha), .clear]),
                                center: CGPoint(x: px, y: py),
                                startRadius: 0,
                                endRadius: glowR
                            )
                        )
                    }
                }
            }
        }
        .onChange(of: animated) { enabled in
            if !enabled { motion.lastDate = nil }
        }
        .onDisappear {
            motion.lastDate = nil
        }
    }

    private func step(at date: Date) -> (phase: Double, energy: Double, activity: Double, audioLevel: Double, audioBass: Double, palette: WavePalette, surge: Double) {
        let targetAct = playing ? 1.0 : 0.0
        let targetEn = targetEnergy
        let targetPalette = WavePalette.from(hex: waveHex, light: colorScheme == .light)

        if motion.lastWaveKey != waveKey {
            if !motion.lastWaveKey.isEmpty {
                motion.surge = min(1.0, motion.surge + 0.5)
            }
            motion.lastWaveKey = waveKey
        }

        if animated {
            let dt = motion.lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.05) } ?? 0
            motion.lastDate = date
            if dt > 0 {
                motion.energy += (targetEn - motion.energy) * min(1, dt * 6.5)
                motion.activity += (targetAct - motion.activity) * min(1, dt * 3.2)
                motion.palette = motion.palette.lerp(to: targetPalette, factor: min(1, dt * 3.0))
                motion.surge *= exp(-dt * 2.6)

                let targetAudio: Double
                let targetBass: Double
                if playing {
                    let meter = Player.shared.audioMeter()
                    if meter.live {
                        targetAudio = meter.level
                        targetBass = meter.bass
                    } else {
                        let synth = 0.24 + 0.18 * sin(motion.phase * 2.4) + 0.12 * sin(motion.phase * 4.1 + 1.1)
                        let beat = pow(max(0, sin(motion.phase * 1.9)), 3.0)
                        targetAudio = min(1, max(0, synth))
                        targetBass = min(1, 0.12 + 0.24 * beat)
                    }
                } else {
                    targetAudio = 0
                    targetBass = 0
                }

                let levelRate = targetAudio > motion.audioLevel ? 18.0 : 6.5
                let bassRate = targetBass > motion.audioBass ? 22.0 : 7.5
                motion.audioLevel += (targetAudio - motion.audioLevel) * min(1, dt * levelRate)
                motion.audioBass += (targetBass - motion.audioBass) * min(1, dt * bassRate)

                let idleSpeed = 0.22 + 0.10 * motion.energy
                let activeSpeed = (0.35 + 0.85 * motion.energy + 0.75 * motion.audioLevel * (0.25 + 0.75 * motion.energy)) * motion.activity
                motion.phase += dt * (idleSpeed + activeSpeed)
            } else {
                motion.energy = targetEn
                motion.activity = targetAct
                motion.palette = targetPalette
            }
            return (motion.phase, motion.energy, motion.activity, motion.audioLevel, motion.audioBass, motion.palette, motion.surge)
        } else {
            motion.lastDate = nil
            motion.energy = targetEn
            motion.activity = targetAct
            motion.palette = targetPalette
            motion.audioLevel = 0
            motion.audioBass = 0
            motion.surge = 0
            return (motion.phase, targetEn, targetAct, 0, 0, targetPalette, 0)
        }
    }

    private func organicLoop(center: CGPoint, rx: CGFloat, ry: CGFloat, time: Double, offset: Double, amp: Double) -> Path {
        let steps = 48
        var pts: [CGPoint] = []
        pts.reserveCapacity(steps)
        for i in 0..<steps {
            let theta = (Double(i) / Double(steps)) * .pi * 2
            let wave = 0.45 * sin(2 * theta + time)
                + 0.35 * sin(3 * theta - 1.35 * time + offset)
                + 0.20 * sin(5 * theta + 2.1 * time)
            let scale = CGFloat(1.0 + amp * wave)
            pts.append(CGPoint(
                x: center.x + CGFloat(cos(theta)) * rx * scale,
                y: center.y + CGFloat(sin(theta)) * ry * scale
            ))
        }
        var path = Path()
        let start = CGPoint(x: (pts[steps - 1].x + pts[0].x) / 2, y: (pts[steps - 1].y + pts[0].y) / 2)
        path.move(to: start)
        for i in 0..<steps {
            let next = pts[(i + 1) % steps]
            let mid = CGPoint(x: (pts[i].x + next.x) / 2, y: (pts[i].y + next.y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.closeSubpath()
        return path
    }

    private func silkWave(leftX: CGFloat, spanX: CGFloat, baseY: CGFloat, amp: CGFloat, freq: Double, time: Double) -> Path {
        let steps = 64
        var path = Path()
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let env = sin(.pi * u)
            let window = env * env
            let yWave = sin(u * .pi * 2 * freq + time) * 0.65
                + sin(u * .pi * 2 * (freq * 1.7) - time * 1.3) * 0.35
            let x = leftX + spanX * CGFloat(u)
            let y = baseY + amp * CGFloat(window * yWave)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

/// Настройка «Моей волны»: характер, настроение и язык, как в официальном клиенте.
struct WaveSettingsSheet: View {
    private static let groups: [(title: String, options: [(name: String, seed: String)])] = [
        ("По характеру", [("Любимое", "settingDiversity:favorite"), ("Незнакомое", "settingDiversity:discover"), ("Популярное", "settingDiversity:popular")]),
        ("Под настроение", [("Бодрое", "settingMoodEnergy:active"), ("Весёлое", "settingMoodEnergy:fun"), ("Спокойное", "settingMoodEnergy:calm"), ("Грустное", "settingMoodEnergy:sad")]),
        ("По языку", [("Русский", "settingLanguage:russian"), ("Иностранный", "settingLanguage:not-russian"), ("Без слов", "settingLanguage:without-words")]),
    ]

    static func label(for seed: String) -> String? {
        for group in groups {
            if let option = group.options.first(where: { $0.seed == seed }) {
                return option.name
            }
        }
        return nil
    }

    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set(Player.waveSettings)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Self.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.scaled(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.text)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(group.options, id: \.seed) { option in
                                        chip(option.name, option.seed, in: group.options.map(\.seed))
                                    }
                                }
                            }
                        }
                    }
                    PlayButton(title: "Включить волну") {
                        Player.waveSettings = Self.groups.flatMap { $0.options.map(\.seed) }.filter { chosen.contains($0) }
                        player.playWave()
                        dismiss()
                    }
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .navigationTitle("Моя волна")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Сбросить") { chosen = [] }
                        .disabled(chosen.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .tint(Theme.text)
        .presentationDetents([.medium, .large])
    }

    /// В каждой группе выбран один вариант или ни одного.
    private func chip(_ name: String, _ seed: String, in group: [String]) -> some View {
        let on = chosen.contains(seed)
        return Button {
            let was = on
            group.forEach { chosen.remove($0) }
            if !was { chosen.insert(seed) }
        } label: {
            Text(name)
                .font(.scaled(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.black : Theme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(on ? Theme.accent : Theme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Колесо волны: подсказки волн по настроению, жанру и артистам к тому, что играет.
private struct WheelStrip: View {
    let tune: () -> Void

    @Environment(\.navigate) private var navigate
    @ObservedObject private var wheel = WaveWheel.shared
    @ObservedObject private var now = Player.shared.now

    /// Колесо строится к играющей волне, без неё — к «Моей волне».
    static func seeds(for now: NowPlaying) -> [String] {
        if now.kind == "radio", let item = now.item, !item.isEmpty { return item.components(separatedBy: ",") }
        return ["user:onyourwave"]
    }

    var body: some View {
        let items = Demo.on ? Self.demo : wheel.items.isEmpty ? Self.fallback : wheel.items
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items, id: \.scrollID) { item in
                    disc(item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .padding(.vertical, -6)
        .task {
            guard wheel.items.isEmpty else { return }
            await wheel.load(seeds: Self.seeds(for: now))
        }
    }

    private func disc(_ item: WheelItem) -> some View {
        let playing: Bool = {
            if case .wave(let wave) = item.action { return now.kind == "radio" && now.item == wave.joined(separator: ",") }
            return false
        }()
        return Button {
            wheel.clicked(item)
            switch item.action {
            case .wave(let wave): Player.shared.tapWave(seeds: wave, name: item.title, color: item.color)
            case .album(let id): navigate(.album(id))
            case .setting: tune()
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color(hex: item.color) ?? Theme.raised)
                    if let cover = item.cover {
                        CoverView(uri: cover, size: 84, round: true, backdrop: nil)
                    } else if item.action == .setting {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    if playing {
                        Circle().strokeBorder(Theme.accent, lineWidth: 3)
                        PlayingBadge(playing: now.playing, size: 34)
                    }
                }
                .frame(width: 84, height: 84)
                Text(item.title)
                    .font(.scaled(size: 13, weight: .medium))
                    .foregroundStyle(playing ? Theme.accentText : Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: 92)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
    }

    private static let fallback: [WheelItem] = [
        WheelItem(kind: "WAVE", id: "fallback:my-wave", action: .wave(["user:onyourwave"]),
                  title: "Моя волна", subtitle: "", cover: nil, color: "#E5A823"),
        WheelItem(kind: "SETTING", id: "fallback:settings", action: .setting,
                  title: "Настроить Мою волну", subtitle: "", cover: nil, color: "#3A3A3C"),
    ]

    private static let demo: [WheelItem] = [
        WheelItem(kind: "WAVE", id: "1", action: .wave(["mood:sad"]), title: "Прожить эту грусть", subtitle: "", cover: nil, color: "#00B2CC"),
        WheelItem(kind: "WAVE", id: "2", action: .wave(["activity:workout"]), title: "Для тренировки", subtitle: "", cover: nil, color: "#E5484D"),
        WheelItem(kind: "WAVE", id: "3", action: .wave(["genre:rock"]), title: "Рок", subtitle: "", cover: nil, color: "#7C5CFF"),
        WheelItem(kind: "SETTING", id: "4", action: .setting, title: "Настроить Мою волну", subtitle: "", cover: nil, color: "#3A3A3C"),
        WheelItem(kind: "WAVE", id: "5", action: .wave(["mood:calm"]), title: "Спокойное", subtitle: "", cover: nil, color: "#30A46C"),
    ]
}

/// «Слова в волне»: факт о звучащем треке, рассказ подробнее и оценка.
private struct WordCardView: View {
    struct Identity: Hashable {
        let cardID: String
        let trackID: String
    }

    let card: WordCard
    let track: Track

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var story: WordBig?
    @State private var loading = false

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.34)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .bold))
                    Text("Слова в волне")
                        .font(.scaled(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.accent.opacity(0.14), in: Capsule())
                Spacer()
                Text("ИИ")
                    .font(.scaled(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.bottom, 14)
            Text(card.text)
                .font(.scaled(size: 19, weight: .medium))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if card.big != nil {
                storyDisclosure
            }
            HStack(spacing: 8) {
                pill(card.feedback == "like" ? "heart.fill" : "heart", "Больше такого", card.feedback == "like") {
                    WaveWords.shared.rate(track, "like")
                }
                pill("hand.thumbsdown", "Мимо", card.feedback == "dislike") {
                    WaveWords.shared.rate(track, "dislike")
                }
                Spacer(minLength: 0)
                if card.big != nil {
                    more
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
        .task(id: loading) {
            if loading { await loadStory() }
        }
    }

    private var storyDisclosure: some View {
        WordStoryLayout(progress: expanded ? 1 : 0) {
            if let story {
                VStack(alignment: .leading, spacing: 10) {
                    Text(story.text)
                        .font(.scaled(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if let title = story.actionTitle, let url = story.actionURL {
                        Link(destination: url) {
                            HStack(spacing: 2) {
                                Text(title)
                                Image(systemName: "chevron.right")
                            }
                            .font(.scaled(size: 13, weight: .medium))
                            .foregroundStyle(Theme.accentText)
                        }
                    }
                }
                .padding(.top, 14)
                .transition(.identity)
            }
        }
        .clipped()
        .opacity(expanded ? 1 : 0)
        .allowsHitTesting(expanded)
        .accessibilityHidden(!expanded)
    }

    private var more: some View {
        Button {
            if story != nil {
                withAnimation(disclosureAnimation) { expanded.toggle() }
            } else {
                loading = true
            }
        } label: {
            if loading {
                let index = card.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % WaveWords.loading.count
                Text(WaveWords.loading[index] + "…")
                    .font(.scaled(size: 13))
                    .foregroundStyle(Theme.dim)
            } else if expanded {
                Text("Свернуть")
                    .font(.scaled(size: 13, weight: .medium))
                    .foregroundStyle(Theme.dim)
            } else {
                HStack(spacing: 2) {
                    Text("Подробнее")
                    Image(systemName: "chevron.right")
                }
                .font(.scaled(size: 13, weight: .medium))
                .foregroundStyle(Theme.accentText)
            }
        }
        .disabled(loading)
    }

    private func loadStory() async {
        do {
            let detail: WordBig?
            if Demo.on {
                detail = WordBig(
                    text: "Музыканты оставили в записи лёгкий шум комнаты. Его можно услышать в паузе перед последним припевом, когда стихают гитары.",
                    actionTitle: nil, actionURL: nil
                )
            } else {
                detail = try await WaveWords.shared.big(for: track)
            }
            guard !Task.isCancelled else { return }
            withAnimation(disclosureAnimation) {
                story = detail
                expanded = detail != nil
                loading = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            loading = false
            Session.shared.show("Яндекс не рассказал подробнее")
        }
    }

    private func pill(_ icon: String, _ title: String, _ active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.scaled(size: 13, weight: .medium))
            .foregroundStyle(active ? Color.black : Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(active ? Theme.accent : Theme.raised, in: Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.94))
    }
}

/// Текст остаётся на месте, пока меняется доступная для него высота.
private struct WordStoryLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let story = subviews.first else { return .zero }
        let size = story.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
