import Foundation
import Observation

/// Counts how long the Mac is awake each weekday.
///
/// Time counts only while the system is awake, the lid is open and the battery
/// cutoff has not stopped the app. It is independent of the keep-awake toggle:
/// it measures awake time, not assertion time.
///
/// `lastTick` is the moment up to which time has already been added. While
/// counting, `now - lastTick` is the small not-yet-stored remainder, which the
/// popover adds on top of the stored value to show a live time.
@MainActor
@Observable
final class AwakeTracker {
    private let store: any HistoryStoring
    private let settings: any SettingsStoring
    private let calendar: Calendar
    private let onGoalReached: @MainActor () -> Void

    /// Minutes after local midnight at which the work day resets (see `AwakeMath.workDay`).
    /// The only observed property: the popover reacts when it changes.
    private(set) var dayResetMinute: Int

    @ObservationIgnored private var history: [String: TimeInterval]
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var isDirty = false

    // Conditions that stop counting.
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var lidClosed = false
    @ObservationIgnored private var cutOff = false

    init(
        store: any HistoryStoring,
        settings: any SettingsStoring,
        calendar: Calendar = .autoupdatingCurrent,
        onGoalReached: @escaping @MainActor () -> Void = { Notifier.postGoalReached() }
    ) {
        self.store = store
        self.settings = settings
        self.calendar = calendar
        self.onGoalReached = onGoalReached
        history = AwakeMath.pruned(store.load(), now: .now, calendar: calendar)

        let stored = settings.dayResetMinute
        dayResetMinute = AwakeMath.resetMinuteChoices.contains(stored) ? stored : AwakeMath.defaultResetMinute
    }

    // MARK: Events

    /// Call once at launch with the current conditions.
    func start(lidClosed: Bool, cutOff: Bool, now: Date = .now) {
        self.lidClosed = lidClosed
        self.cutOff = cutOff
        updateCounting(now: now)
    }

    /// The lid opened or closed, or the battery cutoff started or ended.
    func update(lidClosed: Bool, cutOff: Bool, now: Date = .now) {
        self.lidClosed = lidClosed
        self.cutOff = cutOff
        updateCounting(now: now)
    }

    /// Timer tick (every 30 s): add the elapsed time and persist.
    func tick(now: Date = .now) {
        updateCounting(now: now) // also self-heals if we should be counting but are not
        accumulate(now: now)
        saveIfNeeded()
    }

    /// The system is about to sleep: bank the time up to now and stop counting.
    func willSleep(now: Date = .now) {
        accumulate(now: now)
        lastTick = nil
        isAsleep = true
        saveIfNeeded()
    }

    /// The system woke: the sleep gap is never counted, so restart from now.
    func didWake(now: Date = .now) {
        isAsleep = false
        updateCounting(now: now)
    }

    /// Changes when the day resets. It applies from now on: time up to now is
    /// banked with the old setting first, and nothing already stored is re-bucketed.
    func setDayReset(_ minute: Int, now: Date = .now) {
        guard minute != dayResetMinute, AwakeMath.resetMinuteChoices.contains(minute) else { return }
        accumulate(now: now)
        dayResetMinute = minute
        settings.dayResetMinute = minute
    }

    /// The work day (as its filing date's midnight) that contains `now`. This is "today".
    func currentWorkDay(now: Date = .now) -> Date {
        AwakeMath.workDay(containing: now, calendar: calendar, resetMinute: dayResetMinute)
    }

    /// The app is quitting.
    func flush(now: Date = .now) {
        accumulate(now: now)
        saveIfNeeded()
    }

    // MARK: Reading

    /// Stored seconds for the work day filed under the calendar day of `date`, plus
    /// the live remainder since the last tick when that work day is being counted now.
    func seconds(on date: Date, now: Date = .now) -> TimeInterval {
        let key = AwakeMath.dayKey(for: date, calendar: calendar)
        var total = history[key] ?? 0
        if let last = lastTick {
            total += AwakeMath.split(from: last, to: now, calendar: calendar, resetMinute: dayResetMinute)[key] ?? 0
        }
        return total
    }

    // MARK: Internals

    private var shouldCount: Bool { !isAsleep && !lidClosed && !cutOff }

    /// Starts or stops counting so it matches the current conditions.
    private func updateCounting(now: Date) {
        if shouldCount {
            if lastTick == nil { lastTick = now }
        } else if lastTick != nil {
            accumulate(now: now)
            lastTick = nil
        }
    }

    /// Adds `lastTick ... now` to the right day buckets and moves `lastTick` to `now`.
    private func accumulate(now: Date) {
        guard let last = lastTick else { return }
        let parts = AwakeMath.split(from: last, to: now, calendar: calendar, resetMinute: dayResetMinute)
        for (key, seconds) in parts {
            history[key, default: 0] += seconds
        }
        if !parts.isEmpty { isDirty = true }
        lastTick = now
        notifyIfGoalReached(now: now)
    }

    /// One notification per day when today first reaches the target.
    /// Suppressed while the battery cutoff has the app dormant.
    private func notifyIfGoalReached(now: Date) {
        guard !cutOff else { return }
        let key = AwakeMath.dayKey(for: currentWorkDay(now: now), calendar: calendar)
        guard (history[key] ?? 0) >= AwakeMath.dailyTarget,
              settings.lastGoalNotifiedDay != key else { return }
        settings.lastGoalNotifiedDay = key
        onGoalReached()
    }

    private func saveIfNeeded() {
        guard isDirty else { return }
        history = AwakeMath.pruned(history, now: .now, calendar: calendar)
        store.save(history)
        isDirty = false
    }
}
