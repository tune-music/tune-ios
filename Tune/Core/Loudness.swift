import AVFoundation

/// Громкость записей для выравнивания. Свежие треки приносят её от Яндекса сами. У скачанных
/// и сохранённых раньше её нет: тогда она запрашивается у Яндекса, а без сети измеряется
/// по файлу на устройстве. Найденное запоминается.
@MainActor
final class Loudness {
    static let shared = Loudness()

    /// Средняя громкость в LUFS и пик в dBTP.
    struct Level: Codable {
        var i: Double
        var tp: Double?
    }

    private var known: [String: Level]

    private init() {
        known = Storage.load("loudness-r128.json", as: [String: Level].self) ?? [:]
    }

    /// Громкость, если она уже известна.
    func value(_ track: Track) -> Level? {
        if let i = track.loudness { return Level(i: i, tp: track.peak) }
        return known[track.id]
    }

    /// Узнаёт громкость трека: у Яндекса, а если не вышло — по файлу.
    func resolve(_ track: Track) async -> Level? {
        if let value = value(track) { return value }
        if Demo.on { return nil }
        if !Session.shared.offline, let fresh = try? await API.shared.tracks(ids: [track.id]).first, let i = fresh.loudness {
            let level = Level(i: i, tp: fresh.peak)
            store(track.id, level)
            return level
        }
        guard let file = Downloads.shared.fileURL(for: track.id) ?? TrackFiles.existing(id: track.id, in: Storage.stream) else { return nil }
        guard let measured = await Task.detached(priority: .utility, operation: { Self.measure(file) }).value else { return nil }
        store(track.id, measured)
        return measured
    }

    private func store(_ id: String, _ value: Level) {
        known[id] = value
        let snapshot = known
        Task.detached(priority: .utility) { Storage.save(snapshot, "loudness-r128.json") }
    }

    /// Средняя громкость файла. Это приближение к LUFS: без частотной поправки стандарта,
    /// поэтому может отличаться от числа Яндекса на пару децибел.
    nonisolated static func measure(_ url: URL) -> Level? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var sum = 0.0
        var count = 0
        var top = 0.0
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let size = length / 2
            guard size > 0 else { continue }
            if samples.count < size { samples = [Int16](repeating: 0, count: size) }
            let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size * 2, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for index in 0..<size {
                let value = Double(samples[index]) / 32768
                sum += value * value
                top = max(top, abs(value))
            }
            count += size
        }
        guard count > 22050, sum > 0 else { return nil }
        // +3 дБ: у стереозаписи мощность двух каналов складывается, а здесь они сведены в один.
        return Level(i: 10 * log10(sum / Double(count)) + 3, tp: top > 0 ? 20 * log10(top) : nil)
    }
}
