import Foundation

/// Wrong PINs entered for one profile on this device, and how long the keypad now waits (#257).
/// A few mistakes cost nothing; after that every wrong PIN makes the next wait longer, the way the
/// device passcode does, so working through all 10,000 PINs by hand takes more than a year. Only a
/// right PIN, a new PIN or the profile's removal starts the count again.
nonisolated struct PINAttempts: Codable, Equatable, Sendable {
    private(set) var failures = 0
    private(set) var lockedUntil: Date?

    /// Wrong PINs allowed before the first wait.
    static let freeFailures = 4

    /// The wait that follows this many wrong PINs in a row, if any.
    static func delay(afterFailures failures: Int) -> TimeInterval? {
        switch failures - freeFailures {
        case ..<1: return nil
        case 1: return 30
        case 2: return 60
        case 3: return 5 * 60
        case 4: return 15 * 60
        default: return 60 * 60
        }
    }

    /// When the next PIN may be tried, or nil when one may be tried now. A clock set back never
    /// makes the wait longer than the policy's own.
    func retryDate(now: Date) -> Date? {
        guard let lockedUntil, lockedUntil > now else { return nil }
        let longest = now.addingTimeInterval(Self.delay(afterFailures: failures) ?? 0)
        return min(lockedUntil, longest)
    }

    mutating func recordFailure(now: Date) {
        failures += 1
        lockedUntil = Self.delay(afterFailures: failures).map { now.addingTimeInterval($0) }
    }
}
