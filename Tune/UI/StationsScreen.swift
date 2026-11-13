import SwiftUI

/// Группа волн: жанры, настроения, занятия, эпохи.
struct StationGroup: Identifiable {
    let id: String
    let title: String
    var waves: [WaveCard]

    /// Порядок и названия групп, как в официальном клиенте.
    static let known: [(id: String, title: String)] = [
        ("genre", "Жанры"),
        ("mood", "Настроение"),
        ("activity", "Занятие"),
        ("epoch", "Эпоха"),
        ("local", "Местное"),
    ]
}

/// Все волны Яндекса, разложенные по группам.
struct StationsScreen: View {
    @State private var groups: [StationGroup] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        ScrollView {
            if groups.isEmpty {
                Group {
                    if loading {
                        TilesSkeleton(height: 48, count: 12)
                            .padding(.top, -60)
                    } else if failed {
                        Placeholder(icon: "wifi.slash", title: "Не удалось загрузить волны") {
                            Task { await load() }
                        }
                    } else {
                        Placeholder(icon: "dot.radiowaves.left.and.right", title: "Волн пока нет")
                    }
                }
                .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                            WaveGrid(waves: group.waves)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .navigationTitle("Все волны")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard groups.isEmpty else { return }
        loading = true
        failed = false
        do {
            groups = try await API.shared.stations()
        } catch {
            failed = true
        }
        loading = false
    }
}

/// Сетка волн в два столбца: нажатие запускает волну, играющая выделена.
struct WaveGrid: View {
    let waves: [WaveCard]
    @ObservedObject private var now = Player.shared.now

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(waves) { wave in
                let active = now.from("radio", wave.id)
                Button {
                    Player.shared.tapWave(seeds: wave.seeds, name: wave.title)
                } label: {
                    HStack(spacing: 8) {
                        if active {
                            Image(systemName: now.playing ? "waveform" : "pause.fill")
                                .font(.system(size: 13, weight: .bold))
                        }
                        Text(wave.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(active ? Color.black : Color.white)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(active ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}
