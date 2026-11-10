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

/// Главная: «Моя волна», волны по настроению и полки, как у Яндекс Музыки.
struct HomeScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @Environment(\.navigate) private var navigate
    @StateObject private var model = HomeModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                WaveHero()
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
                } else if model.failed {
                    Placeholder(icon: "wifi.slash", title: "Нет сети", text: "Скачанная музыка доступна в «Коллекции».") {
                        Task { await model.load(force: true) }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topLeading) {
            Button {
                navigate(.settings)
            } label: {
                Text(String((session.profile?.name ?? "T").prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 4)
        }
        .task { await model.load() }
        .refreshable {
            await model.load(force: true)
            await session.refresh()
        }
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
                            .background((Color(hex: wave.color) ?? Theme.raised).opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// «Моя волна»: переливающееся пятно и большая кнопка запуска.
private struct WaveHero: View {
    @EnvironmentObject private var player: Player
    @State private var moving = false

    private var active: Bool { player.isWave && player.contextName == "Моя волна" }

    var body: some View {
        let playing = active && player.isPlaying
        Button {
            if active {
                player.toggle()
            } else {
                player.playWave()
            }
        } label: {
            ZStack {
                blob
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                        Text("Моя волна")
                            .font(.system(size: 36, weight: .bold))
                    }
                    Text(playing ? "Играет" : "Музыка под ваш вкус")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 400)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
