import Foundation
import Testing
@testable import Memozia

struct CurrentTimeServiceTests {
    @Test func sameInstantUsesLocalDateAcrossYearBoundary() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-12-31T16:30:45Z"))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let chinaContext = CurrentTimeService.promptContext(now: now, timeZone: shanghai)
        #expect(chinaContext.contains("当前时间：2027-01-01T00:30:45+08:00"))
        #expect(chinaContext.contains("当前日期：2027-01-01（星期五）"))
        #expect(chinaContext.contains("本地时区：Asia/Shanghai"))

        let usContext = CurrentTimeService.promptContext(now: now, timeZone: losAngeles)
        #expect(usContext.contains("当前时间：2026-12-31T08:30:45-08:00"))
        #expect(usContext.contains("当前日期：2026-12-31（星期四）"))
        #expect(usContext.contains("本地时区：America/Los_Angeles"))
    }

    @Test func readsOffsetForEachInstantAcrossDaylightSavingTransition() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let parser = ISO8601DateFormatter()
        let before = try #require(parser.date(from: "2026-03-08T09:59:59Z"))
        let after = try #require(parser.date(from: "2026-03-08T10:00:00Z"))

        let beforeContext = CurrentTimeService.promptContext(now: before, timeZone: zone)
        let afterContext = CurrentTimeService.promptContext(now: after, timeZone: zone)
        #expect(beforeContext.contains("当前时间：2026-03-08T01:59:59-08:00"))
        #expect(afterContext.contains("当前时间：2026-03-08T03:00:00-07:00"))
        #expect(afterContext.contains("当前日期：2026-03-08（星期日）"))
    }

    @Test func supportsFractionalHourTimeZones() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z"))
        let zone = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        let context = CurrentTimeService.promptContext(now: now, timeZone: zone)
        #expect(context.contains("当前时间：2026-10-22T05:45:00+05:45"))
        #expect(context.contains("当前日期：2026-10-22（星期四）"))
    }
}
