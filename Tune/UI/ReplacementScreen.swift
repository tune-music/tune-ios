import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ReplacementScreen: View {
    let target: ReplacementTarget
    private let original: MetadataOverride
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MetadataOverride
    @State private var importingAudio = false
    @State private var photo: PhotosPickerItem?
    @State private var temporaryFiles = Set<String>()
    @State private var importing = false
    @State private var error: String?

    init(target: ReplacementTarget) {
        self.target = target
        let stored = MetadataOverrides.shared.value(target.kind, target.id) ?? MetadataOverride()
        original = stored
        _draft = State(initialValue: stored)
    }

    var body: some View {
        Form {
            Section {
                TextField(target.title.isEmpty ? "Название" : target.title, text: $draft.title)
                if target.kind != .artist {
                    TextField("Исполнители через запятую", text: $draft.artists)
                }
            } header: {
                Text("Название и исполнители")
            } footer: {
                Text("Пустые поля сохраняют данные каталога. Подмены действуют в Tune на этом устройстве.")
            }
            Section("Обложка") {
                TextField("HTTPS-ссылка на изображение", text: $draft.cover)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(draft.image != nil)
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(draft.image == nil ? "Выбрать из «Фото»" : "Заменить выбранное фото", systemImage: "photo")
                }
                if draft.image != nil {
                    Button("Убрать выбранное фото", role: .destructive) { draft.image = nil }
                }
            }
            if target.kind == .track {
                Section("Аудио") {
                    Button { importingAudio = true } label: {
                        Label(draft.audio == nil ? "Выбрать аудиофайл" : "Заменить выбранный аудиофайл", systemImage: "waveform")
                    }
                    if draft.audio != nil {
                        Button("Убрать аудиофайл", role: .destructive) { draft.audio = nil }
                    }
                }
            } else {
                Section {
                    TextField("Ссылки или ID треков", text: $draft.tracks, axis: .vertical)
                        .lineLimit(3...8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if target.kind == .artist {
                        TextField("Ссылки или ID альбомов", text: $draft.albums, axis: .vertical)
                            .lineLimit(3...8)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text(target.kind == .album ? "Порядок треков" : "Добавить на страницу исполнителя")
                } footer: {
                    Text(target.kind == .album ? "Вставьте треки в нужном порядке. Пустая строка отделяет один диск от другого."
                         : "Добавленные треки и альбомы поднимутся в начало списков.")
                }
            }
            Section {
                Toggle("Применять данные FckCensor", isOn: $draft.usePlugin)
                    .tint(Theme.accentText)
                if original != MetadataOverride() {
                    Button("Сбросить подмену", role: .destructive) { save(nil) }
                }
            }
        }
        .navigationTitle("Подменить")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { commit() }.disabled(importing || draft == original)
            }
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
            importFile {
                let name = try await MetadataOverrides.importAudio(result.get())
                temporaryFiles.insert(name)
                draft.audio = name
            }
        }
        .onChange(of: photo) { item in
            guard let item else { return }
            importFile {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let name = try await MetadataOverrides.importImage(data)
                temporaryFiles.insert(name)
                draft.image = name
                draft.cover = ""
            }
        }
        .alert("Подмена", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .onDisappear {
            for name in temporaryFiles {
                if let url = MetadataOverrides.file(name) { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    private func importFile(_ operation: @escaping @MainActor () async throws -> Void) {
        importing = true
        Task {
            defer { importing = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }

    private func commit() {
        var value = draft
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.artists = value.artists.trimmingCharacters(in: .whitespacesAndNewlines)
        value.cover = value.cover.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.cover.isEmpty {
            guard let url = URL(string: value.cover), url.scheme == "https", url.host != nil else {
                error = "Введите действительную HTTPS-ссылку на изображение"
                return
            }
        }
        if !value.tracks.isEmpty, MetadataOverride.ids(value.tracks, kind: "track").isEmpty {
            error = "Добавьте ссылки Яндекс Музыки или числовые ID треков"
            return
        }
        if !value.albums.isEmpty, MetadataOverride.ids(value.albums, kind: "album").isEmpty {
            error = "Добавьте ссылки Яндекс Музыки или числовые ID альбомов"
            return
        }
        save(value == MetadataOverride() ? nil : value)
    }

    private func save(_ value: MetadataOverride?) {
        if let audio = value?.audio { temporaryFiles.remove(audio) }
        if let image = value?.image { temporaryFiles.remove(image) }
        MetadataOverrides.shared.save(value, target: target)
        dismiss()
    }
}
