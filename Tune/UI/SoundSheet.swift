import SwiftUI

struct SoundSheet: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var pendingSpeed: Float?
    @State private var pendingReverb: Float?

    private var shownSpeed: Float { pendingSpeed ?? player.sound.speed }

    var body: some View {
        NavigationStack {
            Form {
                Section("Воспроизведение") {
                    speedSlider
                    Toggle("Тон вместе со скоростью", isOn: Binding(get: { player.sound.pitchWithSpeed }, set: { enabled in
                        var setting = player.sound
                        setting.pitchWithSpeed = enabled
                        player.updateSound(setting)
                    }))
                    reverbSlider
                }
                Section {
                    Toggle("8D звук", isOn: Binding(get: { player.sound.eightDEnabled }, set: { enabled in
                        var setting = player.sound
                        setting.eightDEnabled = enabled
                        player.updateSound(setting)
                    }))
                    if player.sound.eightDEnabled {
                        eightDControls
                    }
                } footer: {
                    if player.sound.eightDEnabled {
                        Text(player.sound.eightDMode.description)
                    }
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
                    Text("Для эквалайзера, реверба и 8D звука трек сначала загружается в кэш. На скачанных треках эффекты доступны без сети.")
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

    private var speedSlider: some View {
        valueSlider("Скорость", value: "\(shownSpeed.formatted(.number.precision(.fractionLength(0...2))))×",
                    range: SoundSettings.speedRange, step: 0.05, binding: Binding(get: { shownSpeed }, set: { value in
            let speed = (value * 20).rounded() / 20
            if pendingSpeed != nil {
                pendingSpeed = speed
            } else {
                applySpeed(speed)
            }
        }), onEditingChanged: { editing in
            if editing {
                pendingSpeed = player.sound.speed
            } else if let pendingSpeed {
                applySpeed(pendingSpeed)
                self.pendingSpeed = nil
            }
        })
    }

    private func applySpeed(_ speed: Float) {
        var setting = player.sound
        setting.speed = speed
        player.updateSound(setting)
    }

    private var reverbSlider: some View {
        let level = pendingReverb ?? player.sound.echo
        return valueSlider("Реверб", value: "\(Int((level * 100).rounded()))%", range: 0...1, step: 0.01,
                           binding: Binding(get: { pendingReverb ?? player.sound.echo }, set: { value in
            if pendingReverb != nil {
                pendingReverb = value
            } else {
                applyReverb(value)
            }
        }), onEditingChanged: { editing in
            if editing {
                pendingReverb = player.sound.echo
            } else if let pendingReverb {
                applyReverb(pendingReverb)
                self.pendingReverb = nil
            }
        })
    }

    private func applyReverb(_ level: Float) {
        var setting = player.sound
        setting.echo = level
        player.updateSound(setting)
    }

    @ViewBuilder
    private var eightDControls: some View {
        Picker("Режим", selection: Binding(get: { player.sound.eightDMode }, set: { mode in
            var setting = player.sound
            setting.eightDMode = mode
            player.updateSound(setting)
        })) {
            ForEach(EightDMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        let periodTitle = player.sound.eightDMode == .fixed ? "Период" : "База"
        let periodText = "\(player.sound.eightDPeriod.formatted(.number.precision(.fractionLength(0...1)))) с"
        valueSlider(periodTitle, value: periodText, range: SoundSettings.eightDPeriodRange, step: 0.5,
                    binding: Binding(get: { player.sound.eightDPeriod }, set: { value in
            var setting = player.sound
            setting.eightDPeriod = (value * 2).rounded() / 2
            player.updateSound(setting)
        }))
        valueSlider("Плавность", value: "\(Int((player.sound.eightDSmoothness * 100).rounded()))%", range: 0...1, step: 0.05,
                    binding: Binding(get: { player.sound.eightDSmoothness }, set: { value in
            var setting = player.sound
            setting.eightDSmoothness = value
            player.updateSound(setting)
        }))
        valueSlider("Ширина", value: "\(Int((player.sound.eightDDepth * 100).rounded()))%", range: 0...1, step: 0.05,
                    binding: Binding(get: { player.sound.eightDDepth }, set: { value in
            var setting = player.sound
            setting.eightDDepth = value
            player.updateSound(setting)
        }))
        if player.sound.eightDMode != .fixed {
            valueSlider("Отклик", value: "\(Int((player.sound.eightDSensitivity * 100).rounded()))%",
                        range: SoundSettings.eightDSensitivityRange, step: 0.05,
                        binding: Binding(get: { player.sound.eightDSensitivity }, set: { value in
                var setting = player.sound
                setting.eightDSensitivity = value
                player.updateSound(setting)
            }))
        }
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
                             binding: Binding<Float>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: binding, in: range, step: step, onEditingChanged: onEditingChanged)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
