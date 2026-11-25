import SwiftUI

/// Статистика прослушиваний. Копится на устройстве: Яндекс такую не отдаёт.
@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()

    struct Play: Codable {
        var id: String
        var seconds: Double
        var date: Date
        var waveAccount: String? = nil
    }

    private struct Saved: Codable {
        var plays: [Play]
        var tracks: [String: Track]
    }

    @Published private(set) var plays: [Play] = []
    private(set) var tracks: [String: Track] = [:]

    private init() {
        if Demo.on {
            // Для снимков экрана: чем ближе трек к началу списка, тем чаще он «звучал».
            let sample = Demo.data.tracks
            for (index, track) in sample.enumerated() {
                tracks[track.id] = track
                for turn in 0..<max(1, sample.count - index) {
                    plays.append(Play(id: track.id, seconds: track.duration, date: Date().addingTimeInterval(-Double(turn * 7200 + index * 600))))
                }
            }
            return
        }
        if let saved = Storage.load("stats.json", as: Saved.self) {
            plays = saved.plays
            tracks = saved.tracks
        }
    }

    /// Запоминает прослушивание. Короткие включения не считаются: трек просто пролистали.
    func add(_ track: Track, seconds: Double, waveAccount: String? = nil) {
        guard !Demo.on, seconds >= 20 else { return }
        tracks[track.id] = track
        plays.append(Play(id: track.id, seconds: min(seconds, max(track.duration, seconds)), date: Date(),
                          waveAccount: waveAccount.map(Storage.hash)))
        if plays.count > 20_000 {
            plays.removeFirst(plays.count - 20_000)
            let alive = Set(plays.map(\.id))
            tracks = tracks.filter { alive.contains($0.key) }
        }
        let snapshot = Saved(plays: plays, tracks: tracks)
        Task.detached(priority: .utility) { Storage.save(snapshot, "stats.json") }
    }

    func recentRestoredWaveTracks(account: String) -> [Track] {
        let key = Storage.hash(account)
        var seen = Set<String>()
        return plays.reversed().compactMap { play in
            guard play.waveAccount == key, seen.insert(play.id).inserted,
                  let track = tracks[play.id], track.uncensored, track.yandexAvailable == false else { return nil }
            return track
        }
    }

    func clear() {
        plays = []
        tracks = [:]
        Storage.remove("stats.json")
    }

    struct TopTrack: Identifiable {
        let track: Track
        let count: Int
        var id: String { track.id }
    }

    struct TopArtist: Identifiable {
        let artist: ArtistRef
        let cover: String?
        let count: Int
        var id: String { artist.id.isEmpty ? artist.name : artist.id }
    }

    struct Summary {
        var seconds: Double = 0
        var count = 0
        var tracks: [TopTrack] = []
        var artists: [TopArtist] = []
    }

    /// Итоги за последние `days` дней, а без срока — за всё время.
    func summary(days: Int?) -> Summary {
        let since = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        var result = Summary()
        var perTrack: [String: Int] = [:]
        for play in plays where since == nil || play.date >= since! {
            result.seconds += play.seconds
            result.count += 1
            perTrack[play.id, default: 0] += 1
        }
        let ranked = perTrack.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var perArtist: [String: (artist: ArtistRef, soloCover: String?, anyCover: String?, count: Int)] = [:]
        for (id, count) in ranked {
            guard let track = tracks[id] else { continue }
            if result.tracks.count < 20 { result.tracks.append(TopTrack(track: track, count: count)) }
            let solo = track.artistList.count == 1
            for artist in track.artistList {
                let key = artist.id.isEmpty ? artist.name : artist.id
                let known = perArtist[key]
                perArtist[key] = (
                    artist: artist,
                    soloCover: known?.soloCover ?? (solo ? track.cover : nil),
                    anyCover: known?.anyCover ?? track.cover,
                    count: (known?.count ?? 0) + count
                )
            }
        }
        let mapped: [TopArtist] = perArtist.values.map {
            TopArtist(artist: $0.artist, cover: $0.soloCover ?? $0.anyCover, count: $0.count)
        }
        let sorted = mapped.sorted { $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count }
        result.artists = Array(sorted.prefix(12))
        return result
    }
}

/// Экран статистики: сколько слушали, любимые треки и исполнители.
struct StatsScreen: View {
    @ObservedObject private var stats = Stats.shared
    @EnvironmentObject private var player: Player
    @Environment(\.navigate) private var navigate
    @State private var days: Int? = 30
    @State private var confirmClear = false
    @State private var artistCovers: [String: String] = [:]

    var body: some View {
        let data = stats.summary(days: days)
        let top = data.tracks.map(\.track)
        List {
            Picker("Срок", selection: $days) {
                Text("7 дней").tag(Int?.some(7))
                Text("30 дней").tag(Int?.some(30))
                Text("Всё время").tag(Int?.none)
            }
            .pickerStyle(.segmented)
            .plain(top: 8, bottom: 12)

            if data.count == 0 {
                Placeholder(icon: "chart.bar", title: "Пока нечего показать", text: "Статистика копится на этом устройстве: послушайте что-нибудь, и здесь появятся любимые треки и исполнители.")
            } else {
                HStack(spacing: 10) {
                    tile(length(data.seconds), "слушали")
                    tile("\(data.count)", plural(data.count, "прослушивание", "прослушивания", "прослушиваний").components(separatedBy: " ").last ?? "")
                    tile("\(data.artists.count)\(data.artists.count == 12 ? "+" : "")", "исполнителей")
                }
                .plain(top: 0, bottom: 18)

                Text("Любимые треки")
                    .font(.scaled(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .plain(top: 0, bottom: 6)
                ForEach(Array(data.tracks.enumerated()), id: \.element.id) { index, item in
                    TrackRow(track: item.track, number: index + 1, badge: "\(item.count)×") {
                        player.play(top, at: index, context: .various("Любимые треки"))
                    }
                }

                Text("Любимые исполнители")
                    .font(.scaled(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .plain(top: 22, bottom: 10)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(data.artists) { item in
                            Button {
                                if !item.artist.id.isEmpty { navigate(.artist(item.artist.id, item.artist.name)) }
                            } label: {
                                CardView(title: item.artist.name, subtitle: plural(item.count, "раз", "раза", "раз"), cover: artistCovers[item.artist.id] ?? item.cover, round: true, size: 112)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 24, trailing: 0))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(stats.plays.isEmpty)
            }
        }
        .alert("Очистить статистику?", isPresented: $confirmClear) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить", role: .destructive) { stats.clear() }
        } message: {
            Text("Она хранится только на этом устройстве, вернуть её не получится.")
        }
        .task(id: data.artists.map(\.artist.id)) {
            await loadArtistCovers(for: data.artists)
        }
    }

    private func loadArtistCovers(for artists: [Stats.TopArtist]) async {
        if artistCovers.isEmpty, !Demo.on {
            let saved = await Task.detached(priority: .userInitiated) { Storage.load("artist-covers.json", as: [String: String].self) }.value
            if let saved {
                for (id, cover) in saved where artistCovers[id] == nil { artistCovers[id] = cover }
            }
        }
        let ids = artists.map(\.artist.id).filter { !$0.isEmpty && artistCovers[$0] == nil }
        guard !ids.isEmpty, !Connectivity.shared.offline else { return }
        let fetched = await withTaskGroup(of: (String, String)?.self) { group in
            for id in ids {
                group.addTask {
                    guard let cover = try? await API.shared.artistCover(id: id), !cover.isEmpty else { return nil }
                    return (id, cover)
                }
            }
            var loaded: [String: String] = [:]
            for await pair in group {
                if let pair { loaded[pair.0] = pair.1 }
            }
            return loaded
        }
        guard !Task.isCancelled, !fetched.isEmpty else { return }
        artistCovers.merge(fetched) { _, new in new }
        if !Demo.on {
            let snapshot = artistCovers
            Task.detached(priority: .utility) { Storage.save(snapshot, "artist-covers.json") }
        }
    }

    private func tile(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.scaled(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.scaled(size: 13))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// «47 мин», «12 ч 5 мин».
    private func length(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
    }
}

private extension View {
    /// Строка списка без фона и разделителя, с полями страницы.
    func plain(top: CGFloat, bottom: CGFloat) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }
}
