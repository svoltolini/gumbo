import Foundation
import Testing
@testable import GumboCore

@Suite struct DailySeedTests {
    @Test func theDayTurnsAtLocalMidnightNotUTCs() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        // 17:30 in Los Angeles on 22 September is already 23 September in UTC.
        let evening = try #require(pacific.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 17, minute: 30)))
        #expect(DailySeed.dayKey(for: evening, calendar: pacific) == "2026-09-22")
        let lateNight = try #require(pacific.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 23, minute: 59)))
        #expect(DailySeed.dayKey(for: lateNight, calendar: pacific) == "2026-09-22")
        let morning = try #require(pacific.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 0, minute: 1)))
        #expect(DailySeed.dayKey(for: morning, calendar: pacific) == "2026-09-23")
    }

    @Test func theHashIsTheSameOnEveryLaunch() {
        // Published FNV-1a 64-bit values, so the seed can never depend on the process.
        #expect(DailySeed.stableHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(DailySeed.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(DailySeed.stableHash("2026-09-23drive") == DailySeed.stableHash("2026-09-23" + "drive"))
    }
}
