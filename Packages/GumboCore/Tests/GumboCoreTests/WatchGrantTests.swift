import Foundation
import Testing
@testable import GumboCore

/// The iPhone's Watch grant (#219): the Watch clears everything whenever the revision moves, so a
/// relaunch must keep it while a lock, switch, sign-out or other library must move it on.
@Suite struct WatchGrantTests {
    private let library = WatchGrant.scope(profileID: "profile-a", sourceID: "nas|me", rootPath: "/music")

    @Test func relaunchWithTheSameLibraryKeepsTheRevisionTheWatchHas() {
        var grant = WatchGrant.restored(from: nil)
        let first = grant.update(scope: library)
        #expect(first == .granted)
        let watch = grant.authorization
        var relaunched = WatchGrant.restored(from: grant.encoded)
        #expect(relaunched.authorization == watch)
        #expect(relaunched.scope == library)
        // A background relaunch with the profile still closed: nothing moves, nothing revokes.
        let closed = [relaunched.update(scope: nil), relaunched.update(scope: nil)]
        #expect(closed == [.unchanged, .unchanged])
        #expect(relaunched.authorization == watch)
        // The same library opens again.
        let reopened = relaunched.update(scope: library)
        #expect(reopened == .unchanged)
        #expect(relaunched.authorization == watch)
        #expect(!clearsWatch(holding: watch, on: relaunched.authorization))
    }

    @Test func anotherProfileSourceOrFolderAfterARelaunchIsGrantedAnew() throws {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library)
        let watch = grant.authorization
        let saved = try #require(grant.encoded)
        for other in [
            WatchGrant.scope(profileID: "profile-b", sourceID: "nas|me", rootPath: "/music"),
            WatchGrant.scope(profileID: "profile-a", sourceID: "other|me", rootPath: "/music"),
            WatchGrant.scope(profileID: "profile-a", sourceID: "nas|me", rootPath: "/music/other"),
        ] {
            var relaunched = WatchGrant.restored(from: saved)
            _ = relaunched.update(scope: nil)
            let change = relaunched.update(scope: other)
            #expect(change == .granted)
            #expect(relaunched.authorization.isGranted)
            #expect(relaunched.authorization.revision > watch.revision)
            #expect(relaunched.scope == other)
            #expect(clearsWatch(holding: watch, on: relaunched.authorization))
        }
    }

    @Test func closingALibraryOpenInThisProcessRevokes() {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library)
        let watch = grant.authorization
        // Sign-out or leaving the ready library.
        let closed = grant.update(scope: nil)
        #expect(closed == .revoked)
        #expect(!grant.authorization.isGranted)
        #expect(grant.scope == nil)
        #expect(clearsWatch(holding: watch, on: grant.authorization))
        let stillClosed = grant.update(scope: nil)
        #expect(stillClosed == .unchanged)
        // Reopening the same library after a revocation is a new grant, never the old one back.
        let reopened = grant.update(scope: library)
        #expect(reopened == .granted)
        #expect(grant.authorization.revision == watch.revision + 2)
    }

    @Test func aRestoredGrantConfirmedByItsLibraryRevokesWhenThatLibraryCloses() {
        var saved = WatchGrant.restored(from: nil)
        _ = saved.update(scope: library)
        var grant = WatchGrant.restored(from: saved.encoded)
        let changes = [grant.update(scope: nil), grant.update(scope: library), grant.update(scope: nil)]
        #expect(changes == [.unchanged, .unchanged, .revoked])
        #expect(!grant.authorization.isGranted)
    }

    @Test func explicitRevocationAlwaysMovesTheRevision() {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library)
        var relaunched = WatchGrant.restored(from: grant.encoded)
        let watch = relaunched.authorization
        // A lock or switch revokes even a grant restored at launch and not yet confirmed.
        relaunched.revoke()
        #expect(!relaunched.authorization.isGranted)
        #expect(relaunched.scope == nil)
        #expect(clearsWatch(holding: watch, on: relaunched.authorization))
        let revoked = relaunched.authorization
        relaunched.revoke()
        #expect(relaunched.authorization.revision == revoked.revision + 1)
        // The revocation survives a relaunch.
        var afterRevocation = WatchGrant.restored(from: relaunched.encoded)
        #expect(afterRevocation.authorization == relaunched.authorization)
        let closed = afterRevocation.update(scope: nil)
        #expect(closed == .unchanged)
        #expect(!afterRevocation.authorization.isGranted)
    }

    @Test func snapshotsStayOrderedAcrossRelaunchesAndRestartWithANewGrant() {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library)
        let sent = [grant.nextSnapshotRevision(), grant.nextSnapshotRevision()]
        #expect(sent == [1, 2])
        var relaunched = WatchGrant.restored(from: grant.encoded)
        _ = relaunched.update(scope: library)
        // The Watch keeps snapshot 2; anything numbered lower would be discarded as stale.
        let afterRelaunch = relaunched.nextSnapshotRevision()
        #expect(afterRelaunch == 3)
        let switched = relaunched.update(scope: WatchGrant.scope(profileID: "profile-b", sourceID: "nas|me", rootPath: "/music"))
        #expect(switched == .granted)
        let firstOfNewGrant = relaunched.nextSnapshotRevision()
        #expect(firstOfNewGrant == 1)
        relaunched.revoke()
        #expect(relaunched.snapshotRevision == 0)
    }

    @Test func legacyAuthorizationWithoutALibraryIsHeldThenGrantedAnewOnce() {
        let legacy = WatchAuthorization(revision: 7, isGranted: true)
        var grant = WatchGrant.restored(from: nil, legacyAuthorization: legacy.encoded)
        #expect(grant.authorization == legacy)
        #expect(grant.scope == nil)
        let changes = [grant.update(scope: nil), grant.update(scope: library), grant.update(scope: library)]
        #expect(changes == [.unchanged, .granted, .unchanged])
        #expect(grant.authorization == WatchAuthorization(revision: 8, isGranted: true))
        // Once saved in the new form, the legacy value is no longer consulted.
        let stale = WatchAuthorization(revision: 3, isGranted: false)
        let restored = WatchGrant.restored(from: grant.encoded, legacyAuthorization: stale.encoded)
        #expect(restored.authorization == grant.authorization)
    }

    @Test func unreadableOrMissingStateStartsWithNothingGranted() {
        for data in [nil, Data("{}".utf8), Data("not json".utf8)] {
            let grant = WatchGrant.restored(from: data)
            #expect(grant.authorization == WatchAuthorization(revision: 0, isGranted: false))
            #expect(grant.scope == nil)
            #expect(grant.snapshotRevision == 0)
        }
    }

    @Test func scopeUsesStableIdentitiesWithoutDelimiterCollisions() {
        // Profile sessions are new on every opening, so they are not part of the scope.
        #expect(WatchGrant.scope(profileID: "profile-a", sourceID: "nas|me", rootPath: "/music") == library)
        #expect(WatchGrant.scope(profileID: "a|b", sourceID: "c", rootPath: "d") != WatchGrant.scope(profileID: "a", sourceID: "b|c", rootPath: "d"))
        #expect(WatchGrant.scope(profileID: "a", sourceID: "b|c", rootPath: "d") != WatchGrant.scope(profileID: "a", sourceID: "b", rootPath: "c|d"))
        #expect(WatchGrant.scope(profileID: "a", sourceID: "1:b", rootPath: "") != WatchGrant.scope(profileID: "a1:", sourceID: "b", rootPath: ""))
    }

    /// What `WatchStore.accept` does on the Watch: anything newer than what it holds clears it.
    private func clearsWatch(holding current: WatchAuthorization, on incoming: WatchAuthorization) -> Bool {
        current.accepts(incoming) && incoming != current
    }
}
