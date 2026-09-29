import Foundation

/// Pure, side-effect-free helpers. Everything the app decides about time and
/// battery lives here so it can be unit tested without touching the system.
enum AwakeMath {
    /// Longest gap between two ticks that still counts as "awake the whole time".
    /// A larger gap means the Mac was asleep (or the app was frozen), so it is dropped.
    static let maxGap: TimeInterval = 90

    /// Daily awake-time goal.
    static let dailyTarget: TimeInterval = 8 * 3600

    /// How many days of history are kept on disk.
    static let keepDays = 60

    /// "Day resets at" choices: minutes after midnight, in 10-minute steps, 00:00 to 23:50.
    static let resetMinuteChoices = Array(stride(from: 0, through: 23 * 60 + 50, by: 10))
    static let defaultResetMinute = 7 * 60

    /// Choices offered for the low-battery cutoff, in percent.
    static let cutoffChoices = [10, 20, 30, 40, 50, 60, 70, 80]
    static let defaultCutoff = 20

    // MARK: Day keys

    /// `yyyy-MM-dd` key for the calendar day containing `date`.
    /// Built from calendar components (not DateFormatter) so it is cheap and locale-proof.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Work days

    // A "work day" runs from the reset time on date D to the reset time on D+1
    // and is filed under D (`yyyy-MM-dd`). With a 7:00 reset, Tue 07:00 up to
    // Wed 06:59:59 all belong to Tuesday, and Wed 02:00 counts toward Tuesday.
    // A reset of 0 (midnight) makes work days identical to calendar days.

    /// The moment the work day filed under the calendar day containing `dayStart` begins.
    /// Built with `Calendar`, not by adding seconds, so daylight-saving days stay correct.
    static func resetInstant(onDayOf day: Date, calendar: Calendar, resetMinute: Int) -> Date {
        let dayStart = calendar.startOfDay(for: day)
        let minute = min(max(resetMinute, 0), 24 * 60 - 1)
        guard minute > 0,
              let instant = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart)
        else { return dayStart }
        return instant
    }

    /// The work day (as the midnight of its filing date) that contains `date`.
    static func workDay(containing date: Date, calendar: Calendar, resetMinute: Int) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        if date >= resetInstant(onDayOf: dayStart, calendar: calendar, resetMinute: resetMinute) {
            return dayStart
        }
        let previous = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        return calendar.startOfDay(for: previous)
    }

    // MARK: Interval splitting

    /// Turns the wall-clock interval `start ... end` into seconds per work day.
    ///
    /// - The interval is dropped entirely when it is not positive or is `maxGap`
    ///   or longer (the Mac was asleep in between).
    /// - It is split at every reset boundary (not at midnight), so each work day
    ///   gets its own share. Nothing is dropped except as below.
    /// - A work day counts only when its filing date is a weekday
    ///   (`Calendar.isDateInWeekend` is false). Fri 07:00 to Sat 07:00 counts for
    ///   Friday; Sat 07:00 to Mon 07:00 counts for nothing.
    static func split(
        from start: Date,
        to end: Date,
        calendar: Calendar,
        resetMinute: Int = 0,
        maxGap: TimeInterval = AwakeMath.maxGap
    ) -> [String: TimeInterval] {
        let gap = end.timeIntervalSince(start)
        guard gap > 0, gap < maxGap else { return [:] }

        var result: [String: TimeInterval] = [:]
        var cursor = start
        while cursor < end {
            let day = workDay(containing: cursor, calendar: calendar, resetMinute: resetMinute)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let boundary = resetInstant(onDayOf: nextDay, calendar: calendar, resetMinute: resetMinute)
            let segmentEnd = min(end, boundary)
            guard segmentEnd > cursor else { break }
            if !calendar.isDateInWeekend(day) {
                result[dayKey(for: day, calendar: calendar), default: 0] += segmentEnd.timeIntervalSince(cursor)
            }
            cursor = segmentEnd
        }
        return result
    }

    // MARK: Week

    /// The five dates Monday...Friday of the week containing `date`.
    /// On Saturday/Sunday this is the work week that just ended.
    static func workweek(containing date: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: today) // 1 = Sunday ... 7 = Saturday
        let daysSinceMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) else { return [] }
        return (0..<5).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    // MARK: History pruning

    /// Drops entries older than `keepDays` days (today counts as day one).
    static func pruned(
        _ history: [String: TimeInterval],
        now: Date,
        calendar: Calendar,
        keepDays: Int = AwakeMath.keepDays
    ) -> [String: TimeInterval] {
        guard let oldest = calendar.date(byAdding: .day, value: -(keepDays - 1), to: calendar.startOfDay(for: now)) else {
            return history
        }
        let cutoffKey = dayKey(for: oldest, calendar: calendar)
        // `yyyy-MM-dd` keys sort chronologically as plain strings.
        return history.filter { $0.key >= cutoffKey }
    }

    // MARK: Battery cutoff

    /// Whether the whole app should go dormant because the battery is low.
    ///
    /// True only when running on battery power, with a known charge strictly below
    /// the threshold. A Mac without a battery reports no charge and is never cut off.
    static func isBatteryCutOff(onAC: Bool, charge: Int?, threshold: Int) -> Bool {
        guard !onAC, let charge else { return false }
        return charge < threshold
    }

    // MARK: Auto-charge (smart plug)

    /// Start and stop levels move in 5% steps.
    static let chargeStep = 5
    static let defaultChargeStart = 30
    static let defaultChargeStop = 90

    /// "Start charging at" choices: above the cutoff and below the stop level.
    static func chargeStartChoices(cutoff: Int, stop: Int) -> [Int] {
        Array(stride(from: cutoff + chargeStep, through: stop - chargeStep, by: chargeStep))
    }

    /// "Stop charging at" choices: above the start level, up to 100%.
    static func chargeStopChoices(start: Int) -> [Int] {
        Array(stride(from: start + chargeStep, through: 100, by: chargeStep))
    }

    /// Makes the levels valid for `cutoff`: cutoff < start < stop <= 100, on the
    /// 5% grid. A start at or below the cutoff moves up to just above it, and a
    /// stop that is no longer above the start moves up with it.
    static func clampedChargeLevels(cutoff: Int, start: Int, stop: Int) -> (start: Int, stop: Int) {
        let snap = { (value: Int) in (value / chargeStep) * chargeStep }
        let clampedStart = min(max(snap(start), cutoff + chargeStep), 100 - chargeStep)
        let clampedStop = min(max(snap(stop), clampedStart + chargeStep), 100)
        return (clampedStart, clampedStop)
    }

    enum PlugAction: Equatable {
        case turnOn
        case turnOff
    }

    /// What the smart plug should do now, or nil to leave it alone.
    ///
    /// - On battery at or below `start`: turn the charger on.
    /// - Charging at or above `stop`: turn it off.
    /// - Anything in between: nothing, so a manual switch in the app or on the
    ///   plug is never undone until the next level is reached.
    static func plugAction(onAC: Bool, charge: Int?, start: Int, stop: Int) -> PlugAction? {
        guard let charge else { return nil }
        if !onAC && charge <= start { return .turnOn }
        if onAC && charge >= stop { return .turnOff }
        return nil
    }
}

// MARK: - Keep-awake mode

/// What Awake is doing to keep the Mac awake: exactly one of three modes, chosen with the
/// segmented picker in the menu.
enum KeepAwakeMode: String, CaseIterable, Equatable {
    /// Nothing is held: the Mac sleeps normally.
    case off
    /// The screen may go dark, work keeps running.
    case screenCanSleep
    /// The screen stays lit.
    case screenOn

    /// Which power assertions a mode holds.
    struct Assertions: Equatable {
        /// PreventUserIdleSystemSleep
        var systemSleep: Bool
        /// PreventUserIdleDisplaySleep
        var displaySleep: Bool
    }

    /// `.screenOn` holds the system assertion as well as the display one. Holding both is
    /// redundant but explicit.
    var heldAssertions: Assertions {
        switch self {
        case .off: Assertions(systemSleep: false, displaySleep: false)
        case .screenCanSleep: Assertions(systemSleep: true, displaySleep: false)
        case .screenOn: Assertions(systemSleep: true, displaySleep: true)
        }
    }

    /// One-time migration from the two old settings (`keepAwakeEnabled`, default on, and
    /// `keepDisplayOn`, default off). `nil` means the key was never saved.
    /// Screen-on wins; otherwise the old keep-awake switch decides.
    static func migrated(keepAwakeEnabled: Bool?, keepDisplayOn: Bool?) -> KeepAwakeMode {
        if keepDisplayOn == true { return .screenOn }
        return (keepAwakeEnabled ?? true) ? .screenCanSleep : .off
    }
}
