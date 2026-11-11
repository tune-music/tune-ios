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
    @StateObject private var model = HomeModel()
    @State private var tuning = Demo.screen == "wave"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                WaveHero(tune: { tuning = true })
                if session.offline || model.failed {
                    offline
                }
                if !model.page.waves.isEmpty {
                    stations
                }
                quick
                ForEach(model.page.blocks) { block in
                    Shelf(block.title, more: block.items.count > 3 ? { navigate(.block(block)) } : nil) {
                        ForEach(block.items) { item in
                            HomeCard(item: item)
                        }
                    }
                }
                if model.loading && model.page.blocks.isEmpty {
                    HomeSkeleton()
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            // Размытие под часами и островком: прокрученные полки уходят в него плавно.
            // Оно есть всегда: поверх волны его не видно, потому что она сама размыта.
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.35)
            }
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 112)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
        .sheet(isPresented: $tuning) {
            WaveSettingsSheet()
        }
        .task { await model.load() }
        .refreshable {
            // Отдельная задача: жест обновления отменяет свою, и запрос обрывался на полпути.
            await Task {
                await model.load(force: true)
                await session.refresh()
                await Updater.shared.check()
            }.value
        }
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
                        .font(.system(size: 16, weight: .semibold))
                    Text(downloads.entries.isEmpty ? "Скачанной музыки пока нет" : "Скачано: \(plural(downloads.entries.count, "трек", "трека", "треков"))")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .foregroundStyle(.white)
            .padding(16)
            .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    /// Волны по настроению и занятию: лента цветных плашек.
    private var stations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(model.page.waves) { wave in
                    Button {
                        player.playWave(seeds: wave.seeds, name: wave.title)
                    } label: {
                        Text(wave.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(width: 136, height: 44, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: (Color(hex: wave.color) ?? Theme.raised).opacity(0.55), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
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
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
    }
}

/// «Моя волна»: переливающееся пятно, кнопка запуска и настройка.
private struct WaveHero: View {
    let tune: () -> Void

    @EnvironmentObject private var player: Player
    @State private var moving = false

    private var active: Bool { player.isWave && player.contextName == "Моя волна" }

    var body: some View {
        let playing = active && player.isPlaying
        ZStack {
            blob
            VStack(spacing: 18) {
                Button {
                    if active {
                        player.toggle()
                    } else {
                        player.playWave()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                        Text("Моя волна")
                            .font(.system(size: 36, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: tune) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text(Player.waveSettings.isEmpty ? "Настроить" : "Настроено")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .glass(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 50)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 420)
        .onAppear { animate(playing) }
        .onChange(of: playing) { animate($0) }
    }

    /// Пятно движется, только пока волна играет: в покое оно не тратит заряд.
    private func animate(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { moving = true }
        } else {
            withAnimation(.easeOut(duration: 0.8)) { moving = false }
        }
    }

    private var blob: some View {
        ZStack {
            Circle()
                .fill(Color(red: 1, green: 0.32, blue: 0.2))
                .frame(width: 250, height: 250)
                .offset(x: moving ? -70 : 30, y: moving ? -10 : 40)
            Circle()
                .fill(Color(red: 0.98, green: 0.78, blue: 0.1))
                .frame(width: 220, height: 220)
                .offset(x: moving ? 70 : -40, y: moving ? 50 : -20)
            Circle()
                .fill(Color(red: 0.8, green: 0.18, blue: 0.6))
                .frame(width: 200, height: 200)
                .offset(x: moving ? 10 : -80, y: moving ? -70 : 60)
            Circle()
                .fill(Color(red: 0.25, green: 0.3, blue: 0.95))
                .frame(width: 170, height: 170)
                .offset(x: moving ? -40 : 90, y: moving ? 80 : -50)
        }
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
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
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
        .tint(.white)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(on ? Theme.accent : Theme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
