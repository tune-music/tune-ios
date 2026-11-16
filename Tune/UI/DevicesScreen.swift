import SwiftUI

struct DevicesScreen: View {
    @ObservedObject private var sync = Ynison.shared

    var body: some View {
        List {
            Section {
                Toggle("Синхронизация устройств", isOn: Binding(get: { sync.enabled }, set: sync.setEnabled))
                    .tint(Theme.accentText)
            } footer: {
                Text("Переносите очередь, текущий трек и позицию между устройствами одного аккаунта Яндекса.")
            }
            if sync.enabled {
                connection
                if sync.connection == .connected {
                    Section("Воспроизведение") {
                        deviceRow(id: sync.deviceID, name: "Этот iPhone", icon: "iphone")
                        ForEach(sync.state.devices.filter { $0.id != sync.deviceID && !$0.speaker }) { device in
                            deviceRow(id: device.id, name: device.name, icon: "desktopcomputer")
                        }
                    }
                    let speakers = sync.state.devices.filter { $0.id != sync.deviceID && $0.speaker }
                    if !speakers.isEmpty {
                        Section("Колонки") {
                            ForEach(speakers) { device in
                                deviceRow(id: device.id, name: device.name, icon: "hifispeaker.fill")
                            }
                        }
                    }
                    remoteControls
                }
            }
        }
        .navigationTitle("Устройства")
        .navigationBarTitleDisplayMode(.inline)
        .task { sync.updateConnection() }
        .alert("Устройства", isPresented: Binding(get: { sync.errorText != nil }, set: { if !$0 { sync.errorText = nil } })) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(sync.errorText ?? "")
        }
    }

    @ViewBuilder private var connection: some View {
        switch sync.connection {
        case .connected:
            if !sync.state.devices.contains(where: { $0.id != sync.deviceID }) {
                Section {
                    Text("Других устройств в сети пока нет")
                } footer: {
                    Text("Включите музыку на другом устройстве или Станции, подключённой к тому же аккаунту.")
                }
            }
        case .idle, .connecting:
            ProgressView("Подключаемся к Яндекс Музыке")
        case .offline:
            Label("Для подключения устройств нужен интернет", systemImage: "wifi.slash")
        case .failed:
            Section {
                Label("Нет связи с Яндекс Музыкой", systemImage: "wifi.slash")
                Button("Повторить подключение") { sync.retry() }
            }
        }
    }

    private func deviceRow(id: String, name: String, icon: String) -> some View {
        Button {
            Task { await sync.transfer(to: id) }
        } label: {
            HStack {
                Label(name, systemImage: icon)
                Spacer()
                if sync.state.active == id {
                    Image(systemName: "checkmark").accessibilityLabel("Выбрано")
                }
            }
        }
        .disabled(sync.working || sync.state.active == id)
    }

    @ViewBuilder private var remoteControls: some View {
        let playback = sync.state.playback
        if let active = sync.state.active, active != sync.deviceID,
           let device = sync.state.devices.first(where: { $0.id == active }), let song = playback.current {
            Section {
                Text(song.title.isEmpty ? "Текущий трек" : song.title)
                    .font(.headline)
                    .lineLimit(2)
                Button {
                    Task { await sync.controlRemote(paused: !playback.paused) }
                } label: {
                    Label(playback.paused ? "Продолжить" : "Пауза", systemImage: playback.paused ? "play.fill" : "pause.fill")
                }
                if let index = playback.index, index > 0 {
                    Button {
                        Task { await sync.controlRemote(offset: -1) }
                    } label: {
                        Label("Предыдущий трек", systemImage: "backward.end.fill")
                    }
                }
                if let index = playback.index, index + 1 < playback.songs.count {
                    Button {
                        Task { await sync.controlRemote(offset: 1) }
                    } label: {
                        Label("Следующий трек", systemImage: "forward.end.fill")
                    }
                }
            } header: {
                Text(device.name)
            }
            .disabled(sync.working)
        }
    }
}
