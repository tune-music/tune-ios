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
                    speedChips
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
                        GraphicEqualizerView(
                            gains: SoundSettings.frequencies.indices.map { player.sound.gains[$0] },
                            liveUpdate: { band, gain in
                                var setting = player.sound
                                setting.gains[band] = gain
                                setting.preset = 0
                                player.previewSound(setting)
                            },
                            commit: { band, gain in
                                var setting = player.sound
                                setting.gains[band] = gain
                                setting.preset = 0
                                player.updateSound(setting)
                            }
                        )
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

    private var speedChips: some View {
        let current = (shownSpeed * 20).rounded() / 20
        return HStack(spacing: 8) {
            ForEach([Float(0.85), 1.0, 1.25, 1.5], id: \.self) { value in
                let on = abs(current - value) < 0.01
                Button {
                    pendingSpeed = nil
                    applySpeed(value)
                } label: {
                    Text("\(value.formatted(.number.precision(.fractionLength(0...2))))×")
                        .font(.scaled(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(on ? Color.black : Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(on ? Theme.accent : Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
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
        let visible = SoundSettings.presets.indices.filter { $0 != 0 || player.sound.preset == 0 }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visible, id: \.self) { index in
                        let on = player.sound.preset == index
                        Button {
                            var setting = player.sound
                            setting.selectPreset(index)
                            player.updateSound(setting)
                        } label: {
                            Text(SoundSettings.presets[index].name)
                                .font(.scaled(size: 13, weight: .semibold))
                                .foregroundStyle(on ? Color.black : Theme.text)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(on ? Theme.accent : Theme.raised, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(player.sound.preset, anchor: .center) }
            .onChange(of: player.sound.preset) { value in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
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

/// 10-полосный вертикальный эквалайзер с плавной кривой АЧХ.
private struct GraphicEqualizerView: View {
    let gains: [Float]
    let liveUpdate: (Int, Float) -> Void
    let commit: (Int, Float) -> Void

    @State private var draft: [Float]?
    @State private var activeBand: Int?

    private var shown: [Float] { draft ?? gains }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if let band = activeBand, SoundSettings.frequencies.indices.contains(band) {
                    Text(bandTitle(band))
                        .font(.scaled(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text(gainText(shown[band]))
                        .font(.scaled(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accentText)
                } else {
                    Text("АЧХ")
                        .font(.scaled(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Text("+12 / 0 / −12 дБ")
                        .font(.scaled(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(height: 18)

            ZStack {
                curve(shown)
                HStack(spacing: 0) {
                    ForEach(SoundSettings.frequencies.indices, id: \.self) { band in
                        fader(band)
                    }
                }
            }
            .frame(height: 156)

            HStack(spacing: 0) {
                ForEach(SoundSettings.frequencies.indices, id: \.self) { band in
                    Text(shortFreq(SoundSettings.frequencies[band]))
                        .font(.system(size: 10, weight: activeBand == band ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(activeBand == band ? Theme.accentText : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func curve(_ values: [Float]) -> some View {
        Canvas { context, size in
            let padY: CGFloat = 10
            let midY = size.height / 2
            let span = max(1, size.height - padY * 2)
            func yFor(_ db: Float) -> CGFloat {
                let normalized = CGFloat(12 - min(12, max(-12, db))) / 24
                return padY + normalized * span
            }

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: midY))
            zero.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(zero, with: .color(Theme.text.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            guard !values.isEmpty else { return }
            let colW = size.width / CGFloat(values.count)
            let points = values.enumerated().map { idx, val in
                CGPoint(x: colW * (CGFloat(idx) + 0.5), y: yFor(val))
            }

            var line = Path()
            line.move(to: points[0])
            for i in 0..<(points.count - 1) {
                let cx = (points[i].x + points[i + 1].x) / 2
                line.addCurve(to: points[i + 1], control1: CGPoint(x: cx, y: points[i].y), control2: CGPoint(x: cx, y: points[i + 1].y))
            }

            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: midY))
            area.addLine(to: CGPoint(x: points.first!.x, y: midY))
            area.closeSubpath()

            context.fill(area, with: .color(Theme.accent.opacity(0.14)))
            context.stroke(line, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .allowsHitTesting(false)
    }

    private func fader(_ band: Int) -> some View {
        let value = shown.indices.contains(band) ? shown[band] : 0
        let active = activeBand == band
        return GeometryReader { geo in
            let padY: CGFloat = 10
            let span = max(1, geo.size.height - padY * 2)
            let midY = geo.size.height / 2
            let y = padY + CGFloat(12 - min(12, max(-12, value))) / 24 * span
            ZStack {
                Capsule()
                    .fill(Theme.text.opacity(0.12))
                    .frame(width: 2, height: span)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 3, height: max(2, abs(y - midY)))
                    .position(x: geo.size.width / 2, y: (y + midY) / 2)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: active ? 15 : 12, height: active ? 15 : 12)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 1.5))
                    .position(x: geo.size.width / 2, y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if draft == nil { draft = gains }
                        activeBand = band
                        let clamped = min(max(gesture.location.y - padY, 0), span)
                        let raw = Float(12 - (clamped / span) * 24)
                        let snapped = (raw * 2).rounded() / 2
                        let previous = draft?[band] ?? gains[band]
                        draft?[band] = snapped
                        if snapped != previous {
                            liveUpdate(band, snapped)
                        }
                    }
                    .onEnded { _ in
                        let final = draft?[band] ?? gains[band]
                        draft = nil
                        activeBand = nil
                        commit(band, final)
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    draft = nil
                    activeBand = nil
                    liveUpdate(band, 0)
                    commit(band, 0)
                }
            )
        }
    }

    private func bandTitle(_ band: Int) -> String {
        let f = SoundSettings.frequencies[band]
        return f >= 1_000 ? "\(Int(f / 1_000)) кГц" : "\(Int(f)) Гц"
    }

    private func shortFreq(_ f: Float) -> String {
        f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))"
    }

    private func gainText(_ gain: Float) -> String {
        let number = gain.formatted(.number.precision(.fractionLength(0...1)))
        return gain > 0 ? "+\(number) дБ" : "\(number) дБ"
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
