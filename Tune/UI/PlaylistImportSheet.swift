import SwiftUI
import UniformTypeIdentifiers

struct PlaylistImportSheet: View {
    let onOpen: (Playlist) -> Void
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var pickingFile = false
    @State private var working = false
    @State private var message: String?
    @State private var created: Playlist?
    @State private var resolved: [Track] = []
    @State private var missing = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название плейлиста", text: $title)
                        .disabled(working || created != nil)
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Ссылки на треки")
                    Button { pickingFile = true } label: {
                        Label("Выбрать файл", systemImage: "doc")
                    }
                } header: {
                    Text("Ссылки на треки")
                } footer: {
                    Text("Вставьте ссылки Яндекс Музыки по одной на строку или выберите файл TXT, M3U или M3U8 с такими ссылками.")
                }
                .disabled(working || created != nil)
                if working {
                    ProgressView("Импортируем треки")
                } else if let message {
                    Text(message).foregroundStyle(Theme.dim)
                }
                if let created, !working {
                    Button("Открыть созданный плейлист") { open(created) }
                }
            }
            .navigationTitle("Импорт плейлиста")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Отмена" : "Закрыть") { dismiss() }
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(created == nil ? "Импортировать" : "Повторить") {
                        Task { await runImport() }
                    }
                    .disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(working)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                text = try Self.readFile(url)
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func open(_ playlist: Playlist) {
        dismiss()
        onOpen(playlist)
    }

    private func runImport() async {
        guard !working else { return }
        guard let uid = session.profile?.uid else {
            message = "Для импорта нужен аккаунт Яндекс Музыки."
            return
        }
        working = true
        defer { working = false }
        message = nil
        do {
            let playlist: Playlist
            var existing = Set<String>()
            if let created {
                playlist = created
                existing = Set(try await API.shared.playlistTracks(created).map(\.id))
            } else {
                let input = Self.parse(text)
                guard !input.ids.isEmpty else { throw TuneError("В списке нет ссылок на треки Яндекс Музыки.") }
                var found: [Track] = []
                for ids in input.ids.chunked(100) {
                    found += try await API.shared.tracks(ids: ids).filter { !$0.unavailable || $0.uncensored }
                }
                guard !found.isEmpty else { throw TuneError("Яндекс не вернул доступных треков из списка.") }
                guard session.profile?.uid == uid else { return }
                guard let newPlaylist = await session.createPlaylist(title) else {
                    throw TuneError("Не удалось создать плейлист.")
                }
                created = newPlaylist
                playlist = newPlaylist
                resolved = found
                missing = input.skipped + input.ids.count - found.count
            }
            let remaining = resolved.filter { !existing.contains($0.id) }
            for batch in remaining.chunked(100) {
                guard session.profile?.uid == uid else { return }
                guard await session.add(batch, to: playlist, atEnd: true, announce: false) else {
                    throw TuneError("Импорт прервался. Повторите, чтобы добавить оставшиеся треки в этот плейлист.")
                }
            }
            let count = resolved.count
            session.show(missing == 0 ? "Импортировано: \(count)" : "Импортировано: \(count) · пропущено: \(missing)")
            open(playlist)
        } catch {
            message = error.localizedDescription
        }
    }

    static func parse(_ text: String) -> (ids: [String], skipped: Int) {
        let hosts: Set<String> = ["music.yandex.ru", "music.yandex.com", "music.yandex.kz", "music.yandex.by", "music.yandex.uz"]
        var ids: [String] = []
        var seen = Set<String>()
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}")))
            guard !value.isEmpty, !value.hasPrefix("#") else { continue }
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased(), hosts.contains(host),
                  case .track(let id)? = Links.target(of: url), !id.isEmpty,
                  id.utf8.allSatisfy({ (48...57).contains($0) }) else {
                skipped += 1
                continue
            }
            if seen.insert(id).inserted { ids.append(id) }
        }
        return (ids, skipped)
    }

    private static func readFile(_ url: URL) throws -> String {
        guard ["txt", "m3u", "m3u8"].contains(url.pathExtension.lowercased()) else {
            throw TuneError("Выберите файл TXT, M3U или M3U8.")
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 512 * 1024
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw TuneError("Файл больше 512 КБ.") }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TuneError("Сохраните список в кодировке UTF-8.")
        }
        return text
    }
}
