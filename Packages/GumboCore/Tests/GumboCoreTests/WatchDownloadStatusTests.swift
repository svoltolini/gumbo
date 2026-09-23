import Foundation
import Testing
@testable import GumboCore

@Suite struct WatchDownloadStatusTests {
    private func track(_ id: String, bytes: Int64 = 20) -> WatchTrack {
        WatchTrack(id: id, title: id, artist: "Artist", album: "Album", duration: 120, path: "/music/\(id).flac",
                   fileSize: bytes, format: "FLAC", isLossless: true)
    }

    private func playlist(_ tracks: [WatchTrack]) -> WatchPlaylist {
        WatchPlaylist(id: "recent", name: "Recently played", isSmart: true, coverColours: [], tracks: tracks,
                      totalSongs: tracks.count, driveID: "nas-a", profileID: "profile-a")
    }

    private func manifest(desired: Set<String>, files: [String] = []) -> WatchDownloadManifest {
        var manifest = WatchDownloadManifest()
        manifest.desired = desired
        for id in files { manifest.files[id] = UUID().uuidString + "/\(id).flac" }
        return manifest
    }

    // MARK: Status (#246)

    @Test func aPlaylistWithOneSongMissingIsPartialNotFailed() {
        let ids: Set<String> = ["a", "b", "c"]
        let saved = manifest(desired: ["a", "b"], files: ["a", "b"])
        let status = WatchDownloadStatus.resolve(trackIDs: ids, manifest: saved, validated: ["a", "b"], pending: nil, error: nil)
        #expect(status == .partial(available: 2, total: 3, message: nil))
    }

    @Test func aPartialDownloadKeepsItsErrorAlongsideThePlayableSongs() {
        let status = WatchDownloadStatus.resolve(trackIDs: ["a", "b"], manifest: manifest(desired: ["a", "b"], files: ["a"]),
                                                 validated: ["a"], pending: [], error: "Server answered 500")
        #expect(status == .partial(available: 1, total: 2, message: "Server answered 500"))
    }

    @Test func statusCoversCompleteRunningFailedAndAbsentDownloads() {
        let ids: Set<String> = ["a", "b"]
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: nil, validated: [], pending: nil, error: nil) == .none)
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: manifest(desired: ids, files: ["a", "b"]),
                                            validated: ids, pending: nil, error: "old") == .downloaded)
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: manifest(desired: ids, files: ["a"]),
                                            validated: ["a"], pending: ["b"], error: nil) == .downloading(done: 1, total: 2))
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: manifest(desired: ids),
                                            validated: [], pending: nil, error: "Offline") == .failed("Offline"))
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: manifest(desired: ids, files: ["a"]),
                                            validated: [], pending: nil, error: nil) == .failed("Download again to finish."))
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: manifest(desired: ids),
                                            validated: [], pending: nil, error: nil) == .none)
        // Saved songs that left the playlist do not count towards it.
        #expect(WatchDownloadStatus.resolve(trackIDs: ids, manifest: manifest(desired: ids, files: ["z"]),
                                            validated: ["z"], pending: nil, error: nil) == .failed("Download again to finish."))
    }

    @Test func songRowsMapToSavedFilesByOccurrence() {
        let a = track("a"), b = track("b"), c = track("c")
        let list = playlist([a, b, a, c])
        #expect(list.playbackPositions(available: [a, a, c]) == [0, nil, 1, 2])
        #expect(list.playbackPositions(available: [b]) == [nil, 0, nil, nil])
        #expect(list.playbackPositions(available: []) == [nil, nil, nil, nil])
        #expect(list.playbackPositions(available: [a, b, a, c]) == [0, 1, 2, 3])
    }

    // MARK: Validation cache (#248)

    @Test func validationRunsOncePerFileUntilForgotten() {
        var cache = WatchFileValidationCache()
        var checks = 0
        let url = URL(fileURLWithPath: "/tmp/watch/one.flac")
        let other = URL(fileURLWithPath: "/tmp/watch/two.flac")
        let check: (URL, Int64?) -> Bool = { url, _ in checks += 1; return url.lastPathComponent == "one.flac" }
        // Mutating calls stay outside #expect, which evaluates its expression in a closure.
        var answers: [Bool] = []
        func ask(_ file: URL, _ bytes: Int64 = 20) { answers.append(cache.isValid(file, expectedBytes: bytes, check: check)) }

        ask(url); ask(url); ask(other); ask(other)
        #expect(answers == [true, true, false, false])
        #expect(checks == 2)
        // A different expected size is a different question.
        ask(url, 21)
        #expect(answers.last == true)
        #expect(checks == 3)
        cache.forget(url)
        ask(url); ask(other)
        #expect(answers.suffix(2) == [true, false])
        #expect(checks == 4)
        cache.removeAll()
        ask(other)
        #expect(answers.last == false)
        #expect(checks == 5)
    }

    @Test func manifestQueriesUseTheSuppliedValidator() {
        let list = playlist([track("a"), track("b")])
        let saved = manifest(desired: ["a", "b"], files: ["a", "b"])
        let root = URL(fileURLWithPath: "/nonexistent-watch-root")
        // Nothing exists on disk; the injected check alone decides.
        #expect(saved.validatedFileIDs(for: list, root: root).isEmpty)
        #expect(saved.validatedFileIDs(for: list, root: root) { _, _ in true } == ["a", "b"])
        #expect(saved.availableFiles(for: list, root: root) { url, _ in url.lastPathComponent == "a.flac" }.map(\.track.id) == ["a"])
        #expect(saved.outstandingTrackIDs(for: list, root: root) { _, _ in true }.isEmpty)
        var pruned = saved
        let removed = pruned.pruneInvalidFiles(for: list, root: root) { url, _ in url.lastPathComponent == "a.flac" }
        #expect(removed == ["b"])
        #expect(Set(pruned.files.keys) == ["a"])
    }

    // MARK: Following an edit during a download (#247)

    @Test func aSongJoiningDuringADownloadIsRequestedWithoutRestartingTheRest() {
        let generation = UUID()
        let before = playlist([track("a"), track("b"), track("c")])
        let after = playlist([track("new"), track("a"), track("b"), track("c")])
        let plan = WatchDownloadRetarget(previous: before, current: after, pending: ["b", "c"], available: ["a"], generation: generation)
        #expect(plan.kept == ["b", "c"])
        #expect(plan.added.map(\.id) == ["new"])
    }

    @Test func removedAndChangedSongsStopWhileFailedSongsAreNotRetried() {
        let generation = UUID()
        let before = playlist([track("a"), track("b"), track("c"), track("d")])
        // "b" left, "c" changed size on the server, "d" failed earlier and is not pending.
        let after = playlist([track("a"), track("c", bytes: 40), track("d")])
        let plan = WatchDownloadRetarget(previous: before, current: after, pending: ["b", "c"], available: ["a"], generation: generation)
        #expect(plan.kept.isEmpty)
        #expect(plan.added.isEmpty)
    }

    @Test func aSavedOrPendingSongIsNeverRequestedAgain() {
        let generation = UUID()
        let before = playlist([track("a")])
        let after = playlist([track("a"), track("b"), track("c"), track("b")])
        let plan = WatchDownloadRetarget(previous: before, current: after, pending: ["a"], available: ["c"], generation: generation)
        #expect(plan.kept == ["a"])
        #expect(plan.added.map(\.id) == ["b"])
    }

    @Test func withoutTheEarlierPlaylistOnlyPresentTransfersContinue() {
        let after = playlist([track("a"), track("b")])
        let plan = WatchDownloadRetarget(previous: nil, current: after, pending: ["a", "gone"], available: [], generation: UUID())
        #expect(plan.kept == ["a"])
        #expect(plan.added.isEmpty)
    }

    @Test func transfersCountOnlyWhileTheyMatchTheCurrentCatalogue() throws {
        let generation = UUID()
        let list = playlist([track("a"), track("b")])
        let job = try #require(WatchDownloadJob(playlist: list, track: list.tracks[0], generation: generation))
        var catalogue = WatchCatalogue(serverName: "NAS", profileName: "Me", playlists: [list])
        #expect(catalogue.isCurrent(job))
        catalogue.playlists = [playlist([track("a", bytes: 40), track("b")])]
        #expect(!catalogue.isCurrent(job), "A changed song must not be completed by its older transfer")
        catalogue.playlists = [playlist([track("b")])]
        #expect(!catalogue.isCurrent(job))
        catalogue.playlists = []
        #expect(!catalogue.isCurrent(job))
    }
}
