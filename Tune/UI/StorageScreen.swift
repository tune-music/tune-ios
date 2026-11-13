import SwiftUI

/// Занятое место: скачанная музыка по исполнителям, от самых «тяжёлых». Смахивание
/// удаляет всё скачанное у исполнителя.
struct StorageScreen: View {
    @EnvironmentObject private var downloads: Downloads
    @State private var doomed: Bucket?

    private struct Bucket: Identifiable {
        let name: String
        var ids: [String]
        var bytes: Int64
        var cover: String?
        var id: String { name }
    }

    private var buckets: [Bucket] {
        var map: [String: Bucket] = [:]
        for entry in downloads.entries {
            let track = entry.track
            let name = track.artistList.first?.name ?? (track.artists.isEmpty ? "Без исполнителя" : track.artists)
            var bucket = map[name] ?? Bucket(name: name, ids: [], bytes: 0, cover: track.cover)
            bucket.ids.append(track.id)
            bucket.bytes += entry.bytes
            map[name] = bucket
        }
        return map.values.sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }

    var body: some View {
        let list = buckets
        List {
            if list.isEmpty {
                Placeholder(icon: "internaldrive", title: "Пока ничего не скачано", text: "Здесь будет видно, чья музыка занимает больше всего места.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Storage.sizeText(downloads.totalBytes))
                        .font(.scaled(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(plural(downloads.entries.count, "трек", "трека", "треков")) · \(plural(list.count, "исполнитель", "исполнителя", "исполнителей"))")
                        .font(.scaled(size: 14))
                        .foregroundStyle(Theme.dim)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 14, trailing: 16))
                ForEach(list) { bucket in
                    HStack(spacing: 12) {
                        CoverView(uri: bucket.cover, size: 46, corner: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bucket.name)
                                .font(.scaled(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(plural(bucket.ids.count, "трек", "трека", "треков"))
                                .font(.scaled(size: 14))
                                .foregroundStyle(Theme.dim)
                        }
                        Spacer(minLength: 8)
                        Text(Storage.sizeText(bucket.bytes))
                            .font(.scaled(size: 15).monospacedDigit())
                            .foregroundStyle(Theme.dim)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            doomed = bucket
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Занятое место")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Удалить скачанное?", isPresented: Binding(get: { doomed != nil }, set: { if !$0 { doomed = nil } })) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                doomed?.ids.forEach { downloads.remove($0) }
                doomed = nil
            }
        } message: {
            Text(doomed.map { "\($0.name): \(plural($0.ids.count, "трек", "трека", "треков")), \(Storage.sizeText($0.bytes))" } ?? "")
        }
    }
}
