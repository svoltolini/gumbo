import CryptoKit
import Foundation
import GumboShared

/// Album covers extracted from files or downloaded from the drive, kept on disk.
public nonisolated enum CoverStore {
    @TaskLocal static var indexingRun: IndexingRun?
    /// Allows isolated indexing tests to use temporary storage, without touching the user's artwork.
    @TaskLocal static var directoryOverride: URL?
    private static let mutationLock = NSRecursiveLock()

    /// Resolved once: every cover lookup used to create the folder again, a file system call per artwork drawn.
    private static let defaultDirectory = sourceDirectory(in: AppDirectories.support)

    /// Earlier caches mixed source pictures with external artwork without recording provenance.
    /// Leave those files untouched; every reader and writer uses this source-only namespace.
    static func sourceDirectory(in support: URL) -> URL {
        support.appending(path: "Gumbo/source-covers-v\(ArtworkPolicy.version)", directoryHint: .isDirectory)
    }
    public static var directory: URL { directoryOverride ?? defaultDirectory }

    static func scopedDirectory(driveID: String, rootPath: String) -> URL {
        if let directoryOverride { return directoryOverride }
        let scope = "\(driveID.utf8.count):\(driveID)\(rootPath.utf8.count):\(rootPath)"
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return defaultDirectory.appending(path: digest, directoryHint: .isDirectory)
    }

    private static func mutate(_ description: String, _ operation: () throws -> Void) {
        func write() {
            mutationLock.withLock {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try operation()
                } catch {
                    diagnostics("Couldn't \(description): \(error.localizedDescription)")
                }
            }
        }
        if let indexingRun {
            indexingRun.whileActive(write)
        } else {
            write()
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func fileURL(for albumID: String) -> URL {
        directory.appending(path: fileName(for: albumID))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// The cover's file name: a hash of the album id, spelled out without a formatter per byte.
    private static func fileName(for albumID: String) -> String {
        var name: [UInt8] = []
        name.reserveCapacity(68)
        for byte in SHA256.hash(data: Data(albumID.utf8)) {
            name.append(hexDigits[Int(byte >> 4)])
            name.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: name, as: UTF8.self) + ".img"
    }

    public static func hasCover(for albumID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: albumID).path)
    }

    public static func save(_ data: Data, for albumID: String) {
        let pair = CoverPalette.extract(from: data)
        mutate("save album artwork") {
            try data.write(to: fileURL(for: albumID), options: .atomic)
            try removeIfPresent(missingURL(for: albumID))
            if let pair {
                try JSONEncoder().encode(pair).write(to: paletteURL(for: albumID), options: .atomic)
            } else {
                try removeIfPresent(paletteURL(for: albumID))
            }
        }
    }

    public static func remove(for albumID: String) {
        mutate("remove album artwork") {
            try removeIfPresent(fileURL(for: albumID))
            try removeIfPresent(paletteURL(for: albumID))
            try removeIfPresent(missingURL(for: albumID))
        }
    }

    // MARK: Albums with no cover anywhere

    private static func missingURL(for albumID: String) -> URL {
        fileURL(for: albumID).deletingPathExtension().appendingPathExtension("missing")
    }

    /// Remembers that the folder and the files had no picture, so the search is not repeated on every refresh.
    public static func noteMissingCover(for albumID: String) {
        mutate("record missing album artwork") {
            try Data().write(to: missingURL(for: albumID), options: .atomic)
        }
    }

    /// When the last fruitless search for this album's cover happened, if any.
    public static func missingCoverDate(for albumID: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: missingURL(for: albumID).path)[.modificationDate]) as? Date
    }

    public static func copy(from sourceID: String, to targetID: String) {
        mutate("copy album artwork") {
            let source = fileURL(for: sourceID)
            let target = fileURL(for: targetID)
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { return }
            try FileManager.default.copyItem(at: source, to: target)
            if FileManager.default.fileExists(atPath: paletteURL(for: sourceID).path) {
                try removeIfPresent(paletteURL(for: targetID))
                try FileManager.default.copyItem(at: paletteURL(for: sourceID), to: paletteURL(for: targetID))
            }
        }
    }

    // MARK: Palettes

    /// Colours read from the cover, kept next to it.
    public static func paletteURL(for albumID: String) -> URL {
        fileURL(for: albumID).deletingPathExtension().appendingPathExtension("palette")
    }

    public static func palette(for albumID: String) -> CoverPalette.Pair? {
        guard let data = try? Data(contentsOf: paletteURL(for: albumID)) else { return nil }
        return try? JSONDecoder().decode(CoverPalette.Pair.self, from: data)
    }

    public static func savePalette(_ pair: CoverPalette.Pair, for albumID: String) {
        mutate("save artwork colours") {
            try JSONEncoder().encode(pair).write(to: paletteURL(for: albumID), options: .atomic)
        }
    }

    public static func storedPalettes(for albumIDs: Set<String>) -> [String: CoverPalette.Pair] {
        var result: [String: CoverPalette.Pair] = [:]
        for id in albumIDs {
            if let pair = palette(for: id) { result[id] = pair }
        }
        return result
    }

    /// Reads the colours of covers that were saved before palettes existed, storing them for next time.
    public static func computePalettes(for albumIDs: Set<String>) -> [String: CoverPalette.Pair] {
        var result: [String: CoverPalette.Pair] = [:]
        for id in albumIDs {
            guard let data = try? Data(contentsOf: fileURL(for: id)), let pair = CoverPalette.extract(from: data) else { continue }
            savePalette(pair, for: id)
            result[id] = pair
        }
        return result
    }

    public static func clear() {
        mutate("clear the artwork cache") {
            try removeIfPresent(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Covers found inside files, kept per song until albums settle

    /// Embedded pictures are saved per song while tags are still being read, because the album a
    /// song ends up in can change as more tags arrive. Once albums are final these are removed.
    private static var trackDirectory: URL {
        directory.appending(path: "tracks", directoryHint: .isDirectory)
    }

    private static func trackCoverURL(for trackID: String) -> URL {
        let digest = SHA256.hash(data: Data(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        return trackDirectory.appending(path: "\(digest).img")
    }

    public static func saveTrackCover(_ data: Data, for trackID: String) {
        mutate("save song artwork") {
            try FileManager.default.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
            try data.write(to: trackCoverURL(for: trackID), options: .atomic)
        }
    }

    public static func hasTrackCover(for trackID: String) -> Bool {
        FileManager.default.fileExists(atPath: trackCoverURL(for: trackID).path)
    }

    /// Promotes a song's embedded picture to its album's cover, palette included.
    public static func adoptTrackCover(from trackID: String, for albumID: String) {
        guard let data = try? Data(contentsOf: trackCoverURL(for: trackID)) else { return }
        save(data, for: albumID)
    }

    public static func clearTrackCovers() {
        mutate("clear temporary song artwork") {
            try removeIfPresent(trackDirectory)
        }
    }

    // MARK: Finder metadata saved as artwork

    /// How every AppleDouble file ("._Cover.jpg" beside "Cover.jpg") starts; no picture format does.
    private static let appleDoubleSignature = Data([0x00, 0x05, 0x16, 0x07])

    /// Scans before hidden files were ignored could save a "._" twin as an album's cover or a song's
    /// picture, under whichever album it reached. Finds those by their content, removes them and
    /// returns how many album covers went; nothing is written when there are none.
    static func removeFinderMetadata() -> Int {
        func finderMetadata(in folder: URL) -> [URL] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { url in
                guard url.pathExtension == "img", let handle = try? FileHandle(forReadingFrom: url) else { return false }
                defer { try? handle.close() }
                return (try? handle.read(upToCount: appleDoubleSignature.count)) == appleDoubleSignature
            }
        }
        let covers = finderMetadata(in: directory)
        let songs = finderMetadata(in: trackDirectory)
        guard !covers.isEmpty || !songs.isEmpty else { return 0 }
        mutate("remove artwork read from hidden files") {
            for url in covers {
                try removeIfPresent(url)
                try removeIfPresent(url.deletingPathExtension().appendingPathExtension("palette"))
            }
            for url in songs { try removeIfPresent(url) }
        }
        return covers.count
    }

    /// Album ids that already have a cover on disk.
    /// Lists the folder once rather than asking the file system about every album.
    public static func coveredAlbumIDs(among albums: [Album]) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let present = Set(names)
        return Set(albums.lazy.filter { present.contains(fileName(for: $0.id)) }.map(\.id))
    }

}
