import Foundation
import Testing
@testable import GumboCore

/// An in-memory drive with the write half, recording every call so the swap order can be checked.
private actor ReplacementFixtureDrive: WritableRemoteDrive {
    let id = "replacement-fixture"
    let displayName = "Replacement fixture"
    var files: [String: Data]
    var calls: [String] = []
    /// A target name whose next rename fails, to simulate the swap going wrong half way; the
    /// rename that puts the original back afterwards succeeds.
    var failingRenameTarget: String?
    /// Bytes to drop from every upload, to simulate a transfer that did not arrive whole.
    var uploadShortfall = 0
    var replaceBeforeRename = false
    var failRollback = false
    var loseRenameResponse = false

    init(files: [String: Data]) {
        self.files = files
    }

    func setFailingRenameTarget(_ name: String?) { failingRenameTarget = name }
    func setLoseRenameResponse() { loseRenameResponse = true }
    func setRace() { replaceBeforeRename = true }
    func setFailRollback() { failRollback = true }
    func setUploadShortfall(_ bytes: Int) { uploadShortfall = bytes }

    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw URLError(.fileDoesNotExist) }
    nonisolated func streamURL(for path: String) -> URL? { nil }

    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        calls.append("read \(path) \(range.lowerBound)-\(range.upperBound)")
        guard let data = files[path] else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.Download") }
        let start = min(data.count, Int(range.lowerBound))
        let end = min(data.count, Int(range.upperBound))
        return data.subdata(in: start..<end)
    }

    func info(_ path: String) async throws -> RemoteEntry {
        calls.append("info \(path)")
        guard let data = files[path] else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.List") }
        return RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: Int64(data.count), modified: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func upload(_ file: URL, toFolder folder: String, name: String, modified: Date?) async throws {
        calls.append("upload \(folder)/\(name)")
        let data = try Data(contentsOf: file)
        files[folder + "/" + name] = data.dropLast(uploadShortfall)
    }

    func rename(_ path: String, to name: String) async throws {
        calls.append("rename \(path) -> \(name)")
        if path == songPath, replaceBeforeRename { files[path] = Data([9, 8, 7]); replaceBeforeRename = false }
        if failRollback, path.contains(".gumbo-backup") { throw RemoteWriteError.readOnly }
        if name == failingRenameTarget {
            failingRenameTarget = nil
            throw SynologyError.api(code: 1200, api: "SYNO.FileStation.Rename")
        }
        let target = (path as NSString).deletingLastPathComponent + "/" + name
        guard let data = files[path] else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.Rename") }
        guard files[target] == nil else { throw SynologyError.api(code: 414, api: "SYNO.FileStation.Rename") }
        files[path] = nil
        files[target] = data
        if loseRenameResponse { loseRenameResponse = false; throw URLError(.networkConnectionLost) }
    }

    func delete(_ path: String) async throws {
        calls.append("delete \(path)")
        guard files[path] != nil else { throw SynologyError.api(code: 408, api: "SYNO.FileStation.Delete") }
        files[path] = nil
    }
}

private nonisolated let songPath = "/music/Halden Vey/Nocturne Drift/03 Morning.mp3"
private nonisolated let temporaryPath = "/music/Halden Vey/Nocturne Drift/.03 Morning.mp3.gumbo-upload"
private nonisolated let backupPath = "/music/Halden Vey/Nocturne Drift/.03 Morning.mp3.gumbo-backup"
private nonisolated let oldBytes = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) })
private nonisolated let newBytes = Data((0..<3100).map { UInt8(truncatingIfNeeded: $0 &* 3) })

private nonisolated func withLocalFile(_ data: Data, _ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-replacement-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "patched.mp3")
    try data.write(to: url)
    try await body(url)
}

@Suite struct RemoteFileReplacementTests {
    @Test func replacementSwapsTheNewCopyInAndLeavesNothingBehind() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        try await withLocalFile(newBytes) { url in
            try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: Date(timeIntervalSince1970: 1_700_000_001))
        }
        let files = await drive.files
        #expect(files == [songPath: newBytes])
        let calls = await drive.calls
        let temporary = try #require(calls.first?.replacingOccurrences(of: "upload ", with: ""))
        let suffix = String(temporary.dropFirst(temporaryPath.count))
        #expect(UUID(uuidString: String(suffix.dropFirst())) != nil)
        let backup = backupPath + suffix
        #expect(calls == ["upload \(temporary)", "info \(temporary)",
            "rename \(songPath) -> \((backup as NSString).lastPathComponent)",
            "rename \(temporary) -> 03 Morning.mp3", "delete \(backup)"])

    }

    @Test func failedSwapPutsTheOriginalBackAndRemovesTheCopy() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        await drive.setFailingRenameTarget("03 Morning.mp3")
        await #expect(throws: SynologyError.self) {
            try await withLocalFile(newBytes) { url in
                try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: nil)
            }
        }
        let files = await drive.files
        #expect(files[songPath] == oldBytes)
        #expect(files[temporaryPath] == nil)
        #expect(files[backupPath] == nil)
        let calls = await drive.calls
        #expect(files == [songPath: oldBytes])
        #expect(calls.suffix(2).first?.hasPrefix("rename " + backupPath + "-") == true)
        #expect(calls.last?.hasPrefix("delete " + temporaryPath + "-") == true)
    }

    @Test func shortUploadIsDiscardedAndTheOriginalKept() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        await drive.setUploadShortfall(7)
        await #expect(throws: RemoteWriteError.incompleteTransfer) {
            try await withLocalFile(newBytes) { url in
                try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: nil)
            }
        }
        let files = await drive.files
        #expect(files == [songPath: oldBytes])
        let calls = await drive.calls
        #expect(!calls.contains { $0.hasPrefix("rename") })
    }

    @Test func unrelatedBackupFromAnEarlierAttemptIsPreserved() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes, backupPath: Data([1, 2, 3])])
        try await withLocalFile(newBytes) { url in
            try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: nil)
        }
        let files = await drive.files
        #expect(files == [songPath: newBytes, backupPath: Data([1, 2, 3])])
    }

    @Test func temporaryAndBackupNamesAreNeverIndexedAsMusic() {
        for name in [RemoteFileNames.temporary(for: "03 Morning.mp3"), RemoteFileNames.backup(for: "03 Morning.flac")] {
            let entry = RemoteEntry(path: "/music/" + name, name: name, isDirectory: false, size: 1, modified: nil)
            #expect(!entry.isAudio)
            #expect(!entry.isImage)
            #expect(name.hasPrefix("."))
        }
    }

    @Test func aChangeBetweenVersionCheckAndRenameIsRestoredInsteadOfOverwritten() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        let original = try await drive.info(songPath)
        await drive.setRace()
        await #expect(throws: RemoteWriteError.changed) {
            try await withLocalFile(newBytes) { url in
                try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: nil, expectedOriginal: original)
            }
        }
        #expect(await drive.files == [songPath: Data([9, 8, 7])])
    }

    @Test func aLostAcknowledgementAfterMovingTheOriginalStillRestoresIt() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        await drive.setLoseRenameResponse()
        await #expect(throws: URLError.self) {
            try await withLocalFile(newBytes) { url in
                try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: nil)
            }
        }
        #expect(await drive.files == [songPath: oldBytes])
    }

    @Test func failedRollbackKeepsTheBackupAndReportsItsLocation() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        await drive.setFailingRenameTarget("03 Morning.mp3")
        await drive.setFailRollback()
        do {
            try await withLocalFile(newBytes) { url in
                try await drive.replaceFile(at: songPath, with: url, expectedSize: Int64(newBytes.count), modified: nil)
            }
            Issue.record("Expected an interrupted swap")
        } catch RemoteWriteError.recoveryNeeded(let path) {
            #expect(path.hasPrefix(backupPath + "-"))
            #expect(await drive.files == [path: oldBytes])
        }
    }

    @Test func defaultDownloadCopiesExactlyTheBytesPromised() async throws {
        let drive = ReplacementFixtureDrive(files: [songPath: oldBytes])
        let directory = FileManager.default.temporaryDirectory.appending(path: "gumbo-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "original.mp3")
        try await drive.downloadFile(songPath, to: destination, maxBytes: Int64(oldBytes.count))
        #expect(try Data(contentsOf: destination) == oldBytes)
        await #expect(throws: RemoteDriveError.tooLarge) {
            try await drive.downloadFile(songPath, to: destination, maxBytes: Int64(oldBytes.count) - 1)
        }
    }

    @Test func writeDenialsAreRecognisedAcrossServerErrorCodes() {
        #expect(SynologyError.api(code: 407, api: "SYNO.FileStation.Upload").isWriteDenied)
        #expect(SynologyError.api(code: 411, api: "SYNO.FileStation.Rename").isWriteDenied)
        #expect(SynologyError.api(code: 105, api: "SYNO.FileStation.Upload").isWriteDenied)
        #expect(!SynologyError.api(code: 408, api: "SYNO.FileStation.List").isWriteDenied)
        #expect(!SynologyError.api(code: 119, api: "SYNO.FileStation.Upload").isWriteDenied)
        #expect(RemoteWriteError.readOnly.isWriteDenied)
        #expect(!RemoteWriteError.incompleteTransfer.isWriteDenied)
    }
}
