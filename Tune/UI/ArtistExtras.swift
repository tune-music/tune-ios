import AVKit
import Combine
import SwiftUI

struct ArtistExtras: View {
    let clips: [ArtistClip]
    let concerts: [ArtistConcert]
    @State private var watching: ArtistClip?

    var body: some View {
        if !clips.isEmpty {
            Shelf("Клипы") {
                ForEach(clips) { clip in
                    Button { watching = clip } label: {
                        CardView(title: clip.title, subtitle: "Смотреть", cover: clip.cover)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 12, trailing: 0))
            .sheet(item: $watching) { ClipPlayerSheet(clip: $0) }
        }
        if !concerts.isEmpty {
            Section {
                ForEach(concerts) { concert in
                    ConcertRow(concert: concert)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("Концерты")
                    .font(.scaled(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .textCase(nil)
            }
        }
    }
}

struct ConcertRow: View {
    let concert: ArtistConcert

    var body: some View {
        HStack(spacing: 12) {
            CoverView(uri: concert.cover, size: 56, corner: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(concert.title)
                    .font(.scaled(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                let place = [concert.city, concert.venue].filter { !$0.isEmpty }.joined(separator: " · ")
                if !place.isEmpty { Text(place).foregroundStyle(Theme.dim) }
                if let date = concertDate(concert.date) { Text(date).foregroundStyle(Theme.dim) }
            }
            .font(.scaled(size: 14))
            Spacer(minLength: 0)
            if let url = concert.tickets {
                Link("Билеты", destination: url)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accentText)
            }
        }
    }

    private func concertDate(_ raw: String) -> String? {
        let parts = raw.split(separator: "T", maxSplits: 1)
        guard let day = parts.first, day.count == 10 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(day)) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("dd MMMM yyyy")
        let time = parts.count > 1 ? String(parts[1].prefix(5)) : ""
        return time.isEmpty ? formatter.string(from: date) : "\(formatter.string(from: date)) · \(time)"
    }
}

struct ConcertsScreen: View {
    @State private var city: String?
    @State private var cities: [ConcertCity] = []
    @State private var concerts: [ArtistConcert]?
    @State private var error: String?
    @State private var retry = 0
    @AppStorage("concertCity") private var savedCity = ""

    var body: some View {
        List {
            if let concerts, !concerts.isEmpty {
                ForEach(concerts) { concert in
                    ConcertRow(concert: concert)
                        .listRowBackground(Color.clear)
                }
            } else if let error {
                Placeholder(icon: "wifi.slash", title: "Не удалось загрузить концерты", text: error) { retry += 1 }
            } else if concerts != nil {
                Placeholder(icon: "calendar", title: "Нет предстоящих концертов")
            } else {
                RowsSkeleton(count: 6)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Концерты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Город", selection: $savedCity) {
                        Text("Рядом").tag("")
                        ForEach(cities) { city in Text(city.name).tag(city.id) }
                    }
                } label: {
                    Label(cities.first { $0.id == savedCity }?.name ?? "Рядом", systemImage: "location")
                }
            }
        }
        .task {
            if let found = try? await API.shared.concertCities(), !Task.isCancelled { cities = found }
        }
        .task(id: "\(savedCity)#\(retry)") { await load(city: savedCity) }
        .refreshable { await load(city: savedCity) }
    }

    private func load(city requested: String) async {
        if requested != city { concerts = nil }
        city = requested
        error = nil
        do {
            let found = try await API.shared.concerts(city: requested.isEmpty ? nil : requested)
            guard !Task.isCancelled, requested == savedCity else { return }
            concerts = found
        } catch {
            guard !Task.isCancelled, requested == savedCity else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct ClipPlayerSheet: View {
    let clip: ArtistClip
    @Environment(\.dismiss) private var dismiss
    @State private var video: AVPlayer?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let video, let item = video.currentItem {
                    VideoPlayer(player: video)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onReceive(item.publisher(for: \.status)) { status in
                            if status == .failed { error = "Не удалось воспроизвести видео" }
                        }
                } else if error == nil {
                    ProgressView("Загружаем клип")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error {
                    Text(error).multilineTextAlignment(.center)
                    Button("Повторить") { retry += 1 }
                }
                Link("Открыть у Яндекса", destination: clip.url)
                    .padding(.bottom, 16)
            }
            .padding(.top, 12)
            .navigationTitle(clip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .task(id: retry) {
            video?.pause()
            video = nil
            error = nil
            do {
                let url = try await API.shared.clipStream(clip)
                try Task.checkCancellation()
                if Player.shared.isPlaying { Player.shared.pause() }
                let player = AVPlayer(url: url)
                video = player
                player.play()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onDisappear { video?.pause() }
    }
}
