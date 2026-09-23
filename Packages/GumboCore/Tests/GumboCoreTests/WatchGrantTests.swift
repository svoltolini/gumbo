import Foundation
import Testing
@testable import GumboCore

/// The iPhone's Watch grant (#219): the Watch clears everything whenever the revision moves, so a
/// relaunch must keep it while a lock, switch, sign-out or other library must move it on.
@Suite struct WatchGrantTests {
    private let profileA = "profile-a"
    private let library = WatchGrant.scope(profileID: "profile-a", sourceID: "nas|me", rootPath: "/music")

    @Test func relaunchWithTheSameLibraryKeepsTheRevisionTheWatchHas() {
        var grant = WatchGrant.restored(from: nil)
        let first = grant.update(scope: library, profileID: profileA)
        #expect(first == .granted)
        let watch = grant.authorization
        var relaunched = WatchGrant.restored(from: grant.encoded)
        #expect(relaunched.authorization == watch)
        #expect(relaunched.scope == library)
        #expect(relaunched.profileID == profileA)
        // A background relaunch with no profile open, then the same profile open before its
        // library is ready: nothing moves, nothing revokes.
        let closed = [relaunched.update(scope: nil, profileID: nil), relaunched.update(scope: nil, profileID: profileA)]
        #expect(closed == [.unchanged, .unchanged])
        #expect(relaunched.authorization == watch)
        // The same library opens again.
        let reopened = relaunched.update(scope: library, profileID: profileA)
        #expect(reopened == .unchanged)
        #expect(relaunched.authorization == watch)
        #expect(!clearsWatch(holding: watch, on: relaunched.authorization))
    }

    @Test func anotherProfileSourceOrFolderAfterARelaunchIsGrantedAnew() throws {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library, profileID: profileA)
        let watch = grant.authorization
        let saved = try #require(grant.encoded)
        for (profile, other) in [
            ("profile-b", WatchGrant.scope(profileID: "profile-b", sourceID: "nas|me", rootPath: "/music")),
            (profileA, WatchGrant.scope(profileID: profileA, sourceID: "other|me", rootPath: "/music")),
            (profileA, WatchGrant.scope(profileID: profileA, sourceID: "nas|me", rootPath: "/music/other")),
        ] {
            var relaunched = WatchGrant.restored(from: saved)
            _ = relaunched.update(scope: nil, profileID: nil)
            let change = relaunched.update(scope: other, profileID: profile)
            #expect(change == .granted)
            #expect(relaunched.authorization.isGranted)
            #expect(relaunched.authorization.revision > watch.revision)
            #expect(relaunched.scope == other)
            #expect(relaunched.profileID == profile)
            #expect(clearsWatch(holding: watch, on: relaunched.authorization))
        }
    }

    @Test func anotherProfileOpeningAfterARelaunchRevokesBeforeItsLibraryIsReady() {
        var saved = WatchGrant.restored(from: nil)
        _ = saved.update(scope: library, profileID: profileA)
        let watch = saved.authorization
        var grant = WatchGrant.restored(from: saved.encoded)
        // Another profile opens while its library is still loading, re-indexing or offline.
        let switched = grant.update(scope: nil, profileID: "profile-b")
        #expect(switched == .revoked)
        #expect(!grant.authorization.isGranted)
        #expect(grant.profileID == nil)
        #expect(clearsWatch(holding: watch, on: grant.authorization))
        // Its library becoming ready is a new grant for it.
        let ready = grant.update(scope: WatchGrant.scope(profileID: "profile-b", sourceID: "nas|me", rootPath: "/music"), profileID: "profile-b")
        #expect(ready == .granted)
        #expect(grant.authorization.revision == watch.revision + 2)
    }

    @Test func closingALibraryOpenInThisProcessRevokes() {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library, profileID: profileA)
        let watch = grant.authorization
        // Sign-out or leaving the ready library, with the profile still open.
        let closed = grant.update(scope: nil, profileID: profileA)
        #expect(closed == .revoked)
        #expect(!grant.authorization.isGranted)
        #expect(grant.scope == nil)
        #expect(clearsWatch(holding: watch, on: grant.authorization))
        let stillClosed = grant.update(scope: nil, profileID: profileA)
        #expect(stillClosed == .unchanged)
        // Reopening the same library after a revocation is a new grant, never the old one back.
        let reopened = grant.update(scope: library, profileID: profileA)
        #expect(reopened == .granted)
        #expect(grant.authorization.revision == watch.revision + 2)
    }

    @Test func aRestoredGrantConfirmedByItsLibraryRevokesWhenThatLibraryCloses() {
        var saved = WatchGrant.restored(from: nil)
        _ = saved.update(scope: library, profileID: profileA)
        var grant = WatchGrant.restored(from: saved.encoded)
        let changes = [grant.update(scope: nil, profileID: nil), grant.update(scope: library, profileID: profileA),
                       grant.update(scope: nil, profileID: profileA)]
        #expect(changes == [.unchanged, .unchanged, .revoked])
        #expect(!grant.authorization.isGranted)
    }

    @Test func theGrantedProfileLeavingTheIPhoneWhileClosedRevokes() {
        var saved = WatchGrant.restored(from: nil)
        _ = saved.update(scope: library, profileID: profileA, knownProfileIDs: [profileA])
        let watch = saved.authorization
        var grant = WatchGrant.restored(from: saved.encoded)
        // Still on the iPhone, or a profile list that cannot be read: held.
        let held = [grant.update(scope: nil, profileID: nil, knownProfileIDs: [profileA, "profile-b"]),
                    grant.update(scope: nil, profileID: nil, knownProfileIDs: nil)]
        #expect(held == [.unchanged, .unchanged])
        #expect(grant.authorization == watch)
        // Deleted on another device, or retired from the family, while nobody has it open here.
        let removed = grant.update(scope: nil, profileID: nil, knownProfileIDs: ["profile-b"])
        #expect(removed == .revoked)
        #expect(!grant.authorization.isGranted)
        #expect(clearsWatch(holding: watch, on: grant.authorization))
    }

    @Test func explicitRevocationAlwaysMovesTheRevision() {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library, profileID: profileA)
        var relaunched = WatchGrant.restored(from: grant.encoded)
        let watch = relaunched.authorization
        // A lock or switch revokes even a grant restored at launch and not yet confirmed.
        relaunched.revoke()
        #expect(!relaunched.authorization.isGranted)
        #expect(relaunched.scope == nil)
        #expect(relaunched.profileID == nil)
        #expect(clearsWatch(holding: watch, on: relaunched.authorization))
        let revoked = relaunched.authorization
        relaunched.revoke()
        #expect(relaunched.authorization.revision == revoked.revision + 1)
        // The revocation survives a relaunch.
        var afterRevocation = WatchGrant.restored(from: relaunched.encoded)
        #expect(afterRevocation.authorization == relaunched.authorization)
        let closed = afterRevocation.update(scope: nil, profileID: nil)
        #expect(closed == .unchanged)
        #expect(!afterRevocation.authorization.isGranted)
    }

    @Test func snapshotsStayOrderedAcrossRelaunchesAndRestartWithANewGrant() {
        var grant = WatchGrant.restored(from: nil)
        _ = grant.update(scope: library, profileID: profileA)
        let sent = [grant.nextSnapshotRevision(), grant.nextSnapshotRevision()]
        #expect(sent == [1, 2])
        var relaunched = WatchGrant.restored(from: grant.encoded)
        _ = relaunched.update(scope: library, profileID: profileA)
        // The Watch keeps snapshot 2; anything numbered lower would be discarded as stale.
        let afterRelaunch = relaunched.nextSnapshotRevision()
        #expect(afterRelaunch == 3)
        let switched = relaunched.update(scope: WatchGrant.scope(profileID: "profile-b", sourceID: "nas|me", rootPath: "/music"),
                                         profileID: "profile-b")
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
        let changes = [grant.update(scope: nil, profileID: nil), grant.update(scope: library, profileID: profileA),
                       grant.update(scope: library, profileID: profileA)]
        #expect(changes == [.unchanged, .granted, .unchanged])
        #expect(grant.authorization == WatchAuthorization(revision: 8, isGranted: true))
        // Once saved in the new form, a lower legacy value left behind is ignored.
        let stale = WatchAuthorization(revision: 3, isGranted: false)
        let restored = WatchGrant.restored(from: grant.encoded, legacyAuthorization: stale.encoded)
        #expect(restored.authorization == grant.authorization)
        // With no profile saved, any profile opening moves it on, even before its library is ready.
        var early = WatchGrant.restored(from: nil, legacyAuthorization: legacy.encoded)
        let opened = early.update(scope: nil, profileID: profileA)
        #expect(opened == .revoked)
    }

    @Test func aDowngradesHigherLegacyRevisionIsContinuedRatherThanRolledBack() {
        var grant = WatchGrant.restored(from: nil, legacyAuthorization: WatchAuthorization(revision: 7, isGranted: true).encoded)
        _ = grant.update(scope: library, profileID: profileA)
        #expect(grant.authorization.revision == 8)
        // An older version, run again after this one, moved the Watch on to its own revision.
        let watch = WatchAuthorization(revision: 12, isGranted: false)
        #expect(!watch.accepts(grant.authorization))
        var restored = WatchGrant.restored(from: grant.encoded, legacyAuthorization: watch.encoded)
        #expect(restored.authorization == watch)
        #expect(restored.scope == nil)
        #expect(restored.profileID == nil)
        let reopened = restored.update(scope: library, profileID: profileA)
        #expect(reopened == .granted)
        #expect(restored.authorization == WatchAuthorization(revision: 13, isGranted: true))
        #expect(watch.accepts(restored.authorization))
        // An equal revision may be that version's grant for another profile, so it is not continued either.
        let tied = WatchGrant.restored(from: grant.encoded, legacyAuthorization: grant.authorization.encoded)
        #expect(tied.authorization == grant.authorization)
        #expect(tied.scope == nil)
    }

    @Test func unreadableOrMissingStateStartsWithNothingGranted() {
        for data in [nil, Data("{}".utf8), Data("not json".utf8)] {
            let grant = WatchGrant.restored(from: data)
            #expect(grant.authorization == WatchAuthorization(revision: 0, isGranted: false))
            #expect(grant.scope == nil)
            #expect(grant.profileID == nil)
            #expect(grant.snapshotRevision == 0)
        }
    }

    @Test func scopeIsSavedInAStableFormWithoutDelimiterCollisions() {
        // Saved with the grant and compared after an update, so changing this encoding clears every
        // Watch once. Profile sessions are new on every opening, so they are never part of it.
        #expect(library == "9:profile-a6:nas|me6:/music")
        #expect(WatchGrant.scope(profileID: "a|b", sourceID: "c", rootPath: "d") != WatchGrant.scope(profileID: "a", sourceID: "b|c", rootPath: "d"))
        #expect(WatchGrant.scope(profileID: "a", sourceID: "b|c", rootPath: "d") != WatchGrant.scope(profileID: "a", sourceID: "b", rootPath: "c|d"))
        #expect(WatchGrant.scope(profileID: "a", sourceID: "1:b", rootPath: "") != WatchGrant.scope(profileID: "a1:", sourceID: "b", rootPath: ""))
    }

    /// What `WatchStore.accept` does on the Watch: anything newer than what it holds clears it.
    private func clearsWatch(holding current: WatchAuthorization, on incoming: WatchAuthorization) -> Bool {
        current.accepts(incoming) && incoming != current
    }
}
