import SwiftUI

@MainActor
final class HomeModel: ObservableObject {
    @Published var page = HomePage()
    @Published var loading = false
    @Published var failed = false
    private var loaded = false

    func load(force: Bool = false) async {
        if loaded && !force { return }
        loading = true
        defer { loading = false }
        do {
            page = try await API.shared.home()
            loaded = true
            failed = false
        } catch {
            if Task.isCancelled { return }
            failed = page.blocks.isEmpty
        }
    }
}

private struct OffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Главная: «Моя волна», волны по настроению и полки, как у Яндекс Музыки.
struct HomeScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.navigate) private var navigate
    @StateObject private var model = HomeModel()
    @State private var scrolled = false
    @State private var tuning = Demo.screen == "wave"

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                GeometryReader { geometry in
                    Color.clear.preference(key: OffsetKey.self, value: geometry.frame(in: .named("home")).minY)
                }
                .frame(height: 0)
                WaveHero(tune: { tuning = true })
                    .padding(.top, -30)
                if session.offline || model.failed {
                    offline
                }
                if !model.page.waves.isEmpty {
                    stations
                }
                ForEach(model.page.blocks) { block in
                    Shelf(block.title) {
                        ForEach(block.items) { item in
                            HomeCard(item: item)
                        }
                    }
                }
                if model.loading && model.page.blocks.isEmpty {
                    Spinner()
                }
            }
            .padding(.bottom, 24)
        }
        .coordinateSpace(name: "home")
        .onPreferenceChange(OffsetKey.self) { offset in
            let now = offset < -40
            if now != scrolled { scrolled = now }
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            // Тёмная дымка под часами и островком: появляется, когда страница прокручена.
            LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
                .ignoresSafeArea(edges: .top)
                .opacity(scrolled ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: scrolled)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Button {
                navigate(.settings)
            } label: {
                Text(String((session.profile?.name ?? "T").prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .glass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 4)
        }
        .sheet(isPresented: $tuning) {
            WaveSettingsSheet()
        }
        .task { await model.load() }
        .refreshable {
            await model.load(force: true)
            await session.refresh()
        }
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
        .clipped()
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
