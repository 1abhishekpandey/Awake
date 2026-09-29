import AppKit
import Foundation

/// Wires the pieces together: the 30-second timer, sleep/wake, quit handling
/// and the first-launch setup. One instance lives for the whole process.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let power: PowerController
    let tracker: AwakeTracker
    let loginItem: LoginItem
    let autoCharger: AutoCharger

    private var timer: Timer?
    private var sigtermSource: DispatchSourceSignal?
    private var activity: NSObjectProtocol?

    private init() {
        // The real storage, created once and handed to everything that persists anything.
        let settings = UserDefaultsSettingsStore()
        power = PowerController(settings: settings)
        tracker = AwakeTracker(store: FileHistoryStore(), settings: settings)
        loginItem = LoginItem(settings: settings)
        autoCharger = AutoCharger(settings: settings, cutoffPercent: power.batteryCutoffPercent)

        // Lid and battery-cutoff changes start or stop counting immediately.
        power.onConditionsChange = { [tracker] lidClosed, cutOff in
            tracker.update(lidClosed: lidClosed, cutOff: cutOff)
        }
        tracker.start(lidClosed: power.lidClosed, cutOff: power.isCutOff)

        // Battery changes arrive as notifications from macOS; the plug is switched from there.
        power.onBatteryChange = { [weak self] in self?.evaluateAutoCharge() }
        power.onCutoffChange = { [autoCharger] percent in autoCharger.cutoffChanged(to: percent) }
        evaluateAutoCharge()

        startTimer()
        observeSleepAndQuit()
        handleSigterm()
        keepTimerAccurate()

        Notifier.requestAuthorizationIfNeeded()
        loginItem.enableOnFirstLaunch()
    }

    /// Called when the popover opens so it never shows stale state.
    func refreshForDisplay() {
        power.refresh()
        loginItem.refresh()
        autoCharger.refreshSetupState()
    }

    private func evaluateAutoCharge() {
        autoCharger.evaluate(onAC: power.onAC, charge: power.batteryPercent)
    }

    // MARK: Timer

    /// Every 30 s, with generous tolerance so the system can coalesce the wake-up.
    /// Each tick re-reads lid/battery/Low Power Mode (the fallback for the change
    /// notifications) and then adds the elapsed time.
    private func startTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            runOnMain { self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        power.refresh()
        tracker.tick()
        // Retries only: a failed command, or a charger that was switched on but isn't charging.
        evaluateAutoCharge()
    }

    // MARK: Sleep, wake, quit

    private func observeSleepAndQuit() {
        let workspace = NSWorkspace.shared.notificationCenter
        // No queue: handlers run synchronously on the posting (main) thread, so
        // the time is banked before the Mac actually goes to sleep or the app exits.
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            runOnMain { self?.tracker.willSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            runOnMain {
                // Re-read the lid first: a wake with the lid closed must not count.
                self?.power.refresh()
                self?.tracker.didWake()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            runOnMain {
                self?.tracker.flush()
                self?.power.releaseAll()
            }
        }
    }

    /// `pkill` (used by build.sh --install) sends SIGTERM, which would otherwise
    /// skip the normal quit path and lose up to 30 s of unsaved time.
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            runOnMain { NSApplication.shared.terminate(nil) }
        }
        source.resume()
        sigtermSource = source
    }

    /// An agent app with no visible window is a candidate for App Nap, which can
    /// stretch a 30 s timer to minutes; a gap over 90 s is discarded as "asleep",
    /// so time would be under-counted. This opts out of App Nap only. It does
    /// NOT hold any sleep assertion (`...AllowingIdleSystemSleep`).
    private func keepTimerAccurate() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Accurate awake-time tracking"
        )
    }
}
