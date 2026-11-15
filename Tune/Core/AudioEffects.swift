import AVFoundation
import MediaToolbox

struct SoundSettings: Equatable {
    static let frequencies: [Float] = [60, 250, 1_000, 4_000, 12_000]
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var speed: Float = 1
    var gains = SIMD8<Float>.zero
    var echo: Float = 0
    var needsAudioMix: Bool { gains != .zero || echo > 0 }

    static func read() -> Self {
        let saved = UserDefaults.standard.array(forKey: "tuneSound") as? [Float] ?? []
        guard saved.count == frequencies.count + 2, saved.allSatisfy(\.isFinite) else { return Self() }
        var settings = Self()
        settings.speed = speeds.contains(saved[0]) ? saved[0] : 1
        settings.echo = min(1, max(0, saved[1]))
        for index in frequencies.indices { settings.gains[index] = min(12, max(-12, saved[index + 2])) }
        return settings
    }

    func save() {
        UserDefaults.standard.set([speed, echo] + Self.frequencies.indices.map { gains[$0] }, forKey: "tuneSound")
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
            prepare: { tap, _, format in
                Unmanaged<Renderer>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format.pointee)
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
            var z1 = SIMD8<Float>.zero
            var z2 = SIMD8<Float>.zero
        }

        private let effects: AudioEffects
        private var current = SoundSettings()
        private var rate: Float = 0
        private var formatSupported = false
        private var channels: [Channel] = []
        private var delay: [Float] = []
        private var delayFrames = 0
        private var cursor = 0
        private var headroom: Float = 1
        private var b0 = SIMD8<Float>(repeating: 1)
        private var b1 = SIMD8<Float>.zero
        private var b2 = SIMD8<Float>.zero
        private var a1 = SIMD8<Float>.zero
        private var a2 = SIMD8<Float>.zero

        init(effects: AudioEffects) { self.effects = effects }

        func prepare(_ format: AudioStreamBasicDescription) {
            rate = Float(format.mSampleRate)
            formatSupported = format.mFormatID == kAudioFormatLinearPCM
                && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && format.mBitsPerChannel == 32 && rate.isFinite && rate > 0
            guard formatSupported else { return }
            channels = Array(repeating: Channel(), count: Int(format.mChannelsPerFrame))
            delayFrames = max(1, Int(rate * 0.24))
            delay = Array(repeating: 0, count: delayFrames * channels.count)
            cursor = 0
            configure(effects.snapshot() ?? current)
        }

        private func configure(_ settings: SoundSettings) {
            current = settings
            var boost: Float = 0
            for index in SoundSettings.frequencies.indices {
                let gain = settings.gains[index]
                boost += max(0, gain)
                guard gain != 0 else {
                    b0[index] = 1
                    b1[index] = 0
                    b2[index] = 0
                    a1[index] = 0
                    a2[index] = 0
                    continue
                }
                // Peaking biquad, Q = 1.0.
                let amplitude = powf(10, gain / 40)
                let angle = 2 * Float.pi * min(SoundSettings.frequencies[index], rate * 0.45) / rate
                let alpha = sinf(angle) / 2
                let middle = -2 * cosf(angle)
                let normalization = 1 + alpha / amplitude
                b0[index] = (1 + alpha * amplitude) / normalization
                b1[index] = middle / normalization
                b2[index] = (1 - alpha * amplitude) / normalization
                a1[index] = middle / normalization
                a2[index] = (1 - alpha / amplitude) / normalization
            }
            let feedback: Float = 0.32
            headroom = powf(10, -boost / 20) / (1 + settings.echo * 0.5 / (1 - feedback))
        }

        func render(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, flags: MTAudioProcessingTapFlags) {
            guard formatSupported, !channels.isEmpty else { return }
            if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                for channel in channels.indices { channels[channel] = Channel() }
                for index in delay.indices { delay[index] = 0 }
                cursor = 0
            }
            if let settings = effects.snapshot(), settings != current {
                if settings.gains != current.gains {
                    for channel in channels.indices { channels[channel] = Channel() }
                }
                if settings.echo == 0, current.echo > 0 {
                    for index in delay.indices { delay[index] = 0 }
                }
                configure(settings)
            }
            guard current.needsAudioMix else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
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
                    var position = cursor
                    for frame in 0..<available {
                        let sampleIndex = frame * count + index
                        var value = samples[sampleIndex]
                        for band in SoundSettings.frequencies.indices where current.gains[band] != 0 {
                            let output = b0[band] * value + channel.z1[band]
                            channel.z1[band] = b1[band] * value - a1[band] * output + channel.z2[band]
                            channel.z2[band] = b2[band] * value - a2[band] * output
                            value = output
                        }
                        if current.echo > 0 {
                            let slot = channelIndex * delayFrames + position
                            let previous = delay[slot]
                            delay[slot] = value + previous * 0.32
                            value += previous * current.echo * 0.5
                            position += 1
                            if position == delayFrames { position = 0 }
                        }
                        samples[sampleIndex] = value * headroom
                    }
                    channels[channelIndex] = channel
                }
            }
            if current.echo > 0 { cursor = (cursor + frames) % delayFrames }
        }
    }
}
