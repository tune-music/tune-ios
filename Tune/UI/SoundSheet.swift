import SwiftUI

struct SoundSheet: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Воспроизведение") {
                    valueSlider("Скорость", value: "\(player.sound.speed.formatted(.number.precision(.fractionLength(0...2))))×",
                                range: SoundSettings.speedRange, step: 0.05, binding: Binding(get: { player.sound.speed }, set: { speed in
                        var setting = player.sound
                        setting.speed = (speed * 20).rounded() / 20
                        player.updateSound(setting)
                    }))
                    valueSlider("Эхо", value: "\(Int((player.sound.echo * 100).rounded()))%",
                                range: 0...1, step: 0.01, binding: Binding(get: { player.sound.echo }, set: { echo in
                        var setting = player.sound
                        setting.echo = (echo * 100).rounded() / 100
                        player.updateSound(setting)
                    }))
                }
                Section {
                    Toggle("Эквалайзер", isOn: Binding(get: { player.sound.eqEnabled }, set: { enabled in
                        var setting = player.sound
                        setting.eqEnabled = enabled
                        player.updateSound(setting)
                    }))
                    if player.sound.eqEnabled {
                        presets
                        valueSlider("Уровень", value: "\(Int((player.sound.preamp * 100).rounded()))%", range: 0.5...1.5,
                                    step: 0.05, binding: Binding(get: { player.sound.preamp }, set: { level in
                            var setting = player.sound
                            setting.preamp = level
                            setting.preset = 0
                            player.updateSound(setting)
                        }))
                        ForEach(SoundSettings.frequencies.indices, id: \.self) { band in
                            gainSlider(band)
                        }
                    }
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

    private var presets: some View {
        Picker("Пресет", selection: Binding(get: { player.sound.preset }, set: { preset in
            var setting = player.sound
            setting.selectPreset(preset)
            player.updateSound(setting)
        })) {
            ForEach(SoundSettings.presets.indices, id: \.self) { index in
                Text(SoundSettings.presets[index].name).tag(index)
            }
        }
    }

    private func gainSlider(_ band: Int) -> some View {
        let frequency = SoundSettings.frequencies[band]
        let name = frequency >= 1_000 ? "\(Int(frequency / 1_000)) кГц" : "\(Int(frequency)) Гц"
        let gain = player.sound.gains[band]
        let number = gain.formatted(.number.precision(.fractionLength(0...1)))
        let value = gain > 0 ? "+\(number) дБ" : "\(number) дБ"
        return valueSlider(name, value: value, range: -12...12, step: 0.5, binding: Binding(
            get: { player.sound.gains[band] },
            set: { gain in
                var setting = player.sound
                setting.gains[band] = gain
                setting.preset = 0
                player.updateSound(setting)
            }
        ))
    }

    private func valueSlider(_ title: String, value: String, range: ClosedRange<Float>, step: Float,
                             binding: Binding<Float>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 78, alignment: .leading)
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
