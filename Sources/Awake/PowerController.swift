import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation

/// Owns the power assertions and everything that decides whether to hold them:
/// the keep-awake toggle, the lid, the battery cutoff, an agent's halt and Low Power Mode.
///
/// The assertions are held only when ALL of these are true:
///   - the keep-awake toggle is on
///   - the lid is open
///   - the battery cutoff has not stopped the app
///   - no agent has halted the app
///   - Low Power Mode is off
///
/// Night run is the exception: the lid and Low Power Mode don't pause it. It also
/// turns on macOS's sleep-disabled setting, so a closed lid can't put the Mac to
/// sleep. An agent's signal, the battery cutoff or heat end it: the mode goes back
/// to off, and a Mac with its lid closed is put to sleep straight away.
@MainActor
@Observable
final class PowerController {
    enum PauseReason: Equatable {
        case lidClosed
        case lowPowerMode
    }

    enum Status: Equatable {
        /// Battery below the cutoff while on battery: the whole app is dormant.
        case stopped(threshold: Int)
        /// An agent signalled it was done: everything is off until the next wake or Resume.
        case halted(at: Date)
        /// Mode is off.
        case off
        /// Keep-awake is on but temporarily not holding the Mac awake.
        case paused(PauseReason)
        /// Holding the Mac awake; `screenOn` is true when the display is held on too.
        case keepingAwake(screenOn: Bool)
        /// Wanted to hold the assertion but macOS refused it.
        case failed
    }

    // MARK: Settings (persisted through `SettingsStoring`)

    /// The saved keep-awake mode (not necessarily being held right now).
    @ObservationIgnored let keep: KeepAwakeSettings

    var keepMode: KeepAwakeMode { keep.mode }

    func setMode(_ mode: KeepAwakeMode) {
        // Night run needs its one-time setup first; picking it starts the setup.
        if mode == .nightRun, !nightRun.isSetUp {
            nightRun.setUp { [weak self] success in
                if success { self?.setMode(.nightRun) }
            }
            return
        }
        guard keep.setMode(mode) else { return }
        recompute()
        onModeChange?(keepMode)
    }

    /// macOS's sleep-disabled setting and the one-time setup.
    @ObservationIgnored let nightRun: NightRun

    /// Stop everything when on battery below this charge, in percent.
    var batteryCutoffPercent: Int {
        didSet {
            guard batteryCutoffPercent != oldValue else { return }
            settings.batteryCutoffPercent = batteryCutoffPercent
            recompute()
            onCutoffChange?(batteryCutoffPercent)
        }
    }

    /// When an agent halted the app, or nil. Set by `AgentSleep`, never saved.
    private(set) var haltedByAgentAt: Date?

    func setHaltedByAgent(at date: Date?) {
        guard date != haltedByAgentAt else { return }
        haltedByAgentAt = date
        recompute()
    }

    var isHaltedByAgent: Bool { haltedByAgentAt != nil }

    // MARK: Observed system state

    private(set) var lidClosed = false
    private(set) var onAC = true
    private(set) var batteryPercent: Int?
    private(set) var lowPowerMode = false
    /// macOS reports the Mac is hot enough to end Night run.
    private(set) var tooHot = false
    /// True while the system-sleep assertion is actually held.
    private(set) var isHolding = false
    /// True while the display-sleep assertion is actually held.
    private(set) var isHoldingDisplay = false

    /// Fired when the lid changes, or the app is stopped or started again by the
    /// battery cutoff or an agent's halt: the conditions that stop awake-time counting.
    @ObservationIgnored var onConditionsChange: (@MainActor (_ lidClosed: Bool, _ stopped: Bool) -> Void)?

    /// Fired when the battery charge or the AC state changes (from the power-source
    /// notification or a fallback re-read).
    @ObservationIgnored var onBatteryChange: (@MainActor () -> Void)?

    /// Fired when "Stop everything below" changes.
    @ObservationIgnored var onCutoffChange: (@MainActor (_ percent: Int) -> Void)?

    /// Fired when the mode changes, by the picker or because Night run ended.
    @ObservationIgnored var onModeChange: (@MainActor (_ mode: KeepAwakeMode) -> Void)?

    /// Fired when Night run ends by itself, with the reason.
    @ObservationIgnored var onNightRunEnd: (@MainActor (_ reason: AwakeMath.NightRunEnd) -> Void)?

    // MARK: Private state

    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private var systemAssertion: IOPMAssertionID?
    @ObservationIgnored private var displayAssertion: IOPMAssertionID?
    @ObservationIgnored private var lastReported: Conditions?

    /// The conditions that stop awake-time counting.
    private struct Conditions: Equatable {
        var lidClosed: Bool
        var stopped: Bool
    }

    // MARK: Derived

    /// True when on battery with a charge strictly below the cutoff.
    var isCutOff: Bool {
        AwakeMath.isBatteryCutOff(onAC: onAC, charge: batteryPercent, threshold: batteryCutoffPercent)
    }

    private var pauseReason: PauseReason? {
        if keepMode == .nightRun { return nil }
        if lidClosed { return .lidClosed }
        if lowPowerMode { return .lowPowerMode }
        return nil
    }

    /// The keep-awake picker keeps the saved mode but cannot be changed
    /// while the app is stopped or paused.
    var pickerLocked: Bool { isCutOff || isHaltedByAgent || pauseReason != nil }

    var status: Status {
        if isCutOff { return .stopped(threshold: batteryCutoffPercent) }
        if let haltedByAgentAt { return .halted(at: haltedByAgentAt) }
        // A pause is reported before "off" so the header always explains why the
        // picker is disabled, even when the mode is off.
        if let reason = pauseReason { return .paused(reason) }
        if keepMode == .off { return .off }
        return isHolding ? .keepingAwake(screenOn: isHoldingDisplay) : .failed
    }

    var statusText: String {
        switch status {
        case .stopped(let threshold): "Stopped — battery below \(threshold)% (on battery)"
        case .halted(let date): "Halted by agent at \(date.formatted(date: .omitted, time: .shortened))"
        case .off: "Off — Mac sleeps normally"
        case .paused(.lidClosed): "Paused — lid closed"
        case .paused(.lowPowerMode): "Paused — Low Power Mode"
        case .keepingAwake where keepMode == .nightRun: "Night run · stays awake with the lid closed"
        case .keepingAwake(screenOn: true): "Mac awake · screen on"
        case .keepingAwake(screenOn: false): "Mac awake · screen can sleep"
        case .failed: "Couldn't hold the Mac awake"
        }
    }

    /// SF Symbol for the menu bar (rendered as a template image).
    var iconName: String {
        switch status {
        case .stopped: "battery.25"
        case .halted: "zzz"
        case .keepingAwake where keepMode == .nightRun: "moon.stars.fill"
        case .keepingAwake(screenOn: true): "sun.max.fill"
        case .keepingAwake(screenOn: false): "cup.and.saucer.fill"
        case .paused: "moon.zzz"
        case .off, .failed: "cup.and.saucer"
        }
    }

    // MARK: Lifecycle

    init(settings: any SettingsStoring, sleepSwitch: any SleepSwitching = SystemSleepSwitch()) {
        self.settings = settings
        keep = KeepAwakeSettings(settings: settings)
        // Night run never survives a restart of Awake: it always comes back as off.
        if keep.mode == .nightRun { keep.setMode(.off) }
        nightRun = NightRun(system: sleepSwitch)
        let stored = settings.batteryCutoffPercent
        batteryCutoffPercent = AwakeMath.cutoffChoices.contains(stored) ? stored : AwakeMath.defaultCutoff

        readSystemState()
        startLidNotifications()
        startBatteryNotifications()
        startLowPowerNotifications()
        startThermalNotifications()
        recompute()
    }

    /// Re-reads lid, battery and Low Power Mode. Called on every tick as a
    /// fallback for the change notifications, and when the popover opens.
    func refresh() {
        readSystemState()
        recompute()
    }

    /// Drops every assertion and lets the Mac sleep again. Used when the app quits.
    func releaseAll() {
        releaseAssertions()
        nightRun.apply(blockSleep: false)
    }

    /// Re-checks the Night run setup, for the menu.
    func refreshNightRunSetup() {
        nightRun.refreshSetup()
    }

    // MARK: Reading state

    private func readSystemState() {
        lidClosed = SystemPower.isLidClosed()
        let battery = SystemPower.readBattery()
        let batteryChanged = battery.onAC != onAC || battery.percent != batteryPercent
        onAC = battery.onAC
        batteryPercent = battery.percent
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        tooHot = AwakeMath.isTooHot(ProcessInfo.processInfo.thermalState)
        if batteryChanged { onBatteryChange?() }
    }

    fileprivate func lidMayHaveChanged() {
        let closed = SystemPower.isLidClosed()
        guard closed != lidClosed else { return }
        lidClosed = closed
        recompute()
    }

    fileprivate func batteryMayHaveChanged() {
        let battery = SystemPower.readBattery()
        guard battery.onAC != onAC || battery.percent != batteryPercent else { return }
        onAC = battery.onAC
        batteryPercent = battery.percent
        recompute()
        onBatteryChange?()
    }

    fileprivate func lowPowerModeMayHaveChanged() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != lowPowerMode else { return }
        lowPowerMode = enabled
        recompute()
    }

    fileprivate func thermalStateMayHaveChanged() {
        let hot = AwakeMath.isTooHot(ProcessInfo.processInfo.thermalState)
        guard hot != tooHot else { return }
        tooHot = hot
        recompute()
    }

    // MARK: Deciding

    /// The single place that turns state into assertions. Idempotent, so it is
    /// safe to call after any change.
    private func recompute() {
        // Night run ends on an agent's signal, the battery cutoff or heat, and goes back to off.
        var ended: AwakeMath.NightRunEnd?
        if keepMode == .nightRun {
            ended = AwakeMath.nightRunEnd(cutOff: isCutOff, haltedByAgent: isHaltedByAgent, tooHot: tooHot)
            if ended != nil { keep.setMode(.off) }
        }

        let stopped = isCutOff || isHaltedByAgent
        let nightRunning = keepMode == .nightRun && !stopped
        let shouldHold = !stopped && (nightRunning || (!lidClosed && !lowPowerMode))

        // The sleep-disabled setting first, so the Mac can sleep again before anything else.
        if !nightRun.apply(blockSleep: nightRunning), nightRunning {
            // It could not be turned on: fall back to off instead of looking like it runs.
            keep.setMode(.off)
            onModeChange?(keepMode)
            recompute()
            return
        }

        let wanted = shouldHold ? keepMode.heldAssertions : KeepAwakeMode.Assertions(systemSleep: false, displaySleep: false)

        // Take or drop each assertion to match what the mode wants right now.
        if wanted.systemSleep {
            if systemAssertion == nil {
                systemAssertion = SystemPower.createAssertion(
                    type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    reason: "Awake: keeping Mac awake for long-running work"
                )
            }
        } else if let id = systemAssertion {
            SystemPower.releaseAssertion(id)
            systemAssertion = nil
        }

        if wanted.displaySleep {
            if displayAssertion == nil {
                displayAssertion = SystemPower.createAssertion(
                    type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    reason: "Awake: keeping display on"
                )
            }
        } else if let id = displayAssertion {
            SystemPower.releaseAssertion(id)
            displayAssertion = nil
        }

        let holding = systemAssertion != nil
        if isHolding != holding { isHolding = holding }
        let holdingDisplay = displayAssertion != nil
        if isHoldingDisplay != holdingDisplay { isHoldingDisplay = holdingDisplay }

        // Tell the awake-time tracker only when something it cares about changed.
        let conditions = Conditions(lidClosed: lidClosed, stopped: stopped)
        if conditions != lastReported {
            lastReported = conditions
            onConditionsChange?(lidClosed, stopped)
        }

        if let ended {
            onModeChange?(keepMode)
            onNightRunEnd?(ended)
            if lidClosed { sleepSoon() }
        }
    }

    /// With the lid closed, a Mac whose sleep was disabled may not notice it can sleep
    /// again until the lid moves, so it is told to. The short wait lets the smart plug
    /// switch off first after an agent's halt.
    private func sleepSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            runOnMain {
                guard let self, self.lidClosed, self.keepMode != .nightRun else { return }
                self.nightRun.sleepNow()
            }
        }
    }

    private func releaseAssertions() {
        if let id = systemAssertion {
            SystemPower.releaseAssertion(id)
            systemAssertion = nil
        }
        if let id = displayAssertion {
            SystemPower.releaseAssertion(id)
            displayAssertion = nil
        }
        if isHolding { isHolding = false }
        if isHoldingDisplay { isHoldingDisplay = false }
    }

    // MARK: Change notifications

    /// Lid: a general-interest notification on IOPMrootDomain. It carries many
    /// kinds of power messages, so on any of them the property is simply re-read.
    private func startLidNotifications() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(service) }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        var notifier: io_object_t = 0
        // The controller lives for the whole process, so an unretained pointer is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, lidInterestCallback, context, &notifier)
        // `port` and `notifier` are intentionally kept alive for the life of the app.
    }

    /// Battery and AC: a run loop source that fires when any power source changes.
    private func startBatteryNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func startThermalNotifications() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            runOnMain { self?.thermalStateMayHaveChanged() }
        }
    }

    private func startLowPowerNotifications() {
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            runOnMain { self?.lowPowerModeMayHaveChanged() }
        }
    }
}

// MARK: - C callbacks

// These run on the main run loop but are not actor-isolated, so they hop
// explicitly. The context pointer is the (immortal) PowerController.

private func lidInterestCallback(
    _ context: UnsafeMutableRawPointer?, _ service: io_service_t, _ messageType: UInt32, _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let controller = Unmanaged<PowerController>.fromOpaque(context).takeUnretainedValue()
    runOnMain { controller.lidMayHaveChanged() }
}

private func powerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let controller = Unmanaged<PowerController>.fromOpaque(context).takeUnretainedValue()
    runOnMain { controller.batteryMayHaveChanged() }
}
