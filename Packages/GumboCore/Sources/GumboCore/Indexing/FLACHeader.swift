import Foundation

/// What the metadata blocks at the start of a FLAC file tell us.
public nonisolated struct FLACInfo: Sendable {
    public var sampleRate: Int?
    public var channels: Int?
    public var bitsPerSample: Int?
    public var totalSamples: Int64?
    /// Vorbis comment fields with uppercased keys, e.g. "TITLE", "TRACKNUMBER".
    public var tags: [String: String] = [:]
    public var picture: Data?
    public var pictureMIME: String?
    public var isComplete = false
    /// Whether STREAMINFO and a VORBIS_COMMENT block were parsed; enough for the library without the rest.
    public var hasStreamInfo = false
    public var hasComments = false
    /// The prefix length needed for the next incomplete block or header.
    public var neededPrefix: Int?

    public var duration: TimeInterval? {
        guard let totalSamples, let sampleRate, sampleRate > 0, totalSamples > 0 else { return nil }
        return Double(totalSamples) / Double(sampleRate)
    }

    public func tag(_ key: String) -> String? {
        guard let value = tags[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// "3", "3/12" and "03" all become 3.
    public func number(_ key: String) -> Int? {
        guard let raw = tag(key) else { return nil }
        return Int(raw.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    public var year: Int? {
        guard let raw = tag("DATE") ?? tag("YEAR") ?? tag("ORIGINALDATE") else { return nil }
        return Int(raw.prefix(4))
    }
}

/// Parses FLAC metadata blocks from a prefix of the file.
public nonisolated enum FLACHeader {
    public static let initialRead: Int64 = 256 * 1024
    public static let maximumRead: Int64 = 8 * 1024 * 1024

    /// Offsets, including `neededPrefix`, count from the start of the file, before any ID3v2 tag.
    public static func parse(_ data: Data) -> FLACInfo? {
        let bytes = [UInt8](data)
        guard let streamStart = streamStart(in: bytes) else { return nil }
        var info = FLACInfo()
        if streamStart > 0, streamStart + 8 > bytes.count {
            // A long ID3v2 tag in front: the stream begins beyond this prefix.
            info.neededPrefix = streamStart + 8
            return info
        }
        guard streamStart + 8 <= bytes.count, bytes[streamStart] == 0x66, bytes[streamStart + 1] == 0x4C, bytes[streamStart + 2] == 0x61, bytes[streamStart + 3] == 0x43 else { return nil }
        var offset = streamStart + 4
        var pictureType: Int?
        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let isLast = header & 0x80 != 0
            let type = Int(header & 0x7F)
            let length = Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            let end = start + length
            if end > bytes.count {
                info.neededPrefix = end
                break
            }
            let block = Array(bytes[start..<end])
            switch type {
            case 0 where block.count >= 18:
                info.sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12] >> 4)
                info.channels = Int((block[12] >> 1) & 0x07) + 1
                info.bitsPerSample = Int((block[12] & 0x01) << 4 | (block[13] >> 4)) + 1
                info.totalSamples = Int64(block[13] & 0x0F) << 32 | Int64(block[14]) << 24 | Int64(block[15]) << 16 | Int64(block[16]) << 8 | Int64(block[17])
                info.hasStreamInfo = true
            case 4:
                info.tags.merge(parseVorbisComments(block)) { _, new in new }
                info.hasComments = true
            case 6:
                if let (kind, mime, picture) = parsePicture(block) {
                    // Prefer the front cover (type 3) over any other picture.
                    if info.picture == nil || (kind == 3 && pictureType != 3) {
                        info.picture = picture
                        info.pictureMIME = mime
                        pictureType = kind
                    }
                }
            default:
                break
            }
            offset = end
            if isLast { info.isComplete = true; break }
        }
        if !info.isComplete, info.neededPrefix == nil { info.neededPrefix = offset + 4 }
        return info
    }

    /// Where the FLAC stream starts: after any ID3v2 tags some taggers put in front of it, which
    /// players skip. Nil when an ID3v2 header is malformed.
    private static func streamStart(in bytes: [UInt8]) -> Int? {
        var offset = 0
        while offset + 10 <= bytes.count, bytes[offset] == 0x49, bytes[offset + 1] == 0x44, bytes[offset + 2] == 0x33 {
            let size = bytes[(offset + 6)..<(offset + 10)]
            guard size.allSatisfy({ $0 < 0x80 }) else { return nil }
            let length = size.reduce(0) { $0 << 7 | Int($1) }
            // Flag 0x10: a 10-byte footer follows the tag (ID3v2.4).
            let footer = bytes[offset + 5] & 0x10 != 0 ? 10 : 0
            offset += 10 + length + footer
        }
        return offset
    }

    /// Read metadata with bounded, monotonically increasing prefixes. By default every block must be
    /// read: a partial header must not become a tag-write verification. `requireAllBlocks: false` is
    /// for indexing, which needs only STREAMINFO and the comments: a picture too large for the bounded
    /// prefix, or a file cut short after them, then leaves out the rest instead of discarding both.
    public static func read(requireAllBlocks: Bool = true, read: (Range<Int64>) async throws -> Data) async throws -> FLACInfo? {
        var length = initialRead
        var previousCount = 0
        var usable: FLACInfo?
        while length <= maximumRead {
            try Task.checkCancellation()
            let data = try await read(0..<length)
            guard data.count > previousCount, let info = parse(data) else { return usable }
            if info.isComplete { return info }
            if !requireAllBlocks, info.hasStreamInfo, info.hasComments { usable = info }
            guard let needed = info.neededPrefix, needed > data.count, Int64(needed) <= maximumRead else { return usable }
            previousCount = data.count
            // Include space for following blocks, rather than making a request per tiny header.
            length = min(maximumRead, max(Int64(needed), min(maximumRead, length * 2)))
        }
        return usable
    }

    private static func parseVorbisComments(_ block: [UInt8]) -> [String: String] {
        var tags: [String: String] = [:]
        var offset = 0
        func readUInt32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) | Int(block[offset + 1]) << 8 | Int(block[offset + 2]) << 16 | Int(block[offset + 3]) << 24
            offset += 4
            return value
        }
        guard let vendorLength = readUInt32(), offset + vendorLength <= block.count else { return tags }
        offset += vendorLength
        guard let count = readUInt32() else { return tags }
        for _ in 0..<count {
            guard let length = readUInt32(), offset + length <= block.count else { break }
            let comment = String(decoding: block[offset..<offset + length], as: UTF8.self)
            offset += length
            guard let equals = comment.firstIndex(of: "=") else { continue }
            let key = comment[..<equals].uppercased()
            let value = String(comment[comment.index(after: equals)...])
            if tags[key] == nil { tags[key] = value }
        }
        return tags
    }

    private static func parsePicture(_ block: [UInt8]) -> (Int, String, Data)? {
        var offset = 0
        func readUInt32() -> Int? {
            guard offset + 4 <= block.count else { return nil }
            let value = Int(block[offset]) << 24 | Int(block[offset + 1]) << 16 | Int(block[offset + 2]) << 8 | Int(block[offset + 3])
            offset += 4
            return value
        }
        guard let kind = readUInt32(), let mimeLength = readUInt32(), offset + mimeLength <= block.count else { return nil }
        let mime = String(decoding: block[offset..<offset + mimeLength], as: UTF8.self)
        offset += mimeLength
        guard let descriptionLength = readUInt32(), offset + descriptionLength <= block.count else { return nil }
        offset += descriptionLength
        guard offset + 16 <= block.count else { return nil }
        offset += 16
        guard let dataLength = readUInt32(), dataLength > 0, offset + dataLength <= block.count else { return nil }
        return (kind, mime, Data(block[offset..<offset + dataLength]))
    }
}
