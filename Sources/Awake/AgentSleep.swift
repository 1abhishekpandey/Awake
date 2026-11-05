import Foundation
import Observation

/// "Sleep when agent is done": lets a script or coding agent halt Awake when its
/// work is finished, so the Mac can sleep and the charger stays off overnight.
///
/// The menu switch arms it, one run at a time:
///   - Turning the switch on deletes any old signal, so a stale one never fires.
///   - While armed, every check reads the signal file. When it says `true`, the
///     file is deleted, the switch turns itself off and Awake halts.
///   - The halt lasts until the Mac next wakes from sleep, Awake restarts, or the
///     user clicks Resume. It is never saved, so a restart always starts fresh.
///
/// In Screen off and Night run the switch is always on: it is turned on when the
/// mode is picked, on every resume and at launch, and can't be turned off by hand.
@MainActor
@Observable
final class AgentSleep {
    /// Where agents write the signal: `~/.config/awake/sleep-at`, holding `true`.
    static let defaultSignalFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awake/sleep-at")

    /// The menu switch. Off by default, and off again after each halt.
    private(set) var isArmed: Bool
    /// When the agent's signal halted Awake. Nil while running normally.
    private(set) var haltedAt: Date?

    var isHalted: Bool { haltedAt != nil }

    /// The mode keeps the switch on. Set by `AppModel` from the keep-awake mode.
    private(set) var isRequired = false

    /// Fired with the halt time when a signal halts Awake, and with nil on resume.
    @ObservationIgnored var onHaltChange: (@MainActor (_ haltedAt: Date?) -> Void)?

    @ObservationIgnored private let settings: any SettingsStoring
    @ObservationIgnored private let readSignal: () -> String?
    @ObservationIgnored private let clearSignal: () -> Void

    convenience init(settings: any SettingsStoring, signalFile: URL = AgentSleep.defaultSignalFile) {
        self.init(
            settings: settings,
            readSignal: { try? String(contentsOf: signalFile, encoding: .utf8) },
            clearSignal: { try? FileManager.default.removeItem(at: signalFile) }
        )
    }

    /// Tests pass an in-memory signal instead of the file.
    init(settings: any SettingsStoring, readSignal: @escaping () -> String?, clearSignal: @escaping () -> Void) {
        self.settings = settings
        self.readSignal = readSignal
        self.clearSignal = clearSignal
        isArmed = settings.agentSleepArmed
    }

    /// The mode wants the switch on (or no longer does). Turning it on here only when
    /// it is off, so a signal already waiting at launch is not thrown away.
    func setRequired(_ required: Bool) {
        isRequired = required
        if required, !isArmed, !isHalted { setArmed(true) }
    }

    /// The menu switch. Arming always starts from a clean signal. While the mode
    /// requires the switch, it can't be turned off by hand.
    func setArmed(_ armed: Bool) {
        if !armed, isRequired, !isHalted { return }
        if armed { clearSignal() }
        guard armed != isArmed else { return }
        isArmed = armed
        settings.agentSleepArmed = armed
    }

    /// Reads the signal while armed. Cheap: one small file read, only when armed.
    func check(now: Date = .now) {
        guard isArmed, !isHalted, Self.isDone(readSignal()) else { return }
        clearSignal()
        haltedAt = now
        setArmed(false)
        onHaltChange?(now)
    }

    /// The Mac woke, Awake restarted, or the user clicked Resume.
    func resume() {
        guard isHalted else { return }
        haltedAt = nil
        // A signal written during the halt is stale; arming clears it.
        if isRequired { setArmed(true) }
        onHaltChange?(nil)
    }

    /// The signal counts only when the file holds `true`, ignoring case and spaces.
    static func isDone(_ contents: String?) -> Bool {
        contents?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }
}
