import AVFoundation
import MediaToolbox

enum EightDMode: Int, CaseIterable, Identifiable {
    case fixed = 0
    case energy = 1
    case beats = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fixed: return "Фиксированный"
        case .energy: return "По динамике трека"
        case .beats: return "Под биты"
        }
    }

    var description: String {
        switch self {
        case .fixed: return "Равномерное перемещение между каналами с заданным периодом."
        case .energy: return "На громких участках и припевах звук движется быстрее, на тихих — плавнее."
        case .beats: return "Удары баса и бочки ускоряют и перебрасывают звук между каналами."
        }
    }
}

struct SoundSettings: Equatable {
    static let frequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    static let speedRange: ClosedRange<Float> = 0.5...2
    static let eightDPeriodRange: ClosedRange<Float> = 2...20
    static let eightDSensitivityRange: ClosedRange<Float> = 0.1...1
    // Частоты и пресеты из эквалайзера Tune Native.
    static let presets: [(name: String, gains: [Float])] = [
        ("Своя настройка", []),
        ("По умолчанию", Array(repeating: 0, count: 10)),
        ("Классическая музыка", [-0.5, -0.5, -0.5, -0.5, -0.5, -0.5, -3.5, -3.5, -3.5, -4.5]),
        ("Клубная музыка", [-0.5, -0.5, 4, 2.5, 2.5, 2.5, 1.5, -0.5, -0.5, -0.5]),
        ("Танцевальная музыка", [4.5, 3.5, 1, -0.5, -0.5, -2.5, -3.5, -3.5, -0.5, -0.5]),
        ("Усиление НЧ", [4, 4.5, 4.5, 2.5, 0.5, -2, -4, -5, -5.5, -5.5]),
        ("Усиление НЧ и ВЧ", [3.5, 2.5, -0.5, -3.5, -2, 0.5, 4, 5.5, 6, 6]),
        ("Усиление ВЧ", [-4.5, -4.5, -4.5, -2, 1, 5.5, 8, 8, 8, 8]),
        ("Колонки ноутбука", [2, 5.5, 2.5, -1.5, -1, 0.5, 2, 4.5, 6, 7]),
        ("Большой зал", [5, 5, 2.5, 2.5, -0.5, -2, -2, -2, -0.5, -0.5]),
        ("Концерт", [-2, -0.5, 2, 2.5, 2.5, 2.5, 2, 1, 1, 1]),
        ("Вечеринка", [3.5, 3.5, -0.5, -0.5, -0.5, -0.5, -0.5, -0.5, 3.5, 3.5]),
        ("Поп", [-0.5, 2, 3.5, 4, 2.5, -0.5, -1, -1, -0.5, -0.5]),
        ("Регги", [-0.5, -0.5, -0.5, -2.5, -0.5, 3, 3, -0.5, -0.5, -0.5]),
        ("Рок", [4, 2, -2.5, -4, -1.5, 2, 4, 5.5, 5.5, 5.5]),
        ("Ска", [-1, -2, -2, -0.5, 2, 2.5, 4, 4.5, 5.5, 4.5]),
        ("Мягкое звучание", [2, 0.5, -0.5, -1, -0.5, 2, 4, 4.5, 5.5, 6]),
        ("Софт-рок", [2, 2, 1, -0.5, -2, -2.5, -1.5, -0.5, 1, 4]),
        ("Техно", [4, 2.5, -0.5, -2.5, -2, -0.5, 4, 4.5, 4.5, 4]),
    ]

    var speed: Float = 1
    var pitchWithSpeed = true
    var pitchAlgorithm: AVAudioTimePitchAlgorithm { pitchWithSpeed ? .varispeed : .spectral }
    var eqEnabled = false
    var preset = 1
    var preamp: Float = 1
    var gains = SIMD16<Float>.zero
    var echo: Float = 0
    var eightDEnabled = false
    var eightDMode: EightDMode = .fixed
    /// Время полного оборота в секундах.
    var eightDPeriod: Float = 8
    /// Плавность перехода: 1 — мягкая синусоида по кругу, 0 — быстрый переброс с задержкой у краёв.
    var eightDSmoothness: Float = 0.85
    /// Глубина панорамирования: насколько далеко звук уходит в крайние точки.
    var eightDDepth: Float = 0.85
    /// Чувствительность к динамике или ударам баса в авто-режимах.
    var eightDSensitivity: Float = 0.65
    var needsAudioMix: Bool { (eqEnabled && (gains != .zero || preamp != 1)) || echo > 0 || eightDEnabled }

    mutating func selectPreset(_ index: Int) {
        guard Self.presets.indices.contains(index) else { return }
        preset = index
        if index != 0 {
            preamp = 1
            for band in Self.frequencies.indices { gains[band] = Self.presets[index].gains[band] }
        }
    }

    static func read() -> Self {
        let saved = UserDefaults.standard.array(forKey: "tuneSound") as? [Float] ?? []
        var settings = Self()
        settings.pitchWithSpeed = UserDefaults.standard.object(forKey: "tunePitchWithSpeed") as? Bool ?? true
        if let eightD = UserDefaults.standard.array(forKey: "tune8D") as? [Float],
           eightD.count == 6, eightD.allSatisfy(\.isFinite) {
            settings.eightDEnabled = eightD[0] == 1
            settings.eightDMode = EightDMode(rawValue: Int(eightD[1].rounded())) ?? .fixed
            settings.eightDPeriod = min(eightDPeriodRange.upperBound, max(eightDPeriodRange.lowerBound, eightD[2]))
            settings.eightDSmoothness = min(1, max(0, eightD[3]))
            settings.eightDDepth = min(1, max(0, eightD[4]))
            settings.eightDSensitivity = min(eightDSensitivityRange.upperBound, max(eightDSensitivityRange.lowerBound, eightD[5]))
        }
        guard saved.allSatisfy(\.isFinite), saved.count == 7 || saved.count == frequencies.count + 5 else { return settings }
        settings.speed = min(speedRange.upperBound, max(speedRange.lowerBound, saved[0]))
        settings.echo = min(1, max(0, saved[1]))
        if saved.count == 7 {
            // Переносим прежние пять полос к ближайшим частотам новой сетки.
            for (offset, band) in [0, 2, 4, 5, 7].enumerated() {
                settings.gains[band] = min(12, max(-12, saved[offset + 2]))
            }
            settings.eqEnabled = settings.gains != .zero
            settings.preset = settings.eqEnabled ? 0 : 1
        } else {
            settings.eqEnabled = saved[2] == 1
            settings.preset = Int(min(Float(presets.count - 1), max(0, saved[3])))
            settings.preamp = min(1.5, max(0.5, saved[4]))
            for index in frequencies.indices { settings.gains[index] = min(12, max(-12, saved[index + 5])) }
        }
        return settings
    }

    func save() {
        let values: [Float] = [speed, echo, eqEnabled ? 1 : 0, Float(preset), preamp]
        UserDefaults.standard.set(values + Self.frequencies.indices.map { gains[$0] }, forKey: "tuneSound")
        UserDefaults.standard.set(pitchWithSpeed, forKey: "tunePitchWithSpeed")
        let eightD: [Float] = [
            eightDEnabled ? 1 : 0,
            Float(eightDMode.rawValue),
            eightDPeriod,
            eightDSmoothness,
            eightDDepth,
            eightDSensitivity,
        ]
        UserDefaults.standard.set(eightD, forKey: "tune8D")
    }
}

/// Аудиопоток читает настройки, не ожидая освобождения блокировки.
final class AudioEffects {
    private let lock = NSLock()
    private var settings = SoundSettings()
    private let meterLock = NSLock()
    private var meterLevel: Float = 0
    private var meterBass: Float = 0
    private var meterUpdated: CFAbsoluteTime = 0

    func update(_ settings: SoundSettings) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }

    private func snapshot() -> SoundSettings? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return settings
    }

    fileprivate func publishMeter(level: Float, bass: Float) {
        guard meterLock.try() else { return }
        meterLevel = level
        meterBass = bass
        meterUpdated = CFAbsoluteTimeGetCurrent()
        meterLock.unlock()
    }

    func currentMeter() -> (level: Double, bass: Double, live: Bool) {
        meterLock.lock()
        let level = meterLevel
        let bass = meterBass
        let updated = meterUpdated
        meterLock.unlock()
        let live = (CFAbsoluteTimeGetCurrent() - updated) < 0.18
        return live ? (Double(level), Double(bass), true) : (0, 0, false)
    }

    @MainActor
    func install(on item: AVPlayerItem) async -> Bool {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return false }
        let state = Unmanaged.passRetained(Renderer(effects: self))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: state.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<Renderer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, maxFrames, format in
                Unmanaged<Renderer>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format.pointee, maxFrames: Int(maxFrames))
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, written, flags in
                written.pointee = 0
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, nil, written) == noErr,
                      written.pointee > 0 else { return }
                Unmanaged<Renderer>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().render(buffers, frames: Int(written.pointee), flags: flags.pointee)
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap else {
            state.release()
            return false
        }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        item.audioMix = mix
        return true
    }

    /// Пространственное вращение 8D: панорама с сохранением мощности, интерауральная задержка
    /// (ITD до ~0.48 мс), частотное затенение дальнего уха и спереди/сзади, а также авто-режимы
    /// по общей динамике трека и по ударам баса.
    struct Spatial8D {
        private let rate: Float
        private let delayMask: Int
        private var delayL: [Float]
        private var delayR: [Float]
        private var writeIndex = 0

        private var phase: Float = 0
        private var lowpassState: Float = 0
        private var fastBassEnv: Float = 0
        private var slowBassEnv: Float = 0.01
        private var fastEnergyEnv: Float = 0
        private var slowEnergyEnv: Float = 0.02
        private var beatBoost: Float = 0
        private var beatCooldown: Int = 0
        private var direction: Float = 1

        private var shadeL: Float = 0
        private var shadeR: Float = 0

        private let bassAlpha: Float
        private let fastBassAttack: Float
        private let fastBassRelease: Float
        private let slowBassAlpha: Float
        private let fastEnergyAlpha: Float
        private let slowEnergyAlpha: Float
        private let beatDecay: Float
        private let minBeatGap: Int
        private let maxItdSamples: Float
        private let baseShadeAlpha: Float

        init(rate: Float) {
            self.rate = max(8_000, rate)
            var size = 64
            let needed = Int((self.rate * 0.002).rounded(.up)) + 4
            while size < needed { size <<= 1 }
            delayMask = size - 1
            delayL = Array(repeating: 0, count: size)
            delayR = Array(repeating: 0, count: size)

            // Низкочастотный детектор ударов (~130 Гц) и огибающие громкости.
            bassAlpha = min(0.5, 2 * Float.pi * 130 / self.rate)
            fastBassAttack = 1 - expf(-1 / (self.rate * 0.004))
            fastBassRelease = 1 - expf(-1 / (self.rate * 0.045))
            slowBassAlpha = 1 - expf(-1 / (self.rate * 0.38))
            fastEnergyAlpha = 1 - expf(-1 / (self.rate * 0.12))
            slowEnergyAlpha = 1 - expf(-1 / (self.rate * 2.2))
            beatDecay = expf(-1 / (self.rate * 0.14))
            minBeatGap = Int(self.rate * 0.2)
            maxItdSamples = self.rate * 0.00048
            baseShadeAlpha = min(0.85, 2 * Float.pi * 3_400 / self.rate)
        }

        mutating func reset() {
            for i in delayL.indices {
                delayL[i] = 0
                delayR[i] = 0
            }
            writeIndex = 0
            lowpassState = 0
            fastBassEnv = 0
            slowBassEnv = 0.01
            fastEnergyEnv = 0
            slowEnergyEnv = 0.02
            beatBoost = 0
            beatCooldown = 0
            shadeL = 0
            shadeR = 0
        }

        /// Положение источника по горизонтали (-1...1) с учётом плавности и глубины.
        static func shapedPan(phase: Float, smoothness: Float, depth: Float) -> Float {
            let raw = sinf(phase)
            let clampedSmooth = min(1, max(0, smoothness))
            // При smoothness = 1 — чистый синус; ближе к 0 — быстрый перелёт и удержание у краёв.
            let sharpness = 1 + (1 - clampedSmooth) * 8
            let shaped: Float
            if sharpness <= 1.001 {
                shaped = raw
            } else {
                shaped = tanhf(raw * sharpness) / tanhf(sharpness)
            }
            return shaped * min(1, max(0, depth))
        }

        mutating func process(left: Float, right: Float, settings: SoundSettings) -> (Float, Float) {
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5

            // Анализ сигнала для авто-режимов.
            let absMid = abs(mid)
            fastEnergyEnv += (absMid - fastEnergyEnv) * fastEnergyAlpha
            slowEnergyEnv += (absMid - slowEnergyEnv) * slowEnergyAlpha

            lowpassState += (mid - lowpassState) * bassAlpha
            let bass = abs(lowpassState)
            let bassCoeff = bass > fastBassEnv ? fastBassAttack : fastBassRelease
            fastBassEnv += (bass - fastBassEnv) * bassCoeff
            slowBassEnv += (bass - slowBassEnv) * slowBassAlpha

            if beatCooldown > 0 { beatCooldown -= 1 }
            beatBoost *= beatDecay

            let sensitivity = min(1, max(0.1, settings.eightDSensitivity))
            var speedMultiplier: Float = 1

            switch settings.eightDMode {
            case .fixed:
                direction = 1
            case .energy:
                direction = 1
                let ratio = fastEnergyEnv / max(0.008, slowEnergyEnv)
                let delta = (ratio - 1) * (1.2 + sensitivity * 2.2)
                speedMultiplier = min(3.4, max(0.35, 1 + delta))
            case .beats:
                let threshold = 1.95 - sensitivity * 0.72
                if beatCooldown == 0, fastBassEnv > 0.018, fastBassEnv > slowBassEnv * threshold {
                    let strength = min(1, (fastBassEnv / max(0.008, slowBassEnv) - threshold) * 1.4)
                    beatBoost = min(4.5, beatBoost + 1.6 + strength * (1.5 + sensitivity * 2))
                    // На сильных ударах при высокой чувствительности разворачиваем или подталкиваем фазу.
                    if strength > 0.55, sensitivity > 0.45 {
                        phase += direction * (0.28 + 0.35 * sensitivity)
                    }
                    beatCooldown = minBeatGap
                }
                speedMultiplier = 0.65 + beatBoost
            }

            let period = max(SoundSettings.eightDPeriodRange.lowerBound,
                             min(SoundSettings.eightDPeriodRange.upperBound, settings.eightDPeriod))
            let angularStep = (2 * Float.pi / (period * rate)) * speedMultiplier * direction
            phase += angularStep
            if phase >= 2 * Float.pi {
                phase -= 2 * Float.pi
            } else if phase < 0 {
                phase += 2 * Float.pi
            }

            let pan = Self.shapedPan(phase: phase, smoothness: settings.eightDSmoothness, depth: settings.eightDDepth)
            let frontBack = cosf(phase) // +1 спереди, -1 сзади

            // Смешиваем моно-фокус и исходное стерео, чтобы сцена оставалась живой, но чётко локализованной.
            let depth = min(1, max(0, settings.eightDDepth))
            let stereoKeep = 0.35 * (1 - depth * 0.65)
            let sourceL = mid + side * stereoKeep
            let sourceR = mid - side * stereoKeep

            // Интерауральная задержка (ITD): дальнее ухо получает сигнал чуть позже.
            delayL[writeIndex] = sourceL
            delayR[writeIndex] = sourceR
            let itdL = max(0, pan) * maxItdSamples
            let itdR = max(0, -pan) * maxItdSamples
            let delayedL = readDelay(delayL, offset: itdL)
            let delayedR = readDelay(delayR, offset: itdR)
            writeIndex = (writeIndex + 1) & delayMask

            // Частотное затенение головой для дальнего уха и лёгкое приглушение ВЧ, когда звук позади.
            let rearShadow = max(0, -frontBack) * 0.25 * depth
            let shadowL = min(0.75, max(0, pan) * 0.55 + rearShadow)
            let shadowR = min(0.75, max(0, -pan) * 0.55 + rearShadow)

            shadeL += (delayedL - shadeL) * baseShadeAlpha
            shadeR += (delayedR - shadeR) * baseShadeAlpha

            let filteredL = delayedL * (1 - shadowL) + shadeL * shadowL
            let filteredR = delayedR * (1 - shadowR) + shadeR * shadowR

            // Панорамирование с постоянной мощностью (constant-power pan).
            let angle = (pan + 1) * (Float.pi * 0.25)
            let gainL = cosf(angle)
            let gainR = sinf(angle)

            // Небольшой кроссфид на противоположное ухо сохраняет естественность в наушниках.
            let cross: Float = 0.12 * (1 - depth * 0.4)
            let outL = filteredL * (gainL + cross * gainR)
            let outR = filteredR * (gainR + cross * gainL)
            return (outL, outR)
        }

        private func readDelay(_ buffer: [Float], offset: Float) -> Float {
            let whole = Int(offset)
            let frac = offset - Float(whole)
            let i0 = (writeIndex - whole) & delayMask
            let i1 = (i0 - 1) & delayMask
            return buffer[i0] * (1 - frac) + buffer[i1] * frac
        }
    }

    private final class Renderer {
        private struct Channel {
            var z1 = SIMD16<Float>.zero
            var z2 = SIMD16<Float>.zero
        }

        private let effects: AudioEffects
        private var current = SoundSettings()
        private var rate: Float = 0
        private var formatSupported = false
        private var channels: [Channel] = []
        private var halls: [HallReverb] = []
        private var spatial: Spatial8D?
        private var mono: [Float] = []
        private var headroom: Float = 1
        private var activeBands: UInt16 = 0
        private var meterBassLP: Float = 0
        private var meterBassAlpha: Float = 0.08
        private var b0 = SIMD16<Float>(repeating: 1)
        private var b1 = SIMD16<Float>.zero
        private var b2 = SIMD16<Float>.zero
        private var a1 = SIMD16<Float>.zero
        private var a2 = SIMD16<Float>.zero

        init(effects: AudioEffects) { self.effects = effects }

        func prepare(_ format: AudioStreamBasicDescription, maxFrames: Int) {
            rate = Float(format.mSampleRate)
            formatSupported = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32 && rate.isFinite && rate > 0
            guard formatSupported else { return }
            channels = Array(repeating: Channel(), count: Int(format.mChannelsPerFrame))
            halls = channels.indices.map { HallReverb(rate: rate, channel: $0) }
            spatial = Spatial8D(rate: rate)
            mono = Array(repeating: 0, count: max(0, maxFrames))
            meterBassLP = 0
            meterBassAlpha = min(0.5, 2 * Float.pi * 140 / max(8_000, rate))
            configure(effects.snapshot() ?? current)
        }

        private func configure(_ settings: SoundSettings) {
            current = settings
            activeBands = 0
            var boost: Float = 0
            for index in SoundSettings.frequencies.indices {
                let frequency = SoundSettings.frequencies[index]
                let gain = settings.gains[index]
                guard settings.eqEnabled, gain != 0, frequency < rate * 0.49 else { continue }
                activeBands |= 1 << index
                boost = max(boost, gain)
                let amplitude = powf(10, gain / 40)
                let angle = 2 * Float.pi * frequency / rate
                let cosine = cosf(angle)
                let sine = sinf(angle)
                if index == 0 || index == SoundSettings.frequencies.count - 1 {
                    // Полки по краям, как в Tune Native; средние полосы — peaking Q = 1.
                    let direction: Float = index == 0 ? 1 : -1
                    let sum = amplitude + 1
                    let difference = amplitude - 1
                    let slope = sqrtf(2 * amplitude) * sine
                    let normalization = sum + direction * difference * cosine + slope
                    b0[index] = amplitude * (sum - direction * difference * cosine + slope) / normalization
                    b1[index] = direction * 2 * amplitude * (difference - direction * sum * cosine) / normalization
                    b2[index] = amplitude * (sum - direction * difference * cosine - slope) / normalization
                    a1[index] = -direction * 2 * (difference + direction * sum * cosine) / normalization
                    a2[index] = (sum + direction * difference * cosine - slope) / normalization
                } else {
                    let alpha = sine / 2
                    let middle = -2 * cosine
                    let normalization = 1 + alpha / amplitude
                    b0[index] = (1 + alpha * amplitude) / normalization
                    b1[index] = middle / normalization
                    b2[index] = (1 - alpha * amplitude) / normalization
                    a1[index] = middle / normalization
                    a2[index] = (1 - alpha / amplitude) / normalization
                }
            }
            let preamp = settings.eqEnabled ? settings.preamp : 1
            headroom = preamp * powf(10, -boost / 20)
        }

        func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, flags: MTAudioProcessingTapFlags) {
            guard formatSupported, !channels.isEmpty else { return }
            if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                for channel in channels.indices { channels[channel] = Channel() }
                for index in halls.indices { halls[index].reset() }
                spatial?.reset()
                meterBassLP = 0
            }
            if let settings = effects.snapshot(), settings != current {
                if settings.gains != current.gains || settings.eqEnabled != current.eqEnabled {
                    for channel in channels.indices { channels[channel] = Channel() }
                }
                if settings.echo == 0, current.echo > 0 {
                    for index in halls.indices { halls[index].reset() }
                }
                if !settings.eightDEnabled, current.eightDEnabled {
                    spatial?.reset()
                }
                configure(settings)
            }
            analyzeMeter(list, frames: frames)
            guard current.needsAudioMix else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let eightD = current.eightDEnabled && channels.count >= 2
            // При включённом 8D добавляем лёгкий пространственный объём зала, если пользователь не задал свой реверб выше.
            let effectiveEcho = current.eightDEnabled ? max(current.echo, 0.16 * current.eightDDepth) : current.echo
            let reverb = effectiveEcho > 0 && frames <= mono.count
            if reverb {
                for frame in 0..<frames { mono[frame] = 0 }
            }
            var offset = 0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                defer { offset += count }
                guard count > 0, offset + count <= channels.count,
                      let raw = buffer.mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                let available = min(frames, Int(buffer.mDataByteSize) / (count * MemoryLayout<Float>.stride))
                for index in 0..<count {
                    let channelIndex = offset + index
                    var channel = channels[channelIndex]
                    for frame in 0..<available {
                        let sampleIndex = frame * count + index
                        var value = samples[sampleIndex]
                        var bands = activeBands
                        while bands != 0 {
                            let band = bands.trailingZeroBitCount
                            bands &= bands - 1
                            let output = b0[band] * value + channel.z1[band]
                            channel.z1[band] = b1[band] * value - a1[band] * output + channel.z2[band]
                            channel.z2[band] = b2[band] * value - a2[band] * output
                            value = output
                        }
                        value *= headroom
                        if reverb {
                            mono[frame] += value
                            samples[sampleIndex] = value
                        } else if eightD {
                            samples[sampleIndex] = value
                        } else {
                            samples[sampleIndex] = min(1, max(-1, value))
                        }
                    }
                    channels[channelIndex] = channel
                }
            }
            if eightD { applySpatial8D(buffers, frames: frames, clamping: !reverb) }
            if reverb { mixHall(buffers, frames: frames, echo: effectiveEcho) }
        }

        private func applySpatial8D(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, clamping: Bool) {
            guard var processor = spatial else { return }
            defer { spatial = processor }

            if buffers.count == 1, buffers[0].mNumberChannels >= 2, let raw = buffers[0].mData {
                let count = Int(buffers[0].mNumberChannels)
                let samples = raw.assumingMemoryBound(to: Float.self)
                let available = min(frames, Int(buffers[0].mDataByteSize) / (count * MemoryLayout<Float>.stride))
                for frame in 0..<available {
                    let base = frame * count
                    let (outL, outR) = processor.process(left: samples[base], right: samples[base + 1], settings: current)
                    if clamping {
                        samples[base] = min(1, max(-1, outL))
                        samples[base + 1] = min(1, max(-1, outR))
                    } else {
                        samples[base] = outL
                        samples[base + 1] = outR
                    }
                }
            } else if buffers.count >= 2,
                      buffers[0].mNumberChannels == 1,
                      buffers[1].mNumberChannels == 1,
                      let rawL = buffers[0].mData,
                      let rawR = buffers[1].mData {
                let samplesL = rawL.assumingMemoryBound(to: Float.self)
                let samplesR = rawR.assumingMemoryBound(to: Float.self)
                let availL = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
                let availR = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.stride
                let available = min(frames, min(availL, availR))
                for frame in 0..<available {
                    let (outL, outR) = processor.process(left: samplesL[frame], right: samplesR[frame], settings: current)
                    if clamping {
                        samplesL[frame] = min(1, max(-1, outL))
                        samplesR[frame] = min(1, max(-1, outR))
                    } else {
                        samplesL[frame] = outL
                        samplesR[frame] = outR
                    }
                }
            }
        }

        private func analyzeMeter(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first, first.mNumberChannels > 0, let raw = first.mData else { return }
            let count = Int(first.mNumberChannels)
            let samples = raw.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(first.mDataByteSize) / (count * MemoryLayout<Float>.stride))
            guard available > 0 else { return }
            let strideStep = 4
            var sumSq: Float = 0
            var bassSq: Float = 0
            var counted = 0
            var frame = 0
            while frame < available {
                let base = frame * count
                let sample = count >= 2 ? (samples[base] + samples[base + 1]) * 0.5 : samples[base]
                sumSq += sample * sample
                meterBassLP += (sample - meterBassLP) * meterBassAlpha
                bassSq += meterBassLP * meterBassLP
                counted += 1
                frame += strideStep
            }
            guard counted > 0 else { return }
            let rms = sqrtf(sumSq / Float(counted))
            let bassRms = sqrtf(bassSq / Float(counted))
            let level = min(1, powf(min(1, rms * 3.4), 0.78))
            let bass = min(1, powf(min(1, bassRms * 4.2), 0.85))
            effects.publishMeter(level: level, bass: bass)
        }

        private func mixHall(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, echo: Float) {
            let wet = echo * 0.8
            let dry = 1 - echo * 0.4
            let inputScale: Float = 0.015 * min(1, 2 / Float(halls.count))
            var offset = 0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                defer { offset += count }
                guard count > 0, offset + count <= halls.count, let raw = buffer.mData else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                let available = min(frames, Int(buffer.mDataByteSize) / (count * MemoryLayout<Float>.stride))
                for index in 0..<count {
                    let channel = offset + index
                    for frame in 0..<available {
                        let sample = frame * count + index
                        let hall = halls[channel].render(mono[frame] * inputScale)
                        samples[sample] = min(1, max(-1, samples[sample] * dry + hall * wet))
                    }
                }
            }
        }
    }
}
