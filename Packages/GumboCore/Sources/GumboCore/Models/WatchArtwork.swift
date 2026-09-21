import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A phone-only description of a cached cover; these URLs never travel to the Watch.
public nonisolated struct WatchArtworkSource: Hashable, Sendable {
    public let albumID: String
    public let url: URL
    public let version: Int

    public init(albumID: String, url: URL, version: Int) {
        self.albumID = albumID
        self.url = url
        self.version = version
    }
}

public nonisolated enum WatchArtwork {
    public static let albumLimit = 64
    public static let pixelLimit = 192
    public static let imageByteLimit = 24_000
    public static let totalByteLimit = 500_000

    /// Enforce the transfer budget on both sides and discard unreferenced album images.
    public static func bounded(_ images: [String: Data], albumIDs: Set<String>) -> [String: Data] {
        var result: [String: Data] = [:]
        var bytes = 0
        for id in images.keys.sorted() where albumIDs.contains(id) {
            guard result.count < albumLimit, let data = images[id], !data.isEmpty,
                  data.count <= imageByteLimit, bytes + data.count <= totalByteLimit else { continue }
            result[id] = data
            bytes += data.count
        }
        return result
    }

    /// Validate the encoded dimensions before creating a platform image on the Watch.
    public static func isThumbnail(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= imageByteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= pixelLimit && height <= pixelLimit
    }

    fileprivate static func thumbnail(at url: URL) -> Data? {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0, bytes.intValue <= 40_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        for quality in [0.75, 0.5, 0.3] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            // Re-encoding strips all source metadata, including any embedded location tags.
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= imageByteLimit { return data as Data }
        }
        return nil
    }
}

/// ImageIO work runs on this actor, never on the phone's UI actor. Cache only this bounded batch.
public actor WatchArtworkBuilder {
    private var cache: [WatchArtworkSource: Data] = [:]
    private var cacheScope: String?

    public init() {}

    public func thumbnails(for sources: [WatchArtworkSource], scope: String = "") -> [String: Data] {
        if cacheScope != scope {
            cache = [:]
            cacheScope = scope
        }
        var nextCache: [WatchArtworkSource: Data] = [:]
        var result: [String: Data] = [:]
        var bytes = 0
        var seen = Set<String>()
        for source in sources.prefix(WatchArtwork.albumLimit) {
            guard !Task.isCancelled else { return [:] }
            guard seen.insert(source.albumID).inserted,
                  let data = cache[source] ?? WatchArtwork.thumbnail(at: source.url),
                  bytes + data.count <= WatchArtwork.totalByteLimit else { continue }
            result[source.albumID] = data
            nextCache[source] = data
            bytes += data.count
        }
        cache = nextCache
        return result
    }
}
