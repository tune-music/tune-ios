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
        loading = true
        defer { loading = false }
        do {
            let fresh = try await API.shared.home()
            // Пустой ответ не стирает то, что уже показано.
            if !fresh.blocks.isEmpty || page.blocks.isEmpty { page = fresh }
            loaded = true
            failed = false
            if !Demo.on, !fresh.blocks.isEmpty {
                Task.detached(priority: .utility) { Storage.save(fresh, "home.json") }
            }
        } catch {
            if Task.isCancelled { return }
            failed = page.blocks.isEmpty
        }
    }
}

/// Главная: «Моя волна», волны по настроению, быстрый доступ к своему и полки Яндекса.
struct HomeScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.navigate) private var navigate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = HomeModel()
    @ObservedObject private var now = Player.shared.now
    @ObservedObject private var words = WaveWords.shared
    @State private var tuning = Demo.screen == "wave"
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
            VStack(alignment: .leading, spacing: 28) {
                WaveHero(tune: { tuning = true })
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
                if Settings.waveWheel {
                    WheelStrip(tune: { tuning = true })
                }
                if session.offline || model.failed || Settings.offlineMode {
                    offline
                }
                if !model.page.waves.isEmpty {
                    stations
                }
                quick
                    .id("quick")
                ForEach(Demo.screen == "skeleton" ? [] : model.page.blocks) { block in
                    Shelf(block.title, more: block.items.count > 3 ? { navigate(.block(block)) } : nil) {
                        ForEach(block.items) { item in
                            HomeCard(item: item)
                        }
                    }
                }
                if (model.loading && model.page.blocks.isEmpty) || Demo.screen == "skeleton" {
                    HomeSkeleton()
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: cardIdentity)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { proxy.scrollTo("quick", anchor: .top) }
        }
        }
        .overlay {
            Color.clear
                .topScrim(Theme.background)
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
        .task { await model.load() }
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
        .refreshable {
            // Отдельная задача: жест обновления отменяет свою, и запрос обрывался на полпути.
            await Task {
                await model.load(force: true)
                await session.refresh()
                await Updater.shared.check()
            }.value
        }
    }

    private func wordCard(for track: Track?) -> WordCard? {
        guard Settings.waveWords, let track else { return nil }
        if Demo.on {
            return WordCard(id: "demo", text: "Этот трек записали за одну ночь в домашней студии", big: "big", feedback: "neutral")
        }
        return player.isWave ? words.cards[track.id] : nil
    }

    /// Быстрый доступ: своё любимое в одно нажатие, не заходя в коллекцию.
    private var quick: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            QuickTile(title: "Мне нравится", symbol: "heart.fill", colors: SymbolCover.likes) { navigate(.likes) }
            QuickTile(title: "Скачанное", symbol: "arrow.down", colors: SymbolCover.downloads) { navigate(.downloads) }
            QuickTile(title: "История", symbol: "clock.arrow.circlepath", colors: SymbolCover.history) { navigate(.history) }
            ForEach(session.playlists.prefix(3)) { playlist in
                QuickTile(title: playlist.title, cover: playlist.cover) { navigate(.playlist(playlist)) }
            }
        }
        .padding(.horizontal, 16)
    }

    private var offline: some View {
        Button {
            navigate(.downloads)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Нет связи с Яндексом")
                        .font(.scaled(size: 16, weight: .semibold))
                    Text(downloads.entries.isEmpty ? "Скачанной музыки пока нет" : "Скачано: \(plural(downloads.entries.count, "трек", "трека", "треков"))")
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
                        player.tapWave(seeds: wave.seeds, name: wave.title)
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

/// Плитка быстрого доступа: обложка слева, название справа.
private struct QuickTile: View {
    let title: String
    var symbol: String?
    var colors: [Color] = []
    var cover: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    SymbolCover(symbol: symbol, colors: colors, size: 56, corner: 0)
                } else {
                    CoverView(uri: cover, size: 56, corner: 0)
                }
                Text(title)
                    .font(.scaled(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
            }
            .frame(height: 56)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
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

/// «Моя волна»: переливающееся пятно, кнопка запуска и настройка.
private struct WaveHero: View {
    let tune: () -> Void

    @EnvironmentObject private var player: Player
    @ObservedObject private var now = Player.shared.now
    @State private var moving = false

    private var active: Bool { now.from("radio", "user:onyourwave") }

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
        ZStack {
            blob
            VStack(spacing: 18) {
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
                }
                Text("Моя волна")
                    .font(.scaled(size: 36, weight: .bold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 12) {
                    Button {
                        player.tapWave()
                    } label: {
                        HStack(spacing: 8) {
                            PlayGlyph(playing: playing, size: 18)
                            Text(playing ? "Пауза" : "Слушать")
                                .font(.scaled(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 26)
                        .frame(height: 48)
                        .background(Theme.accent, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle())
                    Button(action: tune) {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                            Text(Player.waveSettings.isEmpty ? "Настроить" : "Настроено")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .glass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .onAppear { animate(playing) }
        .onChange(of: playing) { animate($0) }
    }

    /// Пятно движется, только пока волна играет: в покое оно не тратит заряд.
    private func animate(_ on: Bool) {
        if on && !ProcessInfo.processInfo.isLowPowerModeEnabled {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { moving = true }
        } else {
            withAnimation(.easeOut(duration: 0.8)) { moving = false }
        }
    }

    private var blob: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1, green: 0.78, blue: 0.18))
                .frame(width: 240, height: 240)
                .offset(x: moving ? -70 : 30, y: moving ? -10 : 40)
            Circle()
                .fill(Color(red: 1, green: 0.52, blue: 0.1))
                .frame(width: 210, height: 210)
                .offset(x: moving ? 70 : -40, y: moving ? 50 : -20)
            Circle()
                .fill(Color(red: 0.86, green: 0.34, blue: 0.08))
                .frame(width: 180, height: 180)
                .offset(x: moving ? 10 : -80, y: moving ? -70 : 60)
        }
        .opacity(0.7)
        .scaleEffect(moving ? 1.1 : 0.95)
        .blur(radius: 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Сверху пятно не обрезается: когда страницу тянут вниз, свечение уходит под часы плавно.
        .mask {
            Rectangle().padding(.top, -500)
        }
        .overlay {
            LinearGradient(colors: [.clear, .clear, Theme.background], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Настройка «Моей волны»: характер, настроение и язык, как в официальном клиенте.
struct WaveSettingsSheet: View {
    private static let groups: [(title: String, options: [(name: String, seed: String)])] = [
        ("По характеру", [("Любимое", "settingDiversity:favorite"), ("Незнакомое", "settingDiversity:discover"), ("Популярное", "settingDiversity:popular")]),
        ("Под настроение", [("Бодрое", "settingMoodEnergy:active"), ("Весёлое", "settingMoodEnergy:fun"), ("Спокойное", "settingMoodEnergy:calm"), ("Грустное", "settingMoodEnergy:sad")]),
        ("По языку", [("Русский", "settingLanguage:russian"), ("Иностранный", "settingLanguage:not-russian"), ("Без слов", "settingLanguage:without-words")]),
    ]

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
    private var seeds: [String] {
        if now.kind == "radio", let item = now.item, !item.isEmpty { return item.components(separatedBy: ",") }
        return ["user:onyourwave"]
    }

    var body: some View {
        let items = Demo.on ? Self.demo : wheel.items
        Group {
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            disc(item)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .padding(.vertical, -6)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: items.isEmpty)
        .onAppear { wheel.load(seeds: seeds) }
        .onChange(of: now.item) { _ in wheel.load(seeds: seeds) }
    }

    private func disc(_ item: WheelItem) -> some View {
        let playing: Bool = {
            if case .wave(let wave) = item.action { return now.kind == "radio" && now.item == wave.joined(separator: ",") }
            return false
        }()
        return Button {
            wheel.clicked(item)
            switch item.action {
            case .wave(let wave): Player.shared.tapWave(seeds: wave, name: item.title)
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
