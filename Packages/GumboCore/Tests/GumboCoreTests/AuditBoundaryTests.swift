import Foundation
import Testing
@testable import GumboCore

@Suite("Audit lifecycle boundaries")
struct AuditBoundaryTests {
    @Test func watchRevocationRejectsEveryOlderTransportAndSurvivesRelaunch() throws {
        let grant = WatchAuthorization(revision: 41, isGranted: true)
        let revoke = grant.successor(granted: false)
        let restored = try #require(WatchAuthorization.decode(revoke.encoded))
        for _ in ["file", "credentials", "reply"] { #expect(!restored.accepts(grant)) }
        #expect(restored.accepts(revoke))
        let next = revoke.successor(granted: true)
        #expect(restored.accepts(next))
        #expect(next.accepts(next)) // catalogue and credentials can arrive in either order
        #expect(!next.accepts(revoke))
        #expect(!next.accepts(.init(revision: next.revision, isGranted: false)))
        #expect(WatchAuthorization.decode(nil) == nil)
        #expect(WatchAuthorization.decode(Data("{}".utf8)) == nil)
        #expect(WatchAuthorization.decode(WatchAuthorization(revision: 0, isGranted: true).encoded) == nil)
    }

    @Test func newerPlaybackPauseAndRevokeInvalidateSuspendedActivation() {
        var intent = PlaybackIntentRevision()
        let first = intent.advance()
        let second = intent.advance()
        #expect(!intent.accepts(first))
        #expect(intent.accepts(second))
        intent.advance() // pause or revoke while activation is suspended
        #expect(!intent.accepts(second))
    }

    @Test func discoveryAllowsRetryButRejectsCallbacksFromAnEarlierAttemptOrRun() throws {
        var attempts = DiscoveryAttempts()
        let first = try #require({ attempts.begin("NAS") }())
        #expect({ attempts.begin("NAS") == nil }())
        #expect({ attempts.finish("NAS", token: first) }())
        let retry = try #require({ attempts.begin("NAS") }())
        #expect({ !attempts.finish("NAS", token: first) }())
        attempts.reset()
        let restarted = try #require({ attempts.begin("NAS") }())
        #expect({ !attempts.finish("NAS", token: retry) }())
        #expect({ attempts.finish("NAS", token: restarted) }())
    }

    @Test func artworkNamespacesSeparateServersAndFoldersWithoutDelimiterCollisions() {
        #expect(CoverStore.scopedDirectory(driveID: "a", rootPath: "/music") != CoverStore.scopedDirectory(driveID: "b", rootPath: "/music"))
        #expect(CoverStore.scopedDirectory(driveID: "a", rootPath: "/music") != CoverStore.scopedDirectory(driveID: "a", rootPath: "/other"))
        #expect(CoverStore.scopedDirectory(driveID: "a|b", rootPath: "c") != CoverStore.scopedDirectory(driveID: "a", rootPath: "b|c"))
    }

    @Test @MainActor func unreadableProfileIndexIsPreservedAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "audit-profiles-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let original = ProfileStore(directory: directory, defaults: defaults)
        let url = directory.appending(path: "profiles.json")
        let good = try Data(contentsOf: url)
        let corrupt = Data("{incomplete".utf8)
        try corrupt.write(to: url)
        let store = ProfileStore(directory: directory, defaults: defaults)
        #expect(store.profiles.isEmpty && store.isLocked && !store.canAddProfile)
        #expect(store.persistenceFailure?.kind == .unreadableIndex)
        #expect(store.ensureProfileAfterSync(isOwner: true) == nil)
        #expect(try Data(contentsOf: url) == corrupt)
        // Any alert button clears the failure; a retry that still can't read says so again (#233).
        store.dismissPersistenceError()
        store.retryProfileIndex()
        #expect(!store.isProfileIndexReadable && store.profiles.isEmpty)
        #expect(store.persistenceFailure?.kind == .unreadableIndex)
        try good.write(to: url)
        store.retryProfileIndex()
        #expect(store.persistenceFailure == nil)
        #expect(store.profiles.map(\.id) == original.profiles.map(\.id))
        #expect(store.isProfileIndexReadable)
    }

    @Test @MainActor func metadataSaveFailureDoesNotPublishNameOrPINAndInvalidPhotoDoesNotRemoveIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "audit-profile-edits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory, defaults: defaults)
        let original = try #require(store.owner)
        #expect(store.activate(original))
        let photo = directory.appending(path: "\(original.id)-photo.jpg")
        let previous = Data("previous-photo".utf8)
        try previous.write(to: photo)
        #expect(!store.setPhoto(Data("not an image".utf8), for: original))
        #expect(try Data(contentsOf: photo) == previous)
        let url = directory.appending(path: "profiles.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var changed = original
        changed.name = "Must not publish"
        changed.pin = PINRecord.make("5678")
        #expect(!store.update(changed))
        #expect(store.owner == original)
        #expect(store.persistenceFailure != nil)
    }

    @Test @MainActor func collectionMembershipFollowsTagChangesAndNewAlbums() async throws {
        let library = LibraryStore()
        library.replace(with: SampleLibrary.catalogue, drive: nil)
        let original = try #require(library.albums.first)
        let oldGenre = original.genre
        var changed = SampleLibrary.catalogue
        changed.albums[0].genre = "Audit genre"
        library.replace(with: changed, drive: nil)
        await library.derivationTask?.value
        #expect(library.albums(matching: .genre("Audit genre")).map(\.id) == [original.id])
        #expect(!library.albums(matching: .genre(oldGenre)).contains { $0.id == original.id })
        #expect(library.albums(matching: .recentlyAdded).contains { $0.genre == "Audit genre" })
    }
}

extension AuditBoundaryTests {
    @Test @MainActor func profileRetryCannotBypassUnreadableRetirementStateOrPendingExclusions() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "audit-retry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let first = ProfileStore(directory: directory, defaults: defaults)
        let owner = try #require(first.owner)
        #expect(first.activate(owner))
        let peer = try #require(first.create(name: "Peer", avatar: .random(), pin: nil))
        let marker = directory.appending(path: "family-retirement.json")
        try Data("broken".utf8).write(to: marker)
        let store = ProfileStore(directory: directory, defaults: defaults)
        #expect(!store.isProfileIndexReadable && store.isLocked)
        store.retryProfileIndex()
        #expect(!store.isProfileIndexReadable && store.profiles.isEmpty)
        try JSONEncoder().encode(Set([peer.id])).write(to: marker)
        store.retryProfileIndex()
        #expect(store.isProfileIndexReadable)
        #expect(store.profiles.map(\.id) == [owner.id])
        #expect(!store.activate(peer))
    }
}
