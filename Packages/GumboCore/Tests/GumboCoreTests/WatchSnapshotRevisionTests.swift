import Foundation
import Testing
@testable import GumboCore

@Suite struct WatchSnapshotRevisionTests {
    @Test func oldPhoneDefaultsToRevisionZero() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        json.removeValue(forKey: "snapshotRevision")
        let old = try JSONDecoder().decode(WatchCatalogue.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.snapshotRevision == 0)
        #expect(old.isAtLeastAsRecent(as: snapshot()))
        #expect(!old.isAtLeastAsRecent(as: snapshot(revision: 1)))
    }

    @Test func lateInitialSnapshotCannotReplaceArtworkFollowUp() {
        let initial = snapshot(revision: 1)
        var withArtwork = snapshot(revision: 2)
        withArtwork.artwork = ["album": Data([1, 2])]
        #expect(withArtwork.isAtLeastAsRecent(as: initial))
        #expect(!initial.isAtLeastAsRecent(as: withArtwork))
        #expect(withArtwork.isAtLeastAsRecent(as: withArtwork))
    }

    @Test func newerSnapshotCannotRollBackConfirmedDeletions() {
        let current = snapshot(revision: 5, deletion: 3)
        #expect(!snapshot(revision: 6, deletion: 2).isAtLeastAsRecent(as: current))
        #expect(snapshot(revision: 6, deletion: 4).isAtLeastAsRecent(as: current))
    }

    @Test func snapshotRevisionTravelsButDoesNotTriggerRedundantTransfers() throws {
        let original = snapshot(revision: 1)
        var next = original
        next.snapshotRevision = 2
        next.generatedAt = next.generatedAt.addingTimeInterval(1)
        #expect(original.contentKey == next.contentKey)
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: JSONEncoder().encode(next))
        #expect(decoded.snapshotRevision == 2)
        #expect(decoded.contentKey == original.contentKey)
    }

    private func snapshot(revision: UInt64 = 0, deletion: UInt64 = 0) -> WatchCatalogue {
        var result = WatchCatalogue(serverName: "Fixture NAS", profileName: "Fixture", playlists: [])
        result.snapshotRevision = revision
        result.serverDeletionRevision = deletion
        return result
    }
}
