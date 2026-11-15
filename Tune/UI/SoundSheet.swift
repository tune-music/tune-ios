import SwiftUI

struct SoundSheet: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Воспроизведение") {
                    Picker("Скорость", selection: Binding(get: { player.sound.speed }, set: { speed in
                        var setting = player.sound
                        setting.speed = speed
                        player.updateSound(setting)
                    })) {
                        ForEach(SoundSettings.speeds, id: \.self) { speed in
                            Text("\(speed.formatted())×").tag(speed)
                        }
                    }
                }
                Section("Эквалайзер") {
                    ForEach(SoundSettings.frequencies.indices, id: \.self) { band in
                        gainSlider(band)
                    }
                }
                Section {
                    valueSlider("Эхо", value: "\(Int((player.sound.echo * 100).rounded()))%",
                                range: 0...1, step: 0.05, binding: Binding(get: { player.sound.echo }, set: { echo in
                        var setting = player.sound
                        setting.echo = echo
                        player.updateSound(setting)
                    }))
                } footer: {
                    Text("Для эквалайзера и эха трек сначала загружается в кэш. На скачанных треках эффекты доступны без сети.")
                }
                if player.sound != SoundSettings() {
                    Button("Сбросить настройки звука") { player.updateSound(SoundSettings()) }
                }
            }
            .navigationTitle("Звук")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .tint(Theme.accentText)
    }

    private func gainSlider(_ band: Int) -> some View {
        let frequency = SoundSettings.frequencies[band]
        let name = frequency >= 1_000 ? "\(Int(frequency / 1_000)) кГц" : "\(Int(frequency)) Гц"
        let gain = Int(player.sound.gains[band])
        let value = gain > 0 ? "+\(gain) дБ" : "\(gain) дБ"
        return valueSlider(name, value: value, range: -12...12, step: 1, binding: Binding(
            get: { player.sound.gains[band] },
            set: { gain in
                var setting = player.sound
                setting.gains[band] = gain
                player.updateSound(setting)
            }
        ))
    }

    private func valueSlider(_ title: String, value: String, range: ClosedRange<Float>, step: Float,
                             binding: Binding<Float>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 66, alignment: .leading)
            Slider(value: binding, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
