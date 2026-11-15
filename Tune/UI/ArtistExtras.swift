import SwiftUI

struct ArtistExtras: View {
    let clips: [ArtistClip]
    let concerts: [ArtistConcert]

    var body: some View {
        if !clips.isEmpty {
            Shelf("Клипы") {
                ForEach(clips) { clip in
                    Link(destination: clip.url) {
                        CardView(title: clip.title, subtitle: "Смотреть", cover: clip.cover)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 12, trailing: 0))
        }
        if !concerts.isEmpty {
            Section {
                ForEach(concerts) { concert in
                    concertRow(concert)
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

    private func concertRow(_ concert: ArtistConcert) -> some View {
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
