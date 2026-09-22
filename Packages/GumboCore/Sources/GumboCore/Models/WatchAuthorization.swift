import Foundation

/// One ordered authorization shared by every Watch transport. Persist both ends so queued
/// deliveries cannot restore an earlier profile after a lock, including after relaunch.
public nonisolated struct WatchAuthorization: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let isGranted: Bool

    public init(revision: UInt64, isGranted: Bool) {
        self.revision = revision
        self.isGranted = isGranted
    }

    public func successor(granted: Bool) -> Self {
        Self(revision: revision + 1, isGranted: granted)
    }

    public func accepts(_ incoming: Self) -> Bool {
        incoming.revision > 0 && (incoming.revision > revision || incoming == self)
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> Self? {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), value.revision > 0 else { return nil }
        return value
    }
}

/// The iPhone's side of the Watch authorization. Its revision belongs to the open library (profile,
/// source and folder), not to the app process: the Watch clears everything whenever the revision
/// moves, so a relaunch keeps it, while a lock, switch, sign-out or other library moves it on.
public nonisolated struct WatchGrant: Codable, Sendable {
    public nonisolated enum Change: Equatable, Sendable {
        case unchanged
        /// A new revision: another library, or one opening after a revocation. Nothing prepared
        /// under the previous revision may be sent.
        case granted
        /// The library this process had open has closed, or another profile has opened.
        case revoked
    }

    public private(set) var authorization: WatchAuthorization
    /// The library the granted revision covers; nil while revoked.
    public private(set) var scope: String?
    /// The profile of that library, so that another profile opening is a switch even before its
    /// library is ready. Nil while revoked and for a legacy grant, which any opening moves on.
    public private(set) var profileID: String?
    /// The last catalogue snapshot numbered under this authorization. Saved, so snapshots sent
    /// after a relaunch are still newer than the ones the Watch already has.
    public private(set) var snapshotRevision: UInt64
    /// Whether this process has had the granted library open. A grant restored at launch is held
    /// while no library is open yet, the normal state of a background relaunch or a profile
    /// waiting for its PIN; only closing a library that was open here, or another profile
    /// opening, revokes it.
    private var isConfirmed = false

    private enum CodingKeys: String, CodingKey { case authorization, scope, profileID, snapshotRevision }

    init(authorization: WatchAuthorization, scope: String? = nil, profileID: String? = nil, snapshotRevision: UInt64 = 0) {
        self.authorization = authorization
        self.scope = scope
        self.profileID = profileID
        self.snapshotRevision = snapshotRevision
    }

    /// The saved grant exactly as it was: a launch by itself never moves the revision.
    /// Earlier versions saved only the authorization, without the library it covered, so a grant
    /// restored from one moves on, clearing the Watch once, when a profile or library next opens.
    public static func restored(from data: Data?, legacyAuthorization: Data? = nil) -> Self {
        if let data, let saved = try? JSONDecoder().decode(Self.self, from: data), saved.authorization.revision > 0 {
            return saved
        }
        return Self(authorization: WatchAuthorization.decode(legacyAuthorization) ?? .init(revision: 0, isGranted: false))
    }

    /// Identifies a library by stable identities, never by a profile session, which is new on
    /// every opening. Length prefixes keep a delimiter inside one part from matching another split.
    public static func scope(profileID: String, sourceID: String, rootPath: String) -> String {
        [profileID, sourceID, rootPath].map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Follows the library now open, nil while none is ready, and the profile open on the iPhone,
    /// ready or not; `scope` is always that profile's library. The granted library keeps its
    /// revision, even after a relaunch; any other library, or one opening after a revocation, is
    /// granted anew. Closing a library that was open in this process revokes, and so does another
    /// profile opening; a grant restored at launch waits for its own profile's library instead.
    public mutating func update(scope current: String?, profileID openProfile: String?) -> Change {
        guard let current else {
            let switched = openProfile != nil && openProfile != profileID
            guard authorization.isGranted, isConfirmed || switched else { return .unchanged }
            revoke()
            return .revoked
        }
        isConfirmed = true
        guard !authorization.isGranted || scope != current else { return .unchanged }
        authorization = authorization.successor(granted: true)
        scope = current
        profileID = openProfile
        snapshotRevision = 0
        return .granted
    }

    /// Always a new revision, even when already revoked, so the Watch clears whatever it holds.
    public mutating func revoke() {
        authorization = authorization.successor(granted: false)
        scope = nil
        profileID = nil
        snapshotRevision = 0
        isConfirmed = false
    }

    /// Numbers the next catalogue snapshot sent under this authorization.
    public mutating func nextSnapshotRevision() -> UInt64 {
        snapshotRevision += 1
        return snapshotRevision
    }

    public var encoded: Data? { try? JSONEncoder().encode(self) }
}

/// Latest playback intent wins even when audio-session activation completes out of order.
public nonisolated struct PlaybackIntentRevision: Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    @discardableResult public mutating func advance() -> UInt64 { value &+= 1; return value }
    public func accepts(_ revision: UInt64) -> Bool { value == revision }
}
