import Foundation
import Observation

/// Switches the smart plug the Mac's charger is on: on when the battery falls to
/// "Start charging at", off when charging reaches "Stop charging at".
///
/// It never polls. `evaluate` runs when macOS reports a battery change and on the
/// app's existing 30-second tick (which only retries; no network unless needed).
@MainActor
@Observable
final class AutoCharger {
    /// Talks to the plug. Injected so tests don't touch the network or Keychain.
    typealias PlugClient = @Sendable (_ command: PlugCommand) async throws -> Bool

    enum PlugCommand: Sendable, Equatable {
        case set(on: Bool)
        case query
    }

    enum PlugNotSetUp: LocalizedError {
        case missing
        var errorDescription: String? { "The plug isn't set up." }
    }

    /// Wait this long before retrying a failed command, or before deciding a
    /// switched-on charger isn't charging.
    static let retryInterval: TimeInterval = 60

    // MARK: Settings

    var startPercent: Int {
        didSet { levelsChanged(oldStart: oldValue, oldStop: stopPercent) }
    }

    var stopPercent: Int {
        didSet { levelsChanged(oldStart: startPercent, oldStop: oldValue) }
    }

    private(set) var cutoffPercent: Int

    var startChoices: [Int] { AwakeMath.chargeStartChoices(cutoff: cutoffPercent, stop: stopPercent) }
    var stopChoices: [Int] { AwakeMath.chargeStopChoices(start: startPercent) }

    // MARK: Status shown in the menu

    /// False when the Keychain has no plug credentials.
    private(set) var isSetUp: Bool
    /// One line about the last thing that happened, e.g. "Charger on at 30% · 2:14 PM".
    private(set) var lastEvent: String?
    private(set) var lastEventFailed = false
    /// Whether the plug is on, as last read or switched. Nil until known.
    private(set) var plugIsOn: Bool?
    /// True while a command to the plug is running (the button shows it's busy).
    private(set) var isBusy = false

    // MARK: Private state

    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let client: PlugClient
    @ObservationIgnored private let hasCredentials: () -> Bool
    @ObservationIgnored private let notify: (_ title: String, _ body: String) -> Void

    /// The action already done for the current zone. Cleared when the battery
    /// leaves the zone, so each crossing switches the plug once.
    @ObservationIgnored private var handledAction: AwakeMath.PlugAction?
    @ObservationIgnored private var handledAt: Date?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var lastFailureAt: Date?
    /// One failure notification and one "not charging" notification per zone.
    @ObservationIgnored private var notifiedFailure = false
    @ObservationIgnored private var notifiedNotCharging = false
    @ObservationIgnored private var last: (onAC: Bool, charge: Int?)?
    /// The action a manual switch is holding back (see `markManual`).
    @ObservationIgnored private var manualOverride: AwakeMath.PlugAction?

    init(
        settings: any SettingsStoring,
        cutoffPercent: Int,
        client: @escaping PlugClient = AutoCharger.keychainPlugClient,
        hasCredentials: @escaping () -> Bool = { PlugCredentials.load() != nil },
        notify: @escaping (_ title: String, _ body: String) -> Void = Notifier.post
    ) {
        self.settings = settings
        self.client = client
        self.hasCredentials = hasCredentials
        self.notify = notify
        self.cutoffPercent = cutoffPercent
        let levels = AwakeMath.clampedChargeLevels(
            cutoff: cutoffPercent, start: settings.chargeStartPercent, stop: settings.chargeStopPercent
        )
        startPercent = levels.start
        stopPercent = levels.stop
        isSetUp = hasCredentials()
        settings.chargeStartPercent = levels.start
        settings.chargeStopPercent = levels.stop
    }

    /// The low-battery cutoff changed: keep "Start charging at" above it.
    func cutoffChanged(to cutoff: Int) {
        cutoffPercent = cutoff
        applyClamp()
    }

    /// Re-checks the Keychain. Called when the popover opens.
    func refreshSetupState() {
        let setUp = hasCredentials()
        if isSetUp != setUp { isSetUp = setUp }
    }

    // MARK: Deciding

    /// Called with every battery reading. Cheap when there is nothing to do.
    func evaluate(onAC: Bool, charge: Int?, now: Date = .now) {
        last = (onAC, charge)
        // Always on once the plug is set up; there is no separate switch.
        guard isSetUp else { return }

        guard let action = AwakeMath.plugAction(onAC: onAC, charge: charge, start: startPercent, stop: stopPercent) else {
            // Between the levels (or charging started): the zone is done.
            handledAction = nil
            handledAt = nil
            notifiedFailure = false
            notifiedNotCharging = false
            return
        }
        guard !inFlight else { return }

        if let manualOverride {
            if action == manualOverride { return }
            self.manualOverride = nil // the other level was reached: automatic again
        }

        if action == handledAction {
            // Already switched. Only a switched-on charger that still isn't
            // charging after a minute is worth one more try.
            guard action == .turnOn, let handledAt, now.timeIntervalSince(handledAt) >= Self.retryInterval,
                  !notifiedNotCharging
            else { return }
            notifiedNotCharging = true
            notify("Mac isn't charging", "The smart plug was switched on, but the Mac is still on battery. Check the charger cable.")
            send(action, charge: charge, now: now)
            return
        }

        if let lastFailureAt, now.timeIntervalSince(lastFailureAt) < Self.retryInterval { return }
        send(action, charge: charge, now: now)
    }

    /// Reads whether the plug is on. Called when the menu opens; the first call
    /// also triggers macOS's Local Network prompt.
    func refreshPlugState() {
        guard isSetUp, !inFlight else { return }
        run { client in
            let on = try await client(.query)
            self.plugIsOn = on
        } onError: { error in
            self.record("\(error.localizedDescription) · \(Self.time(.now))", failed: true)
        }
    }

    /// The menu's charger button: flips the plug. Auto-charge then leaves this
    /// choice alone until the battery reaches the next level.
    func togglePlug(now: Date = .now) {
        guard !inFlight else { return }
        let known = plugIsOn
        run { client in
            let current: Bool
            if let known { current = known } else { current = try await client(.query) }
            let on = try await client(.set(on: !current))
            self.plugIsOn = on
            self.markManual(on: on)
            self.record("Charger turned \(on ? "on" : "off") by hand · \(Self.time(now))", failed: false)
        } onError: { error in
            self.plugIsOn = nil
            self.record("\(error.localizedDescription) · \(Self.time(now))", failed: true)
        }
    }

    /// A manual switch holds until the battery reaches the other level: turning
    /// the charger on by hand blocks "switch off" until the next "switch on"
    /// moment, and the other way round.
    private func markManual(on: Bool) {
        manualOverride = on ? .turnOff : .turnOn
    }

    /// Runs one plug task at a time, keeping `inFlight` and `isBusy` in step.
    private func run(
        _ body: @escaping @MainActor (PlugClient) async throws -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        inFlight = true
        isBusy = true
        let client = client
        Task {
            do { try await body(client) } catch { onError(error) }
            inFlight = false
            isBusy = false
        }
    }

    private func send(_ action: AwakeMath.PlugAction, charge: Int?, now: Date) {
        let on = action == .turnOn
        run { client in
            _ = try await client(.set(on: on))
            self.plugIsOn = on
            self.handledAction = action
            self.handledAt = now
            self.lastFailureAt = nil
            let level = charge.map { " at \($0)%" } ?? ""
            self.record("Charger \(on ? "on" : "off")\(level) · \(Self.time(now))", failed: false)
        } onError: { error in
            self.lastFailureAt = now
            self.record("\(error.localizedDescription) · \(Self.time(now))", failed: true)
            if !self.notifiedFailure {
                self.notifiedFailure = true
                self.notify(
                    "Couldn't switch the charger \(on ? "on" : "off")",
                    "\(error.localizedDescription) Awake will keep trying every minute."
                )
            }
        }
    }

    private func record(_ event: String, failed: Bool) {
        lastEvent = event
        lastEventFailed = failed
    }

    private func evaluateLast() {
        if let last { evaluate(onAC: last.onAC, charge: last.charge) }
    }

    // MARK: Levels

    private var isClamping = false

    private func levelsChanged(oldStart: Int, oldStop: Int) {
        guard !isClamping else { return }
        applyClamp()
        guard startPercent != oldStart || stopPercent != oldStop else { return }
        handledAction = nil
        evaluateLast()
    }

    private func applyClamp() {
        let levels = AwakeMath.clampedChargeLevels(cutoff: cutoffPercent, start: startPercent, stop: stopPercent)
        isClamping = true
        if startPercent != levels.start { startPercent = levels.start }
        if stopPercent != levels.stop { stopPercent = levels.stop }
        isClamping = false
        settings.chargeStartPercent = levels.start
        settings.chargeStopPercent = levels.stop
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Real plug

    /// Reads the Keychain on every command, so new credentials apply without a restart.
    static let keychainPlugClient: PlugClient = { command in
        guard let credentials = PlugCredentials.load() else { throw PlugNotSetUp.missing }
        let plug = SmartPlug(credentials: credentials)
        switch command {
        case .set(let on):
            try await plug.set(on: on)
            return on
        case .query:
            return try await plug.isOn()
        }
    }
}
