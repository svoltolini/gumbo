import Foundation

/// Picks that stay put all day and change overnight: the day as the listener's own clock has it,
/// and a hash that gives the same order on every launch.
nonisolated enum DailySeed {
    /// "2026-09-23" in the calendar's time zone, so the day turns at local midnight rather than UTC's.
    static func dayKey(for date: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// FNV-1a: the same value for the same text on every launch, unlike `hashValue`.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
