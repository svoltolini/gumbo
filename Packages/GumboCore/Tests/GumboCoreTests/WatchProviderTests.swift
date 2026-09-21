import Foundation
import Testing
@testable import GumboCore

@Suite struct WatchProviderTests {
    @Test func legacyDSMStillDecodesAndUnknownVersionFailsClosed() throws {
        let legacy = Data(#"{"baseURL":"https://nas.example:5001","account":"sam","password":"fixture","driveID":"dsm"}"#.utf8)
        var credentials = try JSONDecoder().decode(WatchCredentials.self, from: legacy)
        #expect(credentials.providerKind == .synology)
        #expect(credentials.isUsable)
        credentials.protocolVersion = 999
        #expect(credentials.providerKind == nil)
        #expect(!credentials.matches(playlist(source: "dsm")))
    }

    @Test func webDAVSignInCannotCrossProviderRootOrAccount() throws {
        let config = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/dav/music/")!)
        let source = config.sourceID(account: "sam")
        var credentials = WatchCredentials(baseURL: config.endpoint, account: "sam", password: "fixture", driveID: source, provider: config)
        #expect(credentials.protocolVersion == 2)
        #expect(credentials.providerKind == .webDAV)
        #expect(credentials.matches(playlist(source: source)))
        credentials.account = "other"
        #expect(!credentials.isUsable)
        credentials.account = "sam"
        credentials.baseURL = URL(string: "https://nas.example/dav/other/")!
        #expect(credentials.providerKind == nil)
        #expect(!credentials.isUsable)
    }

    @Test func smbDescriptorHasNoAccountOrPassword() throws {
        let config = try ProviderConfiguration(kind: .smb, endpoint: URL(string: "smb://nas.example")!, share: "music")
        var credentials = WatchCredentials(baseURL: config.endpoint, account: "", password: "", driveID: "smb-source", provider: config)
        #expect(credentials.isUsable)
        #expect(credentials.providerKind == .smb)
        #expect(credentials.matches(playlist(source: "smb-source")))
        credentials.password = "must-not-cross"
        #expect(!credentials.isUsable)
        credentials.password = ""
        credentials.account = "sam"
        #expect(!credentials.isUsable)
    }

    @Test func unknownProviderOrConfigurationVersionCannotDecodeAsDSM() {
        let body = #"{"baseURL":"https://nas.example","account":"sam","password":"fixture","driveID":"x","protocolVersion":2,"provider":{"version":1,"kind":"future","endpoint":"https://nas.example","requiresEncryption":true}}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchCredentials.self, from: Data(body.utf8)) }
        let badVersion = body.replacingOccurrences(of: "future", with: "webDAV").replacingOccurrences(of: #""version":1"#, with: #""version":55"#)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WatchCredentials.self, from: Data(badVersion.utf8)) }
    }

    @Test func relayUsesCurrentSourceProfileMembershipAndExactFileMetadata() throws {
        let item = playlist()
        let job = try #require(WatchDownloadJob(playlist: item, track: item.tracks[0], generation: UUID()))
        let request = WatchAudioRelayRequest(playlist: item, job: job)
        let catalogue = WatchCatalogue(serverName: "Fixture", profileName: "Me", playlists: [item])
        #expect(WatchAudioRelayRequest.decode(request.encoded) == request)
        #expect(request.resolve(in: catalogue)?.track == item.tracks[0])
        #expect(request.resolve(in: WatchCatalogue(serverName: "Fixture", profileName: "Me", playlists: [playlist(source: "other")])) == nil)
        var otherProfile = item
        otherProfile.profileID = "other-profile"
        #expect(request.resolve(in: WatchCatalogue(serverName: "Fixture", profileName: "Other", playlists: [otherProfile])) == nil)
        var changedFile = item
        changedFile.tracks[0].fileSize = 999
        #expect(request.resolve(in: WatchCatalogue(serverName: "Fixture", profileName: "Me", playlists: [changedFile])) == nil)
        var deleted = catalogue
        deleted.applyServerDeletions(["source": [item.tracks[0].id]])
        #expect(request.resolve(in: deleted) == nil)
    }

    @Test func cancelledOrRetriedRelayGenerationRejectsLateAudio() throws {
        let item = playlist()
        let generation = UUID()
        let job = try #require(WatchDownloadJob(playlist: item, track: item.tracks[0], generation: generation))
        let request = WatchAudioRelayRequest(playlist: item, job: job)
        let catalogue = WatchCatalogue(serverName: "Fixture", profileName: "Me", playlists: [item])
        var manifest = WatchDownloadManifest()
        manifest.desired = [item.tracks[0].id]
        manifest.generation = generation
        #expect(request.isCurrent(in: catalogue, manifest: manifest))
        manifest.generation = nil
        #expect(!request.isCurrent(in: catalogue, manifest: manifest))
        manifest.generation = UUID()
        #expect(!request.isCurrent(in: catalogue, manifest: manifest))
        manifest.generation = generation
        manifest.desired.removeAll()
        #expect(!request.isCurrent(in: catalogue, manifest: manifest))
    }

    @Test func forgedRelayPathAndNewerVersionAreRejected() throws {
        let item = playlist()
        let request = WatchAudioRelayRequest(playlist: item, job: try #require(WatchDownloadJob(playlist: item, track: item.tracks[0], generation: UUID())))
        let encoded = try #require(request.encoded)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var job = try #require(object["job"] as? [String: Any])
        job["fileName"] = "../../outside"
        object["job"] = job
        #expect(WatchAudioRelayRequest.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
        object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = 88
        #expect(WatchAudioRelayRequest.decode(try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test func webDAVBackgroundAuthenticationRejectsRedirectsAndEscapedRoots() throws {
        let config = try ProviderConfiguration(kind: .webDAV, endpoint: URL(string: "https://nas.example/music/")!)
        let credentials = WatchCredentials(baseURL: config.endpoint, account: "sam", password: "fixture",
                                           driveID: config.sourceID(account: "sam"), provider: config)
        let original = URL(string: "https://nas.example/music/a.flac")!
        #expect(credentials.permitsWebDAVDownload(original: original, current: original))
        #expect(!credentials.permitsWebDAVDownload(original: original, current: URL(string: "https://nas.example/other/a.flac")))
        #expect(!credentials.permitsWebDAVDownload(original: original, current: URL(string: "https://other.example/music/a.flac")))
        let outside = URL(string: "https://nas.example/music-other/a.flac")!
        #expect(!credentials.permitsWebDAVDownload(original: outside, current: outside))
        let encodedEscape = URL(string: "https://nas.example/music/%2E%2E/a.flac")!
        #expect(!credentials.permitsWebDAVDownload(original: encodedEscape, current: encodedEscape))
    }

    private func playlist(source: String = "source") -> WatchPlaylist {
        let song = WatchTrack(id: "track", title: "Fixture", artist: "Artist", album: "Album", duration: 1,
                              path: "/music/song.flac", fileSize: 4, format: "FLAC", isLossless: true)
        return WatchPlaylist(id: "playlist", name: "Playlist", isSmart: false, coverColours: [], tracks: [song],
                             totalSongs: 1, driveID: source, profileID: "profile")
    }
}
