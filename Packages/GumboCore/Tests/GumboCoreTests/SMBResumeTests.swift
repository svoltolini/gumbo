import Foundation
import Testing
@testable import GumboCore

@Suite struct SMBResumeTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboSMBResume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test(arguments: [0, 1, 17, 200, 513])
    func verifiesEveryRetainedByteAndAppendsOnlyTheTail(retained: Int) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "partial")
        let remote = Data((0..<513).map { UInt8($0 % 251) })
        try remote.prefix(retained).write(to: file)
        var ranges: [Range<Int64>] = []
        let result = try VerifiedSMBTransfer.copy(size: 513, maximumChunk: 100, destination: file, checkCancellation: {}) { range in
            ranges.append(range)
            return remote.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        } progress: { _ in }
        #expect(result.verifiedPrefixBytes == Int64(retained))
        #expect(result.bytes == 513)
        #expect(ranges.first?.lowerBound == 0) // No skipped remote prefix based on metadata.
        #expect(try Data(contentsOf: file) == remote)
    }

    @Test(arguments: [0, 99, 200])
    func changedSameLengthPrefixIsReplacedWithoutMixingRepresentations(changedAt: Int) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "partial")
        let remote = Data(repeating: 7, count: 513)
        var previous = Data(remote.prefix(250)); previous[changedAt] = 9
        try previous.write(to: file)
        let result = try VerifiedSMBTransfer.copy(size: 513, maximumChunk: 100, destination: file, checkCancellation: {}) { range in
            remote.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        } progress: { _ in }
        #expect(result.verifiedPrefixBytes == Int64(changedAt / 100 * 100))
        #expect(try Data(contentsOf: file) == remote)
    }

    @Test func interruptionRetainsOnlyCompleteWrittenPrefixAndRetryRechecksIt() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "partial")
        let remote = Data(repeating: 6, count: 513)
        #expect(throws: SMBDriveError.disconnected) {
            try VerifiedSMBTransfer.copy(size: 513, maximumChunk: 100, destination: file, checkCancellation: {}) { range in
                if range.lowerBound == 200 { throw SMBDriveError.disconnected }
                return remote.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            } progress: { _ in }
        }
        #expect(try Data(contentsOf: file) == remote.prefix(200))
        let result = try VerifiedSMBTransfer.copy(size: 513, maximumChunk: 100, destination: file, checkCancellation: {}) { range in
            remote.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        } progress: { _ in }
        #expect(result.verifiedPrefixBytes == 200)
        #expect(try Data(contentsOf: file) == remote)
    }

    @Test func cancellationAfterReadNeverAppendsTheLateBytes() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "partial")
        var cancelled = false
        #expect(throws: CancellationError.self) {
            try VerifiedSMBTransfer.copy(size: 10, maximumChunk: 10, destination: file,
                                        checkCancellation: { if cancelled { throw CancellationError() } }) { _ in
                cancelled = true
                return Data(repeating: 1, count: 10)
            } progress: { _ in }
        }
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func checkpointScopeChangeDiscardsSavedBytesIncludingDeletionAndAccessEpoch() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ForegroundDownloadCheckpoint(cacheDirectory: root)
        let key = String(repeating: "a", count: 64)
        let original = ForegroundDownloadCheckpoint.Scope(sourceID: "nas", path: "/song", profileID: "one", accessEpoch: "login-1", deletionEpoch: nil)
        let first = try store.prepare(key: key, scope: original)
        try Data([1, 2, 3]).write(to: first)
        #expect(try Data(contentsOf: store.prepare(key: key, scope: original)) == Data([1, 2, 3]))
        for scope in [
            .init(sourceID: "other", path: "/song", profileID: "one", accessEpoch: "login-1", deletionEpoch: nil),
            .init(sourceID: "nas", path: "/changed", profileID: "one", accessEpoch: "login-1", deletionEpoch: nil),
            .init(sourceID: "nas", path: "/song", profileID: "two", accessEpoch: "login-1", deletionEpoch: nil),
            .init(sourceID: "nas", path: "/song", profileID: "one", accessEpoch: "login-2", deletionEpoch: nil),
            .init(sourceID: "nas", path: "/song", profileID: "one", accessEpoch: "login-1", deletionEpoch: "deleted"),
        ] as [ForegroundDownloadCheckpoint.Scope] {
            let file = try store.prepare(key: key, scope: scope)
            #expect(try Data(contentsOf: file).isEmpty)
            try Data([4]).write(to: file)
        }
        store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test(arguments: [false, true]) func rejectsCheckpointSymlinksWithoutTouchingTheirTarget(broken: Bool) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "untouched")
        if !broken { try Data([9]).write(to: target) }
        let file = root.appending(path: "partial")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: SMBDriveError.invalidPath) {
            try VerifiedSMBTransfer.copy(size: 1, maximumChunk: 1, destination: file, checkCancellation: {}) { _ in Data([1]) } progress: { _ in }
        }
        if broken { #expect(!FileManager.default.fileExists(atPath: target.path)) }
        else { #expect(try Data(contentsOf: target) == Data([9])) }
    }

    @Test func rejectsHardLinkedPayloadWithoutChangingOtherPath() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "untouched")
        let file = root.appending(path: "partial")
        try Data([9, 8, 7]).write(to: target)
        try FileManager.default.linkItem(at: target, to: file)
        #expect(throws: SMBDriveError.invalidPath) {
            try VerifiedSMBTransfer.copy(size: 1, maximumChunk: 1, destination: file, checkCancellation: {}) { _ in Data([1]) } progress: { _ in }
        }
        #expect(try Data(contentsOf: target) == Data([9, 8, 7]))
    }

    @Test(arguments: ["oversized", "symlink", "hardlink", "directory"])
    func unsafeDescriptorIsRecreatedWithoutFollowingOrChangingTarget(kind: String) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ForegroundDownloadCheckpoint(cacheDirectory: root)
        let key = String(repeating: "d", count: 64)
        let scope = ForegroundDownloadCheckpoint.Scope(sourceID: "nas", path: "/song", profileID: "one", accessEpoch: "epoch", deletionEpoch: nil)
        let file = try store.prepare(key: key, scope: scope)
        try Data([1, 2, 3]).write(to: file)
        let descriptor = file.deletingLastPathComponent().appending(path: "scope.json")
        let original = try JSONEncoder().encode(scope)
        let target = root.appending(path: "untouched")
        try original.write(to: target)
        try FileManager.default.removeItem(at: descriptor)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: descriptor, withDestinationURL: target)
        case "hardlink": try FileManager.default.linkItem(at: target, to: descriptor)
        case "directory": try FileManager.default.createDirectory(at: descriptor, withIntermediateDirectories: false)
        default: try Data(repeating: 65, count: 16 * 1024 + 1).write(to: descriptor)
        }
        #expect(try Data(contentsOf: store.prepare(key: key, scope: scope)).isEmpty)
        #expect(try Data(contentsOf: target) == original)
    }
}

private actor CheckpointDrive: ResumableRemoteFileDrive {
    nonisolated let id = "resume-nas"
    nonisolated let displayName = "Generated fixture"
    let bytes: Data
    let interruptFirst: Bool
    let suspendFirst: Bool
    let ignoresCancellation: Bool
    private var suspended: CheckedContinuation<Void, Never>?
    private(set) var prefixes: [Int] = []
    init(byte: UInt8 = 5, interruptFirst: Bool = false, suspendFirst: Bool = false, ignoresCancellation: Bool = false) {
        bytes = Data(repeating: byte, count: 513); self.interruptFirst = interruptFirst; self.suspendFirst = suspendFirst
        self.ignoresCancellation = ignoresCancellation
    }
    var isSuspended: Bool { suspended != nil }
    func release() { suspended?.resume(); suspended = nil }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry { RemoteEntry(path: path, name: "song.flac", isDirectory: false, size: 513, modified: nil) }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { bytes }
    nonisolated func streamURL(for path: String) -> URL? { nil }
    func copyVerified(_ path: String, to file: URL, expectedBytes: Int64?, progress: @escaping @Sendable (Double) async -> Void) async throws -> Int64 {
        prefixes.append((try? Data(contentsOf: file).count) ?? 0)
        if (interruptFirst || suspendFirst) && prefixes.count == 1 {
            try bytes.prefix(200).write(to: file)
            if suspendFirst {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                await withCheckedContinuation { suspended = $0 }
                if ignoresCancellation {
                    // Simulate a blocking native operation returning after access was revoked.
                    // Its open fd survives unlink, but must never publish into the new retry.
                    try handle.seek(toOffset: 0); try handle.write(contentsOf: bytes)
                    return Int64(bytes.count)
                }
                try Task.checkCancellation()
            }
            throw SMBDriveError.disconnected
        }
        let result = try VerifiedSMBTransfer.copy(size: 513, maximumChunk: 100, destination: file, checkCancellation: { try Task.checkCancellation() }) { range in
            bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        } progress: { _ in }
        await progress(1)
        return result.bytes
    }
}

@Suite @MainActor struct ForegroundCheckpointTests {
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Checkpoint transfer did not settle"); throw CancellationError()
    }
    private func manager(_ directory: URL, drive: CheckpointDrive) -> DownloadManager {
        let manager = DownloadManager(directory: directory, configuration: .ephemeral, restoreTasks: { _, completion in completion([]) })
        manager.activeProfileID = "listener"
        manager.driveIDProvider = { drive.id }
        manager.remoteSourceProvider = { _ in .file(drive: drive, path: "/song.flac") }
        return manager
    }
    private func album() -> Album {
        var value = SampleLibrary.catalogue.albums[0]
        value.tracks = Array(value.tracks.prefix(1)); value.tracks[0].fileSize = 513
        return value
    }

    @Test(arguments: [false, true])
    func failedTransferReusesVerifiedPrefixAfterRetryOrRelaunch(relaunch: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = CheckpointDrive(interruptFirst: true)
        let first = manager(root.appending(path: "first"), drive: drive)
        let owner = first.owner(for: album())
        first.download(owner, driveID: drive.id) { _ in nil }
        try await wait { if case .failed = first.state(for: owner) { return true }; return false }
        #expect(first.records.isEmpty)
        let retry: DownloadManager
        let next: CheckpointDrive
        if relaunch {
            try FileManager.default.copyItem(at: root.appending(path: "first"), to: root.appending(path: "second"))
            next = CheckpointDrive(byte: 8) // Same size, different representation: old prefix must be replaced.
            retry = manager(root.appending(path: "second"), drive: next)
        } else { next = drive; retry = first }
        retry.download(owner, driveID: next.id) { _ in nil }
        try await wait { retry.state(for: owner) == .downloaded }
        #expect(await next.prefixes.last == 200)
        let file = try #require(retry.localURL(for: owner.tracks[0]))
        #expect(try Data(contentsOf: file) == Data(repeating: relaunch ? 8 : 5, count: 513))
    }

    @Test(arguments: ["cancel", "remove", "revoke", "delete"])
    func accessAndOwnershipChangesDiscardInterruptedCheckpoint(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = CheckpointDrive(interruptFirst: true)
        let downloads = manager(root, drive: drive)
        let owner = downloads.owner(for: album())
        downloads.download(owner, driveID: drive.id) { _ in nil }
        try await wait { if case .failed = downloads.state(for: owner) { return true }; return false }
        switch action {
        case "cancel": downloads.cancel(owner)
        case "remove": downloads.remove(owner)
        case "revoke": downloads.revokeForegroundDownloads()
        default: downloads.removeServerTracks(sourceID: drive.id, trackIDs: [owner.tracks[0].id])
        }
        downloads.download(owner, driveID: drive.id) { _ in nil }
        try await wait { downloads.state(for: owner) == .downloaded }
        #expect(await drive.prefixes == [0, 0])
    }

    @Test func pausedJobSurvivesProcessRestorationWithoutBecomingCompletedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = CheckpointDrive(suspendFirst: true)
        let first = manager(root.appending(path: "first"), drive: drive)
        let owner = first.owner(for: album())
        first.download(owner, driveID: drive.id) { _ in nil }
        try await wait { await drive.isSuspended }
        first.setForegroundDownloadsActive(false)
        await drive.release()
        try await wait { first.isQueued(owner.tracks[0]) }
        try FileManager.default.copyItem(at: root.appending(path: "first"), to: root.appending(path: "restored"))
        first.cancel(owner)
        let next = CheckpointDrive()
        let restored = manager(root.appending(path: "restored"), drive: next)
        try await wait { !restored.state(for: owner).isDownloading }
        #expect(restored.records.isEmpty)
        #expect(restored.localURL(for: owner.tracks[0]) == nil)
        restored.refreshUnusedStorage()
        restored.download(owner, driveID: next.id) { _ in nil }
        try await wait { restored.state(for: owner) == .downloaded }
        #expect(await next.prefixes == [200])
    }

    @Test func revokedLateCompletionCannotTouchImmediateRetryCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = CheckpointDrive(suspendFirst: true, ignoresCancellation: true)
        let replacement = CheckpointDrive(byte: 9)
        let downloads = manager(root, drive: old)
        let owner = downloads.owner(for: album())
        downloads.download(owner, driveID: old.id) { _ in nil }
        try await wait { await old.isSuspended }
        downloads.revokeForegroundDownloads()
        downloads.remoteSourceProvider = { _ in .file(drive: replacement, path: "/song.flac") }
        downloads.download(owner, driveID: replacement.id) { _ in nil }
        #expect(await replacement.prefixes.isEmpty)
        #expect(downloads.records.isEmpty)
        await old.release()
        try await wait { downloads.state(for: owner) == .downloaded }
        #expect(await replacement.prefixes == [0])
        #expect(try Data(contentsOf: #require(downloads.localURL(for: owner.tracks[0]))) == Data(repeating: 9, count: 513))
        let folder = ForegroundDownloadCheckpoint(cacheDirectory: root).directory
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) != false)
    }

    @Test func discardReportsFailedBytesAndPreservesActiveWorkAndCompletedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let complete = CheckpointDrive(byte: 7)
        let downloads = manager(root, drive: complete)
        var completedAlbum = SampleLibrary.catalogue.albums[1]
        completedAlbum.tracks = Array(completedAlbum.tracks.prefix(1)); completedAlbum.tracks[0].fileSize = 513
        let saved = downloads.owner(for: completedAlbum)
        downloads.download(saved, driveID: complete.id) { _ in nil }
        try await wait { downloads.state(for: saved) == .downloaded }
        let completedFile = try #require(downloads.localURL(for: saved.tracks[0]))
        let failed = CheckpointDrive(interruptFirst: true)
        downloads.remoteSourceProvider = { _ in .file(drive: failed, path: "/failed.flac") }
        let interrupted = downloads.owner(for: album())
        downloads.download(interrupted, driveID: failed.id) { _ in nil }
        try await wait { if case .failed = downloads.state(for: interrupted) { return true }; return false }
        #expect(downloads.retainedPartialBytes == 200)
        let held = CheckpointDrive(suspendFirst: true, ignoresCancellation: true)
        var activeAlbum = SampleLibrary.catalogue.albums[2]
        activeAlbum.tracks = Array(activeAlbum.tracks.prefix(1)); activeAlbum.tracks[0].fileSize = 513
        let active = downloads.owner(for: activeAlbum)
        downloads.remoteSourceProvider = { _ in .file(drive: held, path: "/active.flac") }
        downloads.download(active, driveID: held.id) { _ in nil }
        try await wait { await held.isSuspended }
        downloads.discardInterruptedDownloads()
        #expect(downloads.retainedPartialBytes == 0)
        #expect(downloads.state(for: active).isDownloading)
        #expect(try Data(contentsOf: completedFile) == Data(repeating: 7, count: 513))
        await held.release()
        try await wait { downloads.state(for: active) == .downloaded }
        #expect(try Data(contentsOf: #require(downloads.localURL(for: active.tracks[0]))) == Data(repeating: 5, count: 513))
        downloads.remoteSourceProvider = { _ in .file(drive: failed, path: "/failed.flac") }
        downloads.download(interrupted, driveID: failed.id) { _ in nil }
        try await wait { downloads.state(for: interrupted) == .downloaded }
        #expect(await failed.prefixes == [0, 0])
    }
}
