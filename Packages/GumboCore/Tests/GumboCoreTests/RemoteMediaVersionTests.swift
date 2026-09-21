import AVFoundation
import Foundation
import Testing
@testable import GumboCore

private actor ReplacedMediaDrive: RemoteFileDrive {
    nonisolated let id = "replaced-media"
    nonisolated let displayName = "Fixture"
    let bytes: Data
    var version = "first"
    var readVersions: [String?] = []
    var metadataReads = 0
    init() {
        var audio = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { audio.append(contentsOf: $0) }
        }
        append(UInt32(36 + 16_000)); audio.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000))
        append(UInt16(2)); append(UInt16(16)); audio.append(Data("data".utf8)); append(UInt32(16_000))
        audio.append(Data(repeating: 0, count: 16_000))
        bytes = audio
    }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry {
        metadataReads += 1
        return .init(path: path, name: "audio.wav", isDirectory: false, size: Int64(bytes.count), modified: .distantPast, version: version)
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        Issue.record("The media loader bypassed the version condition")
        return bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func read(_ path: String, range: Range<Int64>, matching entry: RemoteEntry) async throws -> Data {
        readVersions.append(entry.version)
        guard entry.version == version else { throw ProviderError.changed }
        let result = bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        // Replace between AVFoundation's initial content-info request and its decoder request.
        // Size/time are deliberately identical so only a pinned strong version detects this.
        version = "replacement"
        return result
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { bytes }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

@Suite struct RemoteMediaVersionTests {
    @Test func oneAssetNeverAcceptsAReplacementVersionDuringLaterDecoderRequests() async throws {
        let drive = ReplacedMediaDrive()
        let first = await MediaProbe.probe(source: .file(drive: drive, path: "/audio.wav"))
        #expect(first.duration == nil && first.sampleRate == nil)
        let versions = await drive.readVersions
        #expect(versions.count >= 2)
        #expect(versions.allSatisfy { $0 == "first" })
        #expect(await drive.metadataReads == 1)
        // A deliberate new playback/probe can select the newly current file safely.
        let replacement = await MediaProbe.probe(source: .file(drive: drive, path: "/audio.wav"))
        #expect(replacement.duration == 1)
        #expect(replacement.sampleRate == 8_000)
        #expect(await drive.metadataReads == 2)
    }
}
