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
                        SoundSliderRow(
                            title: "Уровень",
                            range: 0.5...1.5,
                            quantize: { ($0 * 20).rounded() / 20 },
                            format: { "\(Int(($0 * 100).rounded()))%" },
                            externalValue: player.sound.preamp,
                            liveUpdate: { level in
                                var setting = player.sound
                                setting.preamp = level
                                setting.preset = 0
                                player.previewSound(setting)
                            },
                            commit: { level in
                                var setting = player.sound
                                setting.preamp = level
                                setting.preset = 0
                                player.updateSound(setting)
                            }
                        )
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
        let speed = (shownSpeed * 20).rounded() / 20
        return valueSlider("Скорость", value: "\(speed.formatted(.number.precision(.fractionLength(0...2))))×",
                           range: SoundSettings.speedRange, binding: Binding(get: { shownSpeed }, set: { value in
            if pendingSpeed != nil {
                pendingSpeed = value
            } else {
                applySpeed((value * 20).rounded() / 20)
            }
        }), onEditingChanged: { editing in
            if editing {
                pendingSpeed = player.sound.speed
            } else if let pendingSpeed {
                applySpeed((pendingSpeed * 20).rounded() / 20)
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
        return valueSlider("Реверб", value: "\(Int((level * 100).rounded()))%", range: 0...1,
                           binding: Binding(get: { pendingReverb ?? player.sound.echo }, set: { value in
            if pendingReverb != nil {
                pendingReverb = value
            } else {
                applyReverb((value * 100).rounded() / 100)
            }
        }), onEditingChanged: { editing in
            if editing {
                pendingReverb = player.sound.echo
            } else if let pendingReverb {
                applyReverb((pendingReverb * 100).rounded() / 100)
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
        SoundSliderRow(
            title: periodTitle,
            range: SoundSettings.eightDPeriodRange,
            quantize: { ($0 * 2).rounded() / 2 },
            format: { "\($0.formatted(.number.precision(.fractionLength(0...1)))) с" },
            externalValue: player.sound.eightDPeriod,
            liveUpdate: { value in
                var setting = player.sound
                setting.eightDPeriod = value
                player.previewSound(setting)
            },
            commit: { value in
                var setting = player.sound
                setting.eightDPeriod = value
                player.updateSound(setting)
            }
        )
        SoundSliderRow(
            title: "Плавность",
            range: 0...1,
            quantize: { ($0 * 100).rounded() / 100 },
            format: { "\(Int(($0 * 100).rounded()))%" },
            externalValue: player.sound.eightDSmoothness,
            liveUpdate: { value in
                var setting = player.sound
                setting.eightDSmoothness = value
                player.previewSound(setting)
            },
            commit: { value in
                var setting = player.sound
                setting.eightDSmoothness = value
                player.updateSound(setting)
            }
        )
        SoundSliderRow(
            title: "Ширина",
            range: 0...1,
            quantize: { ($0 * 100).rounded() / 100 },
            format: { "\(Int(($0 * 100).rounded()))%" },
            externalValue: player.sound.eightDDepth,
            liveUpdate: { value in
                var setting = player.sound
                setting.eightDDepth = value
                player.previewSound(setting)
            },
            commit: { value in
                var setting = player.sound
                setting.eightDDepth = value
                player.updateSound(setting)
            }
        )
        if player.sound.eightDMode != .fixed {
            SoundSliderRow(
                title: "Отклик",
                range: SoundSettings.eightDSensitivityRange,
                quantize: { ($0 * 100).rounded() / 100 },
                format: { "\(Int(($0 * 100).rounded()))%" },
                externalValue: player.sound.eightDSensitivity,
                liveUpdate: { value in
                    var setting = player.sound
                    setting.eightDSensitivity = value
                    player.previewSound(setting)
                },
                commit: { value in
                    var setting = player.sound
                    setting.eightDSensitivity = value
                    player.updateSound(setting)
                }
            )
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
        return SoundSliderRow(
            title: name,
            range: -12...12,
            quantize: { ($0 * 2).rounded() / 2 },
            format: { gain in
                let number = gain.formatted(.number.precision(.fractionLength(0...1)))
                return gain > 0 ? "+\(number) дБ" : "\(number) дБ"
            },
            externalValue: player.sound.gains[band],
            liveUpdate: { gain in
                var setting = player.sound
                setting.gains[band] = gain
                setting.preset = 0
                player.previewSound(setting)
            },
            commit: { gain in
                var setting = player.sound
                setting.gains[band] = gain
                setting.preset = 0
                player.updateSound(setting)
            }
        )
    }

    private func valueSlider(_ title: String, value: String, range: ClosedRange<Float>,
                             binding: Binding<Float>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 82, alignment: .leading)
            Slider(value: binding, in: range, onEditingChanged: onEditingChanged)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// Плавный ползунок без ступенчатого рывка (`step` в SwiftUI привязывает бегунок к сетке)
/// и с локальным состоянием во время перетаскивания, чтобы не перерисовывать всю форму на каждый пиксель.
private struct SoundSliderRow: View {
    let title: String
    let range: ClosedRange<Float>
    let quantize: (Float) -> Float
    let format: (Float) -> String
    let externalValue: Float
    let liveUpdate: (Float) -> Void
    let commit: (Float) -> Void

    @State private var draft: Float?

    private var current: Float { quantize(draft ?? externalValue) }

    var body: some View {
        let text = format(current)
        HStack(spacing: 12) {
            Text(title).frame(width: 82, alignment: .leading)
            Slider(
                value: Binding(
                    get: { draft ?? externalValue },
                    set: { newValue in
                        let previous = quantize(draft ?? externalValue)
                        draft = newValue
                        let next = quantize(newValue)
                        if next != previous {
                            liveUpdate(next)
                        }
                    }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        draft = externalValue
                    } else if let final = draft {
                        let snapped = quantize(final)
                        draft = nil
                        commit(snapped)
                    }
                }
            )
            .accessibilityLabel(title)
            .accessibilityValue(text)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
