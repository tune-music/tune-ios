import ImageIO
import SwiftUI
import UIKit

/// Обложки: память → диск → сеть. Картинка ужимается до нужного размера не в главном
/// потоке, поэтому списки листаются без рывков.
final class ImageLoader {
    static let shared = ImageLoader()

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 96 << 20
        return cache
    }()
    private let inflight = Inflight()
    private let tones = NSCache<NSString, UIColor>()
    private let http: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Сторона картинки у Яндекса под нужный размер в точках.
    static func side(for points: CGFloat) -> Int {
        let pixels = points * 3
        if pixels <= 220 { return 200 }
        if pixels <= 480 { return 400 }
        return 800
    }

    private func key(_ uri: String, _ side: Int) -> String { "\(side)|\(uri)" }

    func cached(_ uri: String?, side: Int) -> UIImage? {
        guard let uri, !uri.isEmpty else { return nil }
        return memory.object(forKey: key(uri, side) as NSString)
    }

    func load(_ uri: String?, side: Int) async -> UIImage? {
        guard let uri, !uri.isEmpty else { return nil }
        let name = key(uri, side)
        if let image = memory.object(forKey: name as NSString) { return image }
        let image = await inflight.run(name) { [self] in await fetch(uri, side) }
        if let image {
            memory.setObject(image, forKey: name as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }

    /// Приглушённый цвет обложки: фон плеера и шапки альбома.
    func cachedTone(_ uri: String?) -> Color? {
        guard let uri, let color = tones.object(forKey: uri as NSString) else { return nil }
        return Color(color)
    }

    func tone(_ uri: String?) async -> Color? {
        guard let uri, !uri.isEmpty else { return nil }
        if let color = tones.object(forKey: uri as NSString) { return Color(color) }
        guard let image = await load(uri, side: 200), let color = Self.average(image) else { return nil }
        tones.setObject(color, forKey: uri as NSString)
        return Color(color)
    }

    /// Средний цвет картинки, приведённый к спокойной тёмной гамме.
    private static func average(_ image: UIImage) -> UIColor? {
        guard let source = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let raw = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard raw.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return raw }
        return UIColor(hue: hue, saturation: min(saturation * 1.15, 0.7), brightness: min(max(brightness, 0.3), 0.46), alpha: 1)
    }

    private func pinned(_ uri: String) -> URL {
        Storage.covers.appendingPathComponent(Storage.hash(uri))
    }

    private func fetch(_ uri: String, _ side: Int) async -> UIImage? {
        // Обложка скачанного трека лежит рядом с ним и видна без сети.
        if let data = try? Data(contentsOf: pinned(uri)), let image = Self.decode(data, side: side) { return image }
        let file = Storage.images.appendingPathComponent("\(Storage.hash(uri))-\(side)")
        if let data = try? Data(contentsOf: file), let image = Self.decode(data, side: side) { return image }
        guard let url = Cover.url(uri, side: side),
              let (data, response) = try? await http.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = Self.decode(data, side: side)
        else { return nil }
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// Сохраняет обложку насовсем: для скачанных треков.
    func pin(_ uri: String?) async {
        guard let uri, !uri.isEmpty, !FileManager.default.fileExists(atPath: pinned(uri).path) else { return }
        guard let url = Cover.url(uri, side: 800),
              let (data, response) = try? await http.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        try? data.write(to: pinned(uri), options: .atomic)
    }

    func unpin(_ uri: String?) {
        guard let uri, !uri.isEmpty else { return }
        try? FileManager.default.removeItem(at: pinned(uri))
    }

    private static func decode(_ data: Data, side: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Одна и та же обложка не качается дважды одновременно.
private actor Inflight {
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func run(_ key: String, _ work: @escaping () async -> UIImage?) async -> UIImage? {
        if let task = tasks[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { await work() }
        tasks[key] = task
        let image = await task.value
        tasks[key] = nil
        return image
    }
}

struct CoverView: View {
    let uri: String?
    let size: CGFloat
    var corner: CGFloat = 6
    var round = false

    @State private var image: UIImage?

    var body: some View {
        let side = ImageLoader.side(for: size)
        let shown = image ?? ImageLoader.shared.cached(uri, side: side)
        ZStack {
            Color(white: 0.14)
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: round ? "person.fill" : "music.note")
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(Color(white: 0.32))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : corner, style: .continuous))
        .task(id: uri) {
            image = nil
            image = await ImageLoader.shared.load(uri, side: side)
        }
    }
}
