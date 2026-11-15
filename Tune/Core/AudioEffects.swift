import AVFoundation
import MediaToolbox

struct SoundSettings: Equatable {
    static let frequencies: [Float] = [60, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
    static let speedRange: ClosedRange<Float> = 0.5...2
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
    var pitchWithSpeed = false
    var pitchAlgorithm: AVAudioTimePitchAlgorithm { pitchWithSpeed ? .varispeed : .spectral }
    var eqEnabled = false
    var preset = 1
    var preamp: Float = 1
    var gains = SIMD16<Float>.zero
    var echo: Float = 0
    var needsAudioMix: Bool { (eqEnabled && (gains != .zero || preamp != 1)) || echo > 0 }

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
        guard saved.allSatisfy(\.isFinite), saved.count == 7 || saved.count == frequencies.count + 5 else { return Self() }
        var settings = Self()
        settings.speed = min(speedRange.upperBound, max(speedRange.lowerBound, saved[0]))
        settings.echo = min(1, max(0, saved[1]))
        settings.pitchWithSpeed = UserDefaults.standard.bool(forKey: "tunePitchWithSpeed")
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
    }
}

/// Аудиопоток читает настройки, не ожидая освобождения блокировки.
final class AudioEffects {
    private let lock = NSLock()
    private var settings = SoundSettings()

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
        private var mono: [Float] = []
        private var headroom: Float = 1
        private var activeBands: UInt16 = 0
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
            mono = Array(repeating: 0, count: max(0, maxFrames))
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
            }
            if let settings = effects.snapshot(), settings != current {
                if settings.gains != current.gains || settings.eqEnabled != current.eqEnabled {
                    for channel in channels.indices { channels[channel] = Channel() }
                }
                if settings.echo == 0, current.echo > 0 {
                    for index in halls.indices { halls[index].reset() }
                }
                configure(settings)
            }
            guard current.needsAudioMix else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let reverb = current.echo > 0 && frames <= mono.count
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
                        } else {
                            samples[sampleIndex] = min(1, max(-1, value))
                        }
                    }
                    channels[channelIndex] = channel
                }
            }
            if reverb { mixHall(buffers, frames: frames) }
        }

        private func mixHall(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let wet = current.echo * 0.8
            let dry = 1 - current.echo * 0.4
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
