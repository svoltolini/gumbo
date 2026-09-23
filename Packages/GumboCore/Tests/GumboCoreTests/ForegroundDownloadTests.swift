import Foundation
import Testing
@testable import GumboCore

/// Each held read is released explicitly, including providers that unwind cancellation late.
private actor HeldDownloadDrive: RemoteFileDrive {
    nonisolated let id = "foreground-nas"
    nonisolated let displayName = "Fixture"
    let data: Data
    private var heldCalls: Set<Int>
    private var continuations: [Int: CheckedContinuation<Resolution, Never>] = [:]
    private(set) var calls = 0
    enum Resolution: Sendable { case data, cancelled, urlCancelled }

    init(byte: UInt8 = 42, heldCalls: Set<Int> = [1, 3]) {
        data = Data(repeating: byte, count: 2_500_001)
        self.heldCalls = heldCalls
    }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { [] }
    func info(_ path: String) async throws -> RemoteEntry {
        RemoteEntry(path: path, name: "song.flac", isDirectory: false, size: Int64(data.count), modified: .distantPast)
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        calls += 1
        let call = calls
        if heldCalls.contains(call) {
            switch await withCheckedContinuation({ continuations[call] = $0 }) {
            case .cancelled: throw CancellationError()
            case .urlCancelled: throw URLError(.cancelled)
            case .data: break
            }
        }
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func release(_ call: Int, as resolution: Resolution) { continuations.removeValue(forKey: call)?.resume(returning: resolution) }
    func releaseAll() { for call in Array(continuations.keys) { release(call, as: .cancelled) } }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { data }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

@MainActor private func awaitForeground(_ condition: () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Foreground transfer did not reach the expected checkpoint")
    throw CancellationError()
}

@MainActor private func foregroundAlbum(count: Int = 1) -> Album {
    var album = SampleLibrary.catalogue.albums[0]
    album.tracks = Array(album.tracks.prefix(count))
    for index in album.tracks.indices { album.tracks[index].fileSize = 2_500_001 }
    return album
}

@MainActor private func foregroundManager(directory: URL, drive: HeldDownloadDrive) -> DownloadManager {
    let manager = DownloadManager(directory: directory, configuration: .ephemeral, restoreTasks: { _, completion in completion([]) })
    manager.activeProfileID = "listener"
    manager.driveIDProvider = { drive.id }
    manager.remoteSourceProvider = { _ in .file(drive: drive, path: "/song.flac") }
    return manager
}

@Suite @MainActor struct ForegroundDownloadTests {
    @Test(arguments: ["signOut", "server", "profile"], [1, 4])
    func accessChangeRevokesCurrentAndQueuedFilesWithoutLosingCompletedSongs(_ change: String, heldRead: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboForeground-\(UUID())")
        let suite = "GumboForegroundAccess.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(3, forKey: "coverCacheVersion")
        var services = ConnectionServices()
        services.observeNetwork = { _ in {} }
        services.deleteCatalogue = {}
        services.password = { _ in nil }
        services.deletePassword = { _ in }
        services.supportsCredentialSync = { false }
        services.log = { _ in }
        let model = AppModel(library: LibraryStore(), defaults: defaults, services: services, restoresSession: false)
        let profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults)
        let drive = HeldDownloadDrive(heldCalls: [heldRead])
        let replacement = HeldDownloadDrive(byte: 70, heldCalls: [])
        let manager = foregroundManager(directory: directory.appending(path: "downloads"), drive: drive)
        // The same synchronous integration hooks used by all three app entry points.
        model.onConnectionWillChange = { [weak manager] in manager?.revokeForegroundDownloads() }
        profiles.onDeactivate = { [weak manager] in manager?.revokeForegroundDownloads() }
        // Foreground downloads belong to an open profile; locking with none open deactivates nothing.
        #expect(profiles.activate(try #require(profiles.owner)))
        let album = foregroundAlbum(count: 3)
        let owner = manager.owner(for: album)
        _ = manager.reconcile(albums: [album.id], playlists: [], driveID: drive.id,
                              album: { _ in album }, playlist: { _ in nil })
        manager.download(owner, driveID: drive.id) { _ in nil }
        try await awaitForeground { await drive.calls == heldRead }
        let completedBefore = heldRead == 4 ? 1 : 0
        #expect(manager.records.count == completedBefore)
        switch change {
        case "signOut": await model.signOut()
        case "server": model.select(DiscoveredServer(name: "Other NAS", baseURL: URL(string: "https://other.example")!, model: nil))
        default: profiles.lock()
        }
        #expect(manager.state(for: owner) == .cancelled(done: completedBefore, total: 3))
        #expect(manager.pendingByOwner.isEmpty)
        #expect(manager.listedOwnerIDs.contains(owner.id))
        #expect(manager.downloadMembership(driveID: drive.id).albums.contains(album.id))
        #expect(manager.records.count == completedBefore)
        #expect(manager.lastError == nil)

        // A retry with newly authenticated credentials must wait for the cancelled read to unwind.
        manager.remoteSourceProvider = { _ in .file(drive: replacement, path: "/song.flac") }
        manager.download(owner, driveID: replacement.id) { _ in nil }
        #expect(await replacement.calls == 0)
        await drive.release(heldRead, as: .data) // The old provider ignores cancellation and returns bytes.
        try await awaitForeground { manager.state(for: owner) == .downloaded }
        #expect(await drive.calls == heldRead) // No next chunk or queued song uses the revoked connection.
        #expect(await replacement.calls == (3 - completedBefore) * 3)
        for (index, track) in owner.tracks.enumerated() {
            let file = try #require(manager.localURL(for: track))
            #expect(try Data(contentsOf: file) == Data(repeating: index < completedBefore ? 42 : 70, count: 2_500_001))
        }
    }

    @Test func revocationKeepsUnstartedHTTPBackgroundWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboForeground-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let drive = HeldDownloadDrive(heldCalls: [1])
        var started: [URLSessionDownloadTask] = []
        let manager = DownloadManager(directory: directory, configuration: .ephemeral,
            restoreTasks: { _, completion in completion([]) }, resumeTask: { started.append($0) })
        manager.activeProfileID = "listener"
        manager.driveIDProvider = { drive.id }
        manager.remoteSourceProvider = { _ in .file(drive: drive, path: "/song.flac") }
        let fileOwner = manager.owner(for: foregroundAlbum())
        manager.download(fileOwner, driveID: drive.id) { _ in nil }
        try await awaitForeground { await drive.calls == 1 }
        var httpAlbum = foregroundAlbum(count: 2)
        httpAlbum.tracks.removeFirst()
        let httpOwner = DownloadOwner(playlist: Playlist(id: "http", name: "HTTP", summary: "", covers: [], tracks: httpAlbum.tracks), profileID: "listener")
        manager.remoteSourceProvider = nil
        manager.download(httpOwner, driveID: drive.id) { _ in URL(string: "https://nas.example/never-requested")! }
        manager.revokeForegroundDownloads()
        #expect(manager.state(for: fileOwner) == .cancelled(done: 0, total: 1))
        #expect(manager.state(for: httpOwner).isDownloading)
        await drive.release(1, as: .data)
        try await awaitForeground { started.count == 1 }
        #expect(manager.state(for: httpOwner).isDownloading)
        #expect(manager.records.isEmpty)
        manager.cancel(httpOwner)
    }

    @Test(arguments: [false, true]) func rapidResumeRetainsPauseIntentAndPublishesProgress(urlCancellation: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboForeground-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let drive = HeldDownloadDrive()
        let manager = foregroundManager(directory: directory, drive: drive)
        let owner = manager.owner(for: foregroundAlbum())
        manager.download(owner, driveID: drive.id) { _ in nil }
        try await awaitForeground { await drive.calls == 1 }
        manager.setForegroundDownloadsActive(false)
        manager.setForegroundDownloadsActive(true) // Before the cancelled read has unwound.
        await drive.release(1, as: urlCancellation ? .urlCancelled : .cancelled)
        try await awaitForeground { await drive.calls == 3 }
        if case .downloading(let progress, let done, _) = manager.state(for: owner) {
            #expect(progress > 0 && progress < 1)
            #expect(done == 0)
        } else { Issue.record("A resumed transfer should still be downloading") }
        #expect(manager.records.isEmpty)
        #expect(manager.lastError == nil)
        await drive.release(3, as: .data)
        try await awaitForeground { manager.state(for: owner) == .downloaded }
        let file = try #require(manager.localURL(for: owner.tracks[0]))
        #expect(try Data(contentsOf: file) == Data(repeating: 42, count: 2_500_001))
    }

    @Test func pausedTransferWaitsUntilActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboForeground-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let drive = HeldDownloadDrive(heldCalls: [1])
        let manager = foregroundManager(directory: directory, drive: drive)
        let owner = manager.owner(for: foregroundAlbum())
        manager.download(owner, driveID: drive.id) { _ in nil }
        try await awaitForeground { await drive.calls == 1 }
        manager.setForegroundDownloadsActive(false)
        await drive.release(1, as: .urlCancelled)
        try await awaitForeground { manager.isQueued(owner.tracks[0]) }
        #expect(await drive.calls == 1)
        #expect(manager.records.isEmpty)
        #expect(manager.state(for: owner).isDownloading)
        manager.setForegroundDownloadsActive(true)
        try await awaitForeground { manager.state(for: owner) == .downloaded }
    }

    @Test func cancelledOldReadCannotPublishIntoNewRetryOrOtherProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GumboForeground-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldDrive = HeldDownloadDrive(heldCalls: [1])
        let replacement = HeldDownloadDrive(byte: 70, heldCalls: [])
        let manager = foregroundManager(directory: directory, drive: oldDrive)
        let owner = manager.owner(for: foregroundAlbum())
        manager.download(owner, driveID: oldDrive.id) { _ in nil }
        try await awaitForeground { await oldDrive.calls == 1 }
        manager.cancel(owner)
        manager.remoteSourceProvider = { _ in .file(drive: replacement, path: "/song.flac") }
        manager.download(owner, driveID: replacement.id) { _ in nil }
        manager.activeProfileID = "other-listener"
        manager.driveIDProvider = { "other-nas" }
        await oldDrive.release(1, as: .data) // Late, cancellation-ignoring response.
        try await awaitForeground { manager.records.count == 1 }
        #expect(manager.localURL(for: owner.tracks[0]) == nil)
        let record = try #require(manager.records.values.first)
        #expect(record.driveID == replacement.id)
        #expect(record.owners == [owner.id])
        manager.activeProfileID = "listener"
        manager.driveIDProvider = { replacement.id }
        #expect(manager.state(for: owner) == .downloaded)
        #expect(try Data(contentsOf: #require(manager.localURL(for: owner.tracks[0]))) == Data(repeating: 70, count: 2_500_001))
    }

    @Test func interruptedForegroundIntentRemainsVisibleAndRetryableAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GumboForeground-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "before")
        let restoredDirectory = root.appending(path: "restored")
        let drive = HeldDownloadDrive(heldCalls: [1])
        let manager = foregroundManager(directory: directory, drive: drive)
        let owner = manager.owner(for: foregroundAlbum())
        manager.download(owner, driveID: drive.id) { _ in nil }
        try await awaitForeground { await drive.calls == 1 }
        manager.setForegroundDownloadsActive(false)
        await drive.release(1, as: .cancelled)
        try await awaitForeground { manager.isQueued(owner.tracks[0]) }
        try FileManager.default.copyItem(at: directory, to: restoredDirectory)
        manager.cancel(owner)
        let restoredDrive = HeldDownloadDrive(heldCalls: [])
        let restored = foregroundManager(directory: restoredDirectory, drive: restoredDrive)
        try await awaitForeground { !restored.state(for: owner).isDownloading }
        if case .failed(let error) = restored.state(for: owner) { #expect(error.contains("interrupted")) }
        else { Issue.record("Unfinished foreground work should restore as an explicit retry") }
        #expect(restored.listedOwnerIDs.contains(owner.id))
        #expect(restored.localURL(for: owner.tracks[0]) == nil)
        #expect(restored.pendingByOwner.isEmpty)
        #expect(await restoredDrive.calls == 0)
        restored.download(owner, driveID: restoredDrive.id) { _ in nil }
        try await awaitForeground { restored.state(for: owner) == .downloaded }
    }
}
