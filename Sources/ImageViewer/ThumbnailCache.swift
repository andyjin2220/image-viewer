import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes small preview images and keeps them in memory and on disk
/// (~/Library/Caches/<bundle id>/Thumbnails), so a folder opens fast the second time.
/// A cached thumbnail is reused only while the file's size and modification date are unchanged.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    /// Longest side of a stored thumbnail, in pixels. Big enough for the largest grid size on Retina.
    static let maxPixelSize = 512

    private let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 400 * 1024 * 1024
        return cache
    }()

    private let directory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "ImageViewer"
        directory = caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Returns a thumbnail, or nil if the file cannot be read. Runs off the main thread.
    func thumbnail(for url: URL) async -> CGImage? {
        guard let key = cacheKey(for: url) else { return nil }
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if Task.isCancelled { return nil }

        let diskURL = directory.appendingPathComponent(key)
        if let image = Self.readImage(at: diskURL) {
            remember(image, key: key)
            return image
        }
        if Task.isCancelled { return nil }

        guard let image = Self.makeThumbnail(of: url) else { return nil }
        remember(image, key: key)
        Self.write(image, to: diskURL)
        return image
    }

    private func remember(_ image: CGImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    private func cacheKey(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let raw = "\(url.standardizedFileURL.path)|\(values.fileSize ?? 0)|\(stamp)|\(Self.maxPixelSize)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func makeThumbnail(of url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func readImage(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// JPEG for opaque images (small files), PNG when there is transparency.
    private static func write(_ image: CGImage, to url: URL) {
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type.identifier as CFString, 1, nil) else { return }
        let props = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        if CGImageDestinationFinalize(dest) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: tmp, to: url)
        } else {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
