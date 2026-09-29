import Foundation
import Testing

@testable import Awake

/// Wednesday 7 Oct 2026 at 10:00 in the machine's time zone (a weekday under any locale).
private let calendar = Calendar(identifier: .gregorian)
private let t0 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

/// A tracker on in-memory storage. `restart()` builds a new tracker on the same
/// storage, like quitting and relaunching the app.
@MainActor
private final class Fixture {
    let history: InMemoryHistoryStore
    let spy: SpyHistoryStore
    let settings: InMemorySettingsStore
    let notifications = NotificationCounter()
    let tracker: AwakeTracker

    final class NotificationCounter { var count = 0 }

    init(preloaded: [String: TimeInterval] = [:], settings: InMemorySettingsStore = InMemorySettingsStore()) {
        history = InMemoryHistoryStore(preloaded)
        spy = SpyHistoryStore(wrapping: history)
        self.settings = settings
        tracker = Self.makeTracker(store: spy, settings: settings, counter: notifications)
    }

    private static func makeTracker(store: any HistoryStoring, settings: InMemorySettingsStore, counter: NotificationCounter) -> AwakeTracker {
        AwakeTracker(store: store, settings: settings, calendar: calendar, onGoalReached: { counter.count += 1 })
    }

    /// A new tracker instance on the same history and settings.
    func restart() -> AwakeTracker {
        Self.makeTracker(store: history, settings: settings, counter: notifications)
    }

    func seconds(at now: Date) -> TimeInterval { tracker.seconds(on: t0, now: now) }
}

@MainActor
@Suite("Awake-time tracking")
struct AwakeTrackerTests {
    @Test("Ticks add elapsed time and persist it")
    func ticksAccumulate() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))
        f.tracker.tick(now: t0.addingTimeInterval(60))
        #expect(f.seconds(at: t0.addingTimeInterval(60)) == 60)
        #expect(f.history.stored["2026-10-07"] == 60)
    }

    @Test("The live value includes the time since the last tick")
    func liveRemainder() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))
        #expect(f.seconds(at: t0.addingTimeInterval(50)) == 50)
    }

    @Test("Battery cutoff banks time up to the cutoff, adds nothing while cut off, and resumes from now")
    func batteryCutoff() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))

        f.tracker.update(lidClosed: false, cutOff: true, now: t0.addingTimeInterval(45))
        f.tracker.tick(now: t0.addingTimeInterval(75))
        f.tracker.tick(now: t0.addingTimeInterval(105))
        #expect(f.seconds(at: t0.addingTimeInterval(105)) == 45) // frozen at the cutoff

        f.tracker.update(lidClosed: false, cutOff: false, now: t0.addingTimeInterval(200))
        f.tracker.tick(now: t0.addingTimeInterval(230))
        #expect(f.seconds(at: t0.addingTimeInterval(230)) == 75) // 45 + 30, the cut-off stretch is not counted
    }

    @Test("A closed lid stops counting and opening it restarts from now")
    func lid() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.update(lidClosed: true, cutOff: false, now: t0.addingTimeInterval(20))
        f.tracker.tick(now: t0.addingTimeInterval(50))
        f.tracker.update(lidClosed: false, cutOff: false, now: t0.addingTimeInterval(60))
        f.tracker.tick(now: t0.addingTimeInterval(90))
        #expect(f.seconds(at: t0.addingTimeInterval(90)) == 50) // 20 + 30
    }

    @Test("Sleep banks the time before it and never counts the sleep itself")
    func sleepAndWake() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.willSleep(now: t0.addingTimeInterval(20))
        f.tracker.didWake(now: t0.addingTimeInterval(3600))
        f.tracker.tick(now: t0.addingTimeInterval(3630))
        #expect(f.seconds(at: t0.addingTimeInterval(3630)) == 50) // 20 + 30
    }

    @Test("A tick after a long stall is dropped, not counted")
    func stalledTick() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(600))
        #expect(f.seconds(at: t0.addingTimeInterval(600)) == 0)
    }

    // MARK: 8-hour notification

    @Test("Reaching 8 h notifies once, and not again the same day")
    func goalNotifiesOnce() {
        let f = Fixture(preloaded: ["2026-10-07": AwakeMath.dailyTarget - 10])
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))
        f.tracker.tick(now: t0.addingTimeInterval(60))
        #expect(f.notifications.count == 1)
    }

    @Test("The 8 h notification is suppressed while the battery cutoff has the app stopped")
    func goalSuppressedWhenCutOff() {
        let f = Fixture(preloaded: ["2026-10-07": AwakeMath.dailyTarget - 10])
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        // The cutoff starts 30 s in; the flush that crosses 8 h happens while cut off.
        f.tracker.update(lidClosed: false, cutOff: true, now: t0.addingTimeInterval(30))
        f.tracker.tick(now: t0.addingTimeInterval(60))
        #expect(f.notifications.count == 0)
    }

    @Test("The 8 h notification is not sent again after a restart the same day")
    func goalNotDuplicatedAcrossRestart() {
        let f = Fixture(preloaded: ["2026-10-07": AwakeMath.dailyTarget - 10])
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))
        #expect(f.notifications.count == 1)
        #expect(f.settings.lastGoalNotifiedDay == "2026-10-07")

        let relaunched = f.restart()
        relaunched.start(lidClosed: false, cutOff: false, now: t0.addingTimeInterval(120))
        relaunched.tick(now: t0.addingTimeInterval(150))
        #expect(f.notifications.count == 1)
    }

    // MARK: Day reset (default 7:00 AM)

    @Test("Time before the reset is filed under the previous day")
    func earlyMorningBelongsToPreviousDay() {
        let f = Fixture()
        let wed2am = at(2)
        let tue = at(12, day: 6)
        f.tracker.start(lidClosed: false, cutOff: false, now: wed2am)
        f.tracker.tick(now: wed2am.addingTimeInterval(30))
        #expect(f.tracker.seconds(on: tue, now: wed2am.addingTimeInterval(30)) == 30)
        #expect(f.seconds(at: wed2am.addingTimeInterval(30)) == 0)
        #expect(f.tracker.currentWorkDay(now: wed2am) == calendar.startOfDay(for: tue))
        #expect(f.history.stored["2026-10-06"] == 30)
    }

    @Test("Changing the reset applies from then on and does not re-bucket what is stored")
    func changingResetKeepsHistory() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0) // Wed 10:00
        f.tracker.tick(now: t0.addingTimeInterval(30))
        f.tracker.setDayReset(12 * 60, now: t0.addingTimeInterval(30))
        // With a 12:00 reset, 10:00-12:00 now belongs to Tuesday's work day.
        f.tracker.tick(now: t0.addingTimeInterval(60))
        #expect(f.seconds(at: t0.addingTimeInterval(60)) == 30) // Wednesday keeps what it had
        #expect(f.tracker.seconds(on: at(12, day: 6), now: t0.addingTimeInterval(60)) == 30) // the new 30 s went to Tuesday
    }

    @Test("The 8 h notification guard uses the work-day key")
    func goalUsesWorkDayKey() {
        let f = Fixture(preloaded: ["2026-10-06": AwakeMath.dailyTarget - 10])
        let wed2am = at(2)
        f.tracker.start(lidClosed: false, cutOff: false, now: wed2am)
        f.tracker.tick(now: wed2am.addingTimeInterval(30))
        f.tracker.tick(now: wed2am.addingTimeInterval(60))
        #expect(f.notifications.count == 1)
    }
}

@MainActor
@Suite("Storage: restarts, saves, settings")
struct StorageBehaviourTests {
    @Test("After a restart the new tracker continues from the stored time")
    func restartContinues() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))
        f.tracker.tick(now: t0.addingTimeInterval(60))
        f.tracker.flush(now: t0.addingTimeInterval(65)) // quitting

        let relaunched = f.restart()
        relaunched.start(lidClosed: false, cutOff: false, now: t0.addingTimeInterval(3600))
        #expect(relaunched.seconds(on: t0, now: t0.addingTimeInterval(3600)) == 65) // what was stored, none of the downtime
        relaunched.tick(now: t0.addingTimeInterval(3630))
        #expect(relaunched.seconds(on: t0, now: t0.addingTimeInterval(3630)) == 95)
    }

    @Test("A crash loses at most the time since the last tick")
    func crashLosesAtMostOneTick() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.tick(now: t0.addingTimeInterval(30))
        f.tracker.tick(now: t0.addingTimeInterval(60))
        // 25 s later the app dies: no flush, no sleep, no quit.
        let relaunched = f.restart()
        #expect(relaunched.seconds(on: t0, now: t0.addingTimeInterval(85)) == 60)
    }

    @Test("Saves happen on every tick that adds time, on flush and on sleep")
    func savesOnTickFlushAndSleep() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        #expect(f.spy.saveCount == 0)

        f.tracker.tick(now: t0.addingTimeInterval(30))
        #expect(f.spy.saveCount == 1)

        f.tracker.flush(now: t0.addingTimeInterval(45)) // quit
        #expect(f.spy.saveCount == 2)
        #expect(f.history.stored["2026-10-07"] == 45)

        f.tracker.willSleep(now: t0.addingTimeInterval(50)) // sleep
        #expect(f.spy.saveCount == 3)
        #expect(f.history.stored["2026-10-07"] == 50)
    }

    @Test("Nothing new to store means no write")
    func noNeedlessWrites() {
        let f = Fixture()
        f.tracker.start(lidClosed: false, cutOff: false, now: t0)
        f.tracker.update(lidClosed: false, cutOff: true, now: t0) // cut off straight away
        f.tracker.tick(now: t0.addingTimeInterval(30))
        f.tracker.tick(now: t0.addingTimeInterval(60))
        f.tracker.flush(now: t0.addingTimeInterval(65))
        #expect(f.spy.saveCount == 0)
    }

    @Test("The day-reset setting round-trips through the settings store")
    func resetSettingRoundTrip() {
        let f = Fixture()
        #expect(f.tracker.dayResetMinute == 420) // default 7:00 AM
        f.tracker.setDayReset(540)
        #expect(f.settings.dayResetMinute == 540)
        #expect(f.restart().dayResetMinute == 540)
    }

    @Test("An invalid stored reset falls back to 7:00 AM, and invalid changes are ignored")
    func resetSettingValidation() {
        let settings = InMemorySettingsStore()
        settings.dayResetMinute = 425 // not a 10-minute step
        let f = Fixture(settings: settings)
        #expect(f.tracker.dayResetMinute == 420)
        f.tracker.setDayReset(555)
        #expect(f.tracker.dayResetMinute == 420)
        #expect(settings.dayResetMinute == 425) // untouched
    }
}
