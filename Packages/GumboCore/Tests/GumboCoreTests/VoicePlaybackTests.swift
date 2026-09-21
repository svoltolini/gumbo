import Foundation
import Testing
@testable import GumboCore

@Suite struct VoicePlaybackTests {
    @Test func sameSongTitleRequiresDisambiguationAndArtistOrAlbumCanResolveIt() {
        let albums = [album("one", artist: "First Artist"), album("two", artist: "Second Artist")]
        #expect(VoiceMediaResolver.matches(.init(kind: .song, name: "  CAFÉ  "), albums: albums, playlists: []).count == 2)
        let artist = VoiceMediaResolver.matches(.init(kind: .song, name: "Cafe", artist: "second artist"), albums: albums, playlists: [])
        #expect(artist.map(\.id) == ["song:two-song"])
        let albumMatch = VoiceMediaResolver.matches(.init(kind: .song, name: "Café", album: "one"), albums: albums, playlists: [])
        #expect(albumMatch.map(\.id) == ["song:one-song"])
        #expect(VoiceMediaResolver.matches(.init(name: "Cafe by First Artist"), albums: albums, playlists: []).map(\.id) == ["song:one-song"])
        #expect(VoiceMediaResolver.matches(.init(name: "Caf"), albums: albums, playlists: []).isEmpty)
        #expect(VoiceMediaResolver.matches(.init(name: ""), albums: albums, playlists: []).isEmpty)
    }

    @Test func literalTitleContainingByWinsAndCollectionsKeepTheirOrderAndDuplicates() {
        var record = album("one", artist: "First Artist")
        record.tracks[0].title = "Stand By Me"
        let playlist = Playlist(id: "mix", name: "Road trip", summary: "", covers: [], tracks: record.tracks + record.tracks)
        let song = VoiceMediaResolver.matches(.init(name: "Stand By Me"), albums: [record], playlists: [playlist])
        #expect(song.count == 1)
        let mix = VoiceMediaResolver.matches(.init(kind: .playlist, name: "Road trip"), albums: [record], playlists: [playlist])
        #expect(mix.first?.tracks.map(\.id) == ["one-song", "one-song"])
        let artist = VoiceMediaResolver.matches(.init(kind: .artist, name: "First Artist"), albums: [record], playlists: [playlist])
        #expect(artist.first?.tracks.count == 1)
        #expect(VoiceMediaResolver.matches(.init(kind: .album, name: "one"), albums: [record], playlists: []).first?.tracks == record.tracks)
    }

    @Test func sameTitleAcrossKindsDoesNotChooseAnArbitrarySong() {
        var record = album("Café", artist: "Café")
        record.tracks[0].artist = "Café"
        let matches = VoiceMediaResolver.matches(.init(name: "Café"), albums: [record], playlists: [])
        #expect(Set(matches.map(\.kind)) == [.song, .album, .artist])
    }

    @Test func offlineDownloadedCollectionPlaysWithoutConnectingAndKeepsRequestedOptions() async throws {
        let harness = Harness()
        harness.downloaded = true
        let selection = try #require(try await harness.controller.resolve(.init(kind: .album, name: "one")).first)
        try await harness.controller.play(selection, shuffle: true, repeatMode: .all)
        #expect(harness.waits == 0)
        #expect(harness.played == ["one-song"])
        #expect(harness.shuffle == true)
        #expect(harness.repeatMode == .all)
    }

    @Test func unavailableServerDoesNotPretendToPlayOrDropUndownloadedTracks() async throws {
        let harness = Harness()
        let selection = try #require(try await harness.controller.resolve(.init(name: "Café")).first)
        await #expect(throws: VoicePlaybackError.offline) { try await harness.controller.play(selection) }
        #expect(harness.played.isEmpty)
        #expect(harness.waits == 1)
    }

    @Test func manualPlaybackWhileServerWaitsSupersedesVoice() async throws {
        let harness = Harness()
        let selection = try #require(try await harness.controller.resolve(.init(name: "Café")).first)
        harness.duringWait = { harness.command = UUID(); harness.connected = true }
        await #expect(throws: VoicePlaybackError.cancelled) { try await harness.controller.play(selection) }
        #expect(harness.played.isEmpty)
    }

    @Test func commandIsReservedBeforeAnAdaptersIdentifierLookup() async throws {
        let harness = Harness()
        harness.connected = true
        let id = try #require(try await harness.controller.resolve(.init(name: "Café")).first?.id)
        let command = harness.controller.beginRequest()
        let selection = try #require(try await harness.controller.selections(for: [id]).first)
        harness.command = UUID() // A tap while the adapter was finding the music must win.
        await #expect(throws: VoicePlaybackError.cancelled) { try await harness.controller.play(selection, command: command) }
        #expect(harness.played.isEmpty)
    }

    @Test(arguments: ContextChange.allCases)
    func changedContextDuringServerWaitCannotStartPlayback(_ change: ContextChange) async throws {
        let harness = Harness()
        let selection = try #require(try await harness.controller.resolve(.init(name: "Café")).first)
        harness.duringWait = { harness.change(change); harness.connected = true }
        await #expect(throws: VoicePlaybackError.changed) { try await harness.controller.play(selection) }
        #expect(harness.played.isEmpty)
    }

    @Test func oldShortcutIdentityCannotSelectSamePathFromAnotherProfileOrServer() async throws {
        let harness = Harness()
        let id = try #require(try await harness.controller.resolve(.init(name: "Café")).first?.id)
        #expect(!id.contains("song"))
        harness.change(.profile)
        #expect(try await harness.controller.selections(for: [id]).isEmpty)
        harness.change(.source)
        #expect(try await harness.controller.selections(for: [id]).isEmpty)
    }

    @Test func lockedProfileCannotSearchAndImmediatePlayerFailureIsReported() async throws {
        let harness = Harness()
        harness.connected = true
        let selection = try #require(try await harness.controller.resolve(.init(name: "Café")).first)
        harness.playSucceeds = false
        await #expect(throws: VoicePlaybackError.playbackFailed) { try await harness.controller.play(selection) }
        harness.context = nil
        await #expect(throws: VoicePlaybackError.openApp) { _ = try await harness.controller.resolve(.init(name: "Café")) }
    }

    @Test func cancelledTaskDoesNotStartMusic() async throws {
        let harness = Harness()
        harness.connected = true
        let selection = try #require(try await harness.controller.resolve(.init(name: "Café")).first)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await harness.controller.play(selection)
        }
        await #expect(throws: VoicePlaybackError.cancelled) { try await task.value }
        #expect(harness.played.isEmpty)
    }

    private func album(_ title: String, artist: String) -> Album { makeAlbum(title, artist: artist) }
}

nonisolated enum ContextChange: CaseIterable, Sendable { case source, root, profile, session, connection, content, lock }

private final class Harness {
    var context: VoicePlaybackContext? = .init(sourceID: "nas", rootPath: "/music", profileID: "profile", sessionID: UUID(), connectionToken: UUID())
    var albums = [makeAlbum("one", artist: "First Artist")]
    var connected = false
    var downloaded = false
    var command = UUID()
    var duringWait: (() -> Void)?
    var waits = 0
    var played: [String] = []
    var shuffle: Bool?
    var repeatMode: PlayerModel.RepeatMode?
    var playSucceeds = true
    lazy var controller = VoicePlaybackController(context: { [unowned self] in context }, content: { [unowned self] in (albums, []) },
        isDownloaded: { [unowned self] _ in downloaded }, isConnected: { [unowned self] in connected },
        waitForConnection: { [unowned self] in waits += 1; duringWait?() },
        beginCommand: { [unowned self] in command = UUID(); return command }, currentCommand: { [unowned self] in command },
        play: { [unowned self] tracks, _, requestedShuffle, requestedRepeat in
            played = tracks.map(\.id); shuffle = requestedShuffle; repeatMode = requestedRepeat; return playSucceeds
        })

    func change(_ change: ContextChange) {
        guard let previous = context else { return }
        if change == .lock { context = nil; return }
        context = VoicePlaybackContext(sourceID: change == .source ? "other" : previous.sourceID,
            rootPath: change == .root ? "/other" : previous.rootPath,
            profileID: change == .profile ? "other" : previous.profileID,
            sessionID: change == .session ? UUID() : previous.sessionID,
            connectionToken: change == .connection ? UUID() : previous.connectionToken,
            contentRevision: change == .content ? previous.contentRevision + 1 : previous.contentRevision)
    }
}

private nonisolated func makeAlbum(_ title: String, artist: String) -> Album {
    let track = Track(id: title + "-song", albumID: title, title: "Café", index: 0, number: 1, disc: 1,
                      duration: 120, codec: "m4a", path: "/\(title).m4a", format: "AAC", isEnriched: false)
    return Album(id: title, title: title, artist: artist, year: 2026, genre: "Rock", tracks: [track],
                 colorA: "000000", colorB: "333333", addedRank: 0, folderTitle: title, folderArtist: artist)
}
