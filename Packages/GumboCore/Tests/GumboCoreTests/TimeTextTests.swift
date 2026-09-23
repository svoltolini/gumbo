import Foundation
import Testing
@testable import GumboCore

@Test func clockShowsMinutesAndSecondsUnderAnHour() {
    #expect(TimeText.clock(0) == "0:00")
    #expect(TimeText.clock(-3) == "0:00")
    #expect(TimeText.clock(331.9) == "5:31")
    #expect(TimeText.clock(3599) == "59:59")
}

@Test func clockAddsHoursFromAnHour() {
    #expect(TimeText.clock(3600) == "1:00:00")
    #expect(TimeText.clock(4512) == "1:15:12")
    #expect(TimeText.clock(3760) == "1:02:40")
    #expect(TimeText.clock(36_005) == "10:00:05")
}
