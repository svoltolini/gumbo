import Foundation
import Testing
@testable import GumboCore

@Suite struct DownloadFileRevisionTests {
    @Test func detectsFileChangesButIgnoresPresentationAndFirstEnrichment() throws {
        var original = SampleLibrary.catalogue.albums[0].tracks[0]
        original.isEnriched = true
        original.sourceVersion = "first"
        original.sourceModifiedAt = 1_000
        original.genreTag = "Rock"
        let revision = DownloadFileRevision(track: original)
        #expect(try JSONDecoder().decode(DownloadFileRevision.self, from: JSONEncoder().encode(revision)) == revision)
        var changed = original
        changed.albumID = "regrouped"
        changed.title = "Shorter display title"
        changed.tagVersion = 99
        #expect(revision.matches(DownloadFileRevision(track: changed)))
        changed.sourceVersion = "second"
        #expect(!revision.matches(DownloadFileRevision(track: changed)))
        changed = original
        changed.sourceModifiedAt = 1_001
        #expect(!revision.matches(DownloadFileRevision(track: changed)))
        changed = original
        changed.genreTag = "Jazz"
        #expect(!revision.matches(DownloadFileRevision(track: changed)))
        changed = original
        changed.isEnriched = false
        changed.sourceModifiedAt = nil
        changed.sourceVersion = nil
        changed.genreTag = nil
        #expect(DownloadFileRevision(track: changed).matches(revision))
    }

    @Test func backgroundJobAndRecordRetainRevisionAndDecodeLegacyData() throws {
        let track = SampleLibrary.catalogue.albums[0].tracks[0]
        let revision = DownloadFileRevision(track: track)
        var job = DownloadJob(ownerID: "owner", trackID: "track", driveID: "source", fileName: "file.m4a", expectedBytes: 12,
                              ownerTitle: "Album", ownerSubtitle: "Artist", trackTitle: "Song", ownerTrackCount: 1)
        job.fileRevision = revision
        #expect(DownloadJob.decode(job.encoded)?.fileRevision == revision)
        let record = DownloadRecord(trackID: "track", driveID: "source", fileName: "file.m4a", bytes: 12, owners: ["owner"], fileRevision: revision)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: data).fileRevision == revision)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["fileRevision"] = nil
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: legacy)).fileRevision == nil)
    }

    @Test func watchRejectsSameSizeReplacementsIncludingLateRelay() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = SampleLibrary.catalogue.albums[0].tracks[0]
        source.fileSize = 8192
        source.isEnriched = true
        source.genreTag = "Rock"
        var track = WatchTrack(id: source.id, title: source.title, artist: "Artist", album: "Album", duration: 120,
                               path: "/music/song.m4a", fileSize: 8192, format: "AAC", isLossless: false,
                               fileRevision: DownloadFileRevision(track: source))
        var playlist = WatchPlaylist(id: "mix", name: "Mix", isSmart: false, coverColours: [], tracks: [track],
                                     totalSongs: 1, driveID: "source", profileID: "profile")
        let generation = UUID()
        let job = try #require(WatchDownloadJob(playlist: playlist, track: track, generation: generation))
        let destination = job.destination(in: root)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: destination)
        var manifest = WatchDownloadManifest()
        manifest.generation = generation
        manifest.desired = [track.id]
        manifest.files[track.id] = generation.uuidString + "/" + job.fileName
        manifest.fileRevisions[track.id] = track.fileRevision
        #expect(manifest.availableFiles(for: playlist, root: root).count == 1)
        let request = WatchAudioRelayRequest(playlist: playlist, job: job)
        source.genreTag = "Jazz" // Same path/size/mtime; only the saved embedded tag changed.
        track.fileRevision = DownloadFileRevision(track: source)
        playlist.tracks = [track]
        let catalogue = WatchCatalogue(serverName: "NAS", profileName: "Me", playlists: [playlist])
        #expect(request.resolve(in: catalogue) == nil)
        #expect(!request.isCurrent(in: catalogue, manifest: manifest))
        let restored = try JSONDecoder().decode(WatchDownloadManifest.self, from: JSONEncoder().encode(manifest))
        #expect(restored.availableFiles(for: playlist, root: root).isEmpty)
        #expect(restored.outstandingTrackIDs(for: playlist, root: root) == [track.id])
        #expect(manifest.pruneInvalidFiles(for: playlist, root: root) == [track.id])
        #expect(manifest.fileRevisions.isEmpty)
        #expect(manifest.desired == [track.id])
    }

    @Test func legacyWatchManifestRetainsFilesAndCanAdoptKnownRevision() throws {
        var source = SampleLibrary.catalogue.albums[0].tracks[0]
        source.sourceVersion = "first"
        let revision = DownloadFileRevision(track: source)
        let old = Data(#"{"files":{"song":"file"},"desired":["song"]}"#.utf8)
        var manifest = try JSONDecoder().decode(WatchDownloadManifest.self, from: old)
        #expect(manifest.files == ["song": "file"])
        #expect(manifest.fileRevisions.isEmpty)
        var track = WatchTrack(id: "song", title: "Song", artist: "Artist", album: "Album", duration: 120,
                               path: "/song.m4a", fileSize: 8192, format: "AAC", isLossless: false, fileRevision: revision)
        var playlist = WatchPlaylist(id: "mix", name: "Mix", isSmart: false, coverColours: [], tracks: [track], totalSongs: 1)
        manifest.adoptFileRevisions(from: playlist)
        #expect(manifest.fileRevisions["song"] == revision)
        source.sourceVersion = "second"
        track.fileRevision = DownloadFileRevision(track: source)
        playlist.tracks = [track]
        manifest.adoptFileRevisions(from: playlist)
        #expect(manifest.fileRevisions["song"] == revision) // Never overwrite the baseline to bless stale bytes.
    }
}
