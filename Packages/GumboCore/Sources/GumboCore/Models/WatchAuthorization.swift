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

/// Latest playback intent wins even when audio-session activation completes out of order.
public nonisolated struct PlaybackIntentRevision: Sendable {
    public private(set) var value: UInt64 = 0
    public init() {}
    @discardableResult public mutating func advance() -> UInt64 { value &+= 1; return value }
    public func accepts(_ revision: UInt64) -> Bool { value == revision }
}
