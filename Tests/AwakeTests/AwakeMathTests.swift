import Foundation
import Testing

@testable import Awake

/// A fixed calendar so the tests do not depend on the machine's locale or time zone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    calendar.locale = Locale(identifier: "en_US") // weekend = Saturday and Sunday
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second
    ))!
}

// October 2026: Wed 7, Fri 2, Sat 3, Sun 4, Mon 5.
@Suite("Splitting an interval into days")
struct SplitTests {
    @Test("Calendar assumptions used below hold")
    func calendarAssumptions() {
        #expect(calendar.component(.weekday, from: date(2026, 10, 2)) == 6) // Friday
        #expect(calendar.isDateInWeekend(date(2026, 10, 3)))
        #expect(calendar.isDateInWeekend(date(2026, 10, 4)))
        #expect(!calendar.isDateInWeekend(date(2026, 10, 5)))
    }

    @Test("Interval within a weekday goes to that day")
    func withinWeekday() {
        let result = AwakeMath.split(
            from: date(2026, 10, 7, 10, 0, 0), to: date(2026, 10, 7, 10, 0, 30), calendar: calendar
        )
        #expect(result == ["2026-10-07": 30])
    }

    @Test("Friday to Saturday: only the Friday part counts")
    func fridayIntoSaturday() {
        let result = AwakeMath.split(
            from: date(2026, 10, 2, 23, 59, 50), to: date(2026, 10, 3, 0, 0, 20), calendar: calendar
        )
        #expect(result == ["2026-10-02": 10])
    }

    @Test("Sunday to Monday: only the Monday part counts")
    func sundayIntoMonday() {
        let result = AwakeMath.split(
            from: date(2026, 10, 4, 23, 59, 50), to: date(2026, 10, 5, 0, 0, 20), calendar: calendar
        )
        #expect(result == ["2026-10-05": 20])
    }

    @Test("Interval crossing midnight between two weekdays is split between them")
    func weekdayIntoWeekday() {
        let result = AwakeMath.split(
            from: date(2026, 10, 7, 23, 59, 45), to: date(2026, 10, 8, 0, 0, 15), calendar: calendar
        )
        #expect(result == ["2026-10-07": 15, "2026-10-08": 15])
    }

    @Test("Weekend interval counts nothing")
    func weekendOnly() {
        let result = AwakeMath.split(
            from: date(2026, 10, 3, 12, 0, 0), to: date(2026, 10, 3, 12, 0, 30), calendar: calendar
        )
        #expect(result.isEmpty)
    }

    @Test("A gap of 90 s or more is dropped, 89 s is kept")
    func gapLimit() {
        let start = date(2026, 10, 7, 10, 0, 0)
        #expect(AwakeMath.split(from: start, to: start.addingTimeInterval(120), calendar: calendar).isEmpty)
        #expect(AwakeMath.split(from: start, to: start.addingTimeInterval(90), calendar: calendar).isEmpty)
        #expect(AwakeMath.split(from: start, to: start.addingTimeInterval(89), calendar: calendar) == ["2026-10-07": 89])
    }

    @Test("A backwards or empty interval counts nothing")
    func notPositive() {
        let start = date(2026, 10, 7, 10, 0, 0)
        #expect(AwakeMath.split(from: start, to: start, calendar: calendar).isEmpty)
        #expect(AwakeMath.split(from: start, to: start.addingTimeInterval(-10), calendar: calendar).isEmpty)
    }
}

/// Work days: with a 7:00 reset, Tue 07:00 up to Wed 06:59:59 is filed under Tuesday.
/// `maxGap: .infinity` lets these tests use hour-long intervals.
@Suite("Work-day reset")
struct ResetTests {
    private let reset = 7 * 60

    private func split(_ from: Date, _ to: Date, reset: Int? = nil) -> [String: TimeInterval] {
        AwakeMath.split(from: from, to: to, calendar: calendar, resetMinute: reset ?? self.reset, maxGap: .infinity)
    }

    @Test("Tue 06:30-07:30 splits at the reset: 30 min to Monday, 30 min to Tuesday")
    func crossingTheReset() {
        #expect(split(date(2026, 10, 6, 6, 30), date(2026, 10, 6, 7, 30)) == ["2026-10-05": 1800, "2026-10-06": 1800])
    }

    @Test("Wed 02:00-03:00 counts toward Tuesday")
    func afterMidnightBelongsToPreviousDay() {
        #expect(split(date(2026, 10, 7, 2), date(2026, 10, 7, 3)) == ["2026-10-06": 3600])
    }

    @Test("Fri 23:00 to Sat 08:00: 8 h to Friday, the Saturday 07:00-08:00 hour to nothing")
    func fridayIntoSaturday() {
        #expect(split(date(2026, 10, 2, 23), date(2026, 10, 3, 8)) == ["2026-10-02": 8 * 3600])
    }

    @Test("Sun 23:00 to Mon 06:00 counts nothing: it falls under Sunday")
    func sundayNightIntoMonday() {
        #expect(split(date(2026, 10, 4, 23), date(2026, 10, 5, 6)).isEmpty)
    }

    @Test("Mon 06:00-08:00 gives 1 h to Monday; the first hour still belongs to Sunday")
    func mondayMorning() {
        #expect(split(date(2026, 10, 5, 6), date(2026, 10, 5, 8)) == ["2026-10-05": 3600])
    }

    @Test("Sat 07:00 to Mon 07:00 counts nothing")
    func wholeWeekend() {
        #expect(split(date(2026, 10, 3, 7), date(2026, 10, 5, 7)).isEmpty)
    }

    @Test("Fri 07:00 to Sat 07:00 is all Friday")
    func fullFriday() {
        #expect(split(date(2026, 10, 2, 7), date(2026, 10, 3, 7)) == ["2026-10-02": 24 * 3600])
    }

    @Test("A reset of 0 is the old midnight logic")
    func resetZeroIsMidnight() {
        #expect(split(date(2026, 10, 2, 23, 59, 50), date(2026, 10, 3, 0, 0, 20), reset: 0) == ["2026-10-02": 10])
        #expect(split(date(2026, 10, 4, 23, 59, 50), date(2026, 10, 5, 0, 0, 20), reset: 0) == ["2026-10-05": 20])
        #expect(split(date(2026, 10, 7, 2), date(2026, 10, 7, 3), reset: 0) == ["2026-10-07": 3600])
    }

    @Test("The reset still honours the 90 s gap limit")
    func gapStillDropped() {
        let start = date(2026, 10, 7, 10)
        let result = AwakeMath.split(from: start, to: start.addingTimeInterval(120), calendar: calendar, resetMinute: reset)
        #expect(result.isEmpty)
    }

    @Test("workDay(containing:) is the day the last reset started")
    func workDayLookup() {
        func key(_ date: Date, reset: Int) -> String {
            AwakeMath.dayKey(for: AwakeMath.workDay(containing: date, calendar: calendar, resetMinute: reset), calendar: calendar)
        }
        #expect(key(date(2026, 10, 6, 6, 59, 59), reset: 420) == "2026-10-05")
        #expect(key(date(2026, 10, 6, 7, 0, 0), reset: 420) == "2026-10-06")
        #expect(key(date(2026, 10, 6, 23, 59, 59), reset: 420) == "2026-10-06")
        #expect(key(date(2026, 10, 6, 0, 0, 0), reset: 0) == "2026-10-06")
    }

    // Daylight saving. Cairo (Africa/Cairo) moves its clocks on weekdays, so it exercises
    // days that are not 24 h long. The reset instant must come from the calendar, not from
    // "midnight + 7 h" in seconds. If the system's time zone data has no such day, these
    // tests have nothing to check and return early.

    private static let cairo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func cairoDate(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.cairo.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func dayLength(month: Int, day: Int) -> TimeInterval {
        let start = Self.cairo.startOfDay(for: cairoDate(month, day, 12))
        let next = Self.cairo.startOfDay(for: Self.cairo.date(byAdding: .day, value: 1, to: start)!)
        return next.timeIntervalSince(start)
    }

    @Test("Spring-forward day (23 h, no midnight): the 07:00 reset is still 07:00 local")
    func shortDay() {
        guard dayLength(month: 4, day: 24) == 23 * 3600 else { return }
        // Fri 24 Apr 2026 starts at 01:00. "Midnight + 7 h" would be 08:00 and put all of
        // 06:30-07:30 under Thursday.
        let result = AwakeMath.split(
            from: cairoDate(4, 24, 6, 30), to: cairoDate(4, 24, 7, 30),
            calendar: Self.cairo, resetMinute: 420, maxGap: .infinity
        )
        #expect(result == ["2026-04-23": 1800, "2026-04-24": 1800])
    }

    @Test("Fall-back day (25 h): Thu 07:00 to Fri 07:00 is one work day of 25 real hours")
    func longDay() {
        guard dayLength(month: 10, day: 29) == 25 * 3600 else { return }
        let result = AwakeMath.split(
            from: cairoDate(10, 29, 7), to: cairoDate(10, 30, 7),
            calendar: Self.cairo, resetMinute: 420, maxGap: .infinity
        )
        #expect(result == ["2026-10-29": 25 * 3600])
    }
}

@Suite("Battery cutoff decision")
struct CutoffTests {
    @Test("On AC never cuts off, even at 5%")
    func onAC() {
        #expect(!AwakeMath.isBatteryCutOff(onAC: true, charge: 5, threshold: 20))
    }

    @Test("On battery below the threshold cuts off")
    func belowThreshold() {
        #expect(AwakeMath.isBatteryCutOff(onAC: false, charge: 19, threshold: 20))
    }

    @Test("On battery at exactly the threshold does not cut off")
    func atThreshold() {
        #expect(!AwakeMath.isBatteryCutOff(onAC: false, charge: 20, threshold: 20))
    }

    @Test("On battery above the threshold does not cut off")
    func aboveThreshold() {
        #expect(!AwakeMath.isBatteryCutOff(onAC: false, charge: 60, threshold: 20))
    }

    @Test("A Mac with no battery is never cut off")
    func noBattery() {
        #expect(!AwakeMath.isBatteryCutOff(onAC: true, charge: nil, threshold: 80))
        #expect(!AwakeMath.isBatteryCutOff(onAC: false, charge: nil, threshold: 80))
    }
}

@Suite("Week, history and formatting")
struct MiscTests {
    @Test("Work week is Monday to Friday of the current week")
    func workweekMidWeek() {
        let days = AwakeMath.workweek(containing: date(2026, 10, 7, 15), calendar: calendar)
        #expect(days.map { AwakeMath.dayKey(for: $0, calendar: calendar) } == [
            "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09",
        ])
    }

    @Test("On a weekend the work week shown is the one that just ended")
    func workweekOnWeekend() {
        for day in [3, 4] {
            let days = AwakeMath.workweek(containing: date(2026, 10, day, 15), calendar: calendar)
            #expect(AwakeMath.dayKey(for: days[0], calendar: calendar) == "2026-09-28")
            #expect(AwakeMath.dayKey(for: days[4], calendar: calendar) == "2026-10-02")
        }
    }

    @Test("History older than 60 days is pruned, newer is kept")
    func pruning() {
        let now = date(2026, 10, 7, 12)
        let history: [String: TimeInterval] = [
            "2026-10-07": 100, // today
            "2026-08-09": 200, // 59 days ago: kept
            "2026-08-08": 300, // 60 days ago: pruned
            "2025-01-01": 400,
        ]
        #expect(AwakeMath.pruned(history, now: now, calendar: calendar) == ["2026-10-07": 100, "2026-08-09": 200])
    }

    @Test("Durations are floored to whole minutes")
    func durationFormat() {
        #expect(Format.duration(0) == "0h 0m")
        #expect(Format.duration(5 * 3600 + 12 * 60 + 59) == "5h 12m")
        #expect(Format.duration(8 * 3600) == "8h 0m")
        #expect(Format.duration(-5) == "0h 0m")
    }
}
