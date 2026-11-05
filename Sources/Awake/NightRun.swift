import Foundation
import Observation

/// The system side of Night run: macOS's sleep-disabled setting, which keeps the Mac
/// running even with the lid closed. Behind a protocol so tests use a fake.
protocol SleepSwitching: AnyObject {
    /// The one-time setup is installed: the narrow sudo rule and the safety job.
    func isSetUp() -> Bool
    /// Turns the setting on or off. False when the command failed.
    func setSleepDisabled(_ disabled: Bool) -> Bool
    /// Whether the setting is on right now, whoever turned it on.
    func isSleepDisabled() -> Bool
    /// Puts the Mac to sleep now.
    func sleepNow()
    /// Installs the setup behind macOS's own admin password prompt. Calls back
    /// (on any thread) with true when it succeeded.
    func runSetup(completion: @escaping @Sendable (Bool) -> Void)
}

/// Keeps macOS's sleep-disabled setting in step with what Night run wants, and runs
/// the one-time setup. `PowerController` decides; this only applies.
@MainActor
@Observable
final class NightRun {
    private(set) var isSetUp: Bool
    private(set) var isSettingUp = false
    /// Shown under the picker when setup or switching failed.
    private(set) var errorMessage: String?

    @ObservationIgnored private let system: any SleepSwitching
    /// What was last applied successfully. Nil when unknown, so the next apply always runs.
    @ObservationIgnored private var applied: Bool?

    /// A fresh launch always starts with the setting off: Night run never survives a
    /// restart of Awake, and a crash may have left it on.
    init(system: any SleepSwitching) {
        self.system = system
        isSetUp = system.isSetUp()
        if system.isSleepDisabled() {
            applied = system.setSleepDisabled(false) ? false : nil
        } else {
            applied = false
        }
    }

    func refreshSetup() {
        isSetUp = system.isSetUp()
    }

    /// Turns the setting on or off if it is not already. False when it could not be
    /// changed; a failed "off" is retried on the next call.
    @discardableResult
    func apply(blockSleep: Bool) -> Bool {
        guard blockSleep != applied else { return true }
        if system.setSleepDisabled(blockSleep) {
            applied = blockSleep
            errorMessage = nil
            return true
        }
        // A failed "off" when the setting is already off (no setup, say) is not a failure.
        if !blockSleep, !system.isSleepDisabled() {
            applied = false
            return true
        }
        applied = nil
        isSetUp = system.isSetUp()
        errorMessage = blockSleep
            ? "Couldn't start Night run. Pick it again to redo the setup."
            : "Couldn't turn Night run off. Retrying."
        return false
    }

    /// Asks for the admin password once and installs the setup. Calls back with the result.
    func setUp(then: @escaping @MainActor (Bool) -> Void) {
        guard !isSettingUp else { return }
        isSettingUp = true
        errorMessage = nil
        system.runSetup { [weak self] ok in
            runOnMain {
                guard let self else { return }
                self.isSettingUp = false
                self.isSetUp = self.system.isSetUp()
                let success = ok && self.isSetUp
                if !success { self.errorMessage = "Night run wasn't set up. Pick it again to retry." }
                then(success)
            }
        }
    }

    func sleepNow() {
        system.sleepNow()
    }
}

/// The real setting, changed through `pmset` under a sudo rule that allows only
/// `pmset -a disablesleep 0` and `pmset -a disablesleep 1`, with no password.
///
/// The setup also installs a root safety job that runs every minute and at startup:
/// if Awake isn't running and the setting is on, it turns it off. So a crash, a
/// force-quit or a restart can never leave the Mac unable to sleep.
final class SystemSleepSwitch: SleepSwitching, @unchecked Sendable {
    static let sudoersFile = "/etc/sudoers.d/awake-night-run"
    static let guardLabel = "com.abhishek.awake.nightrun-guard"
    static var guardPlist: String { "/Library/LaunchDaemons/\(guardLabel).plist" }

    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"

    func isSetUp() -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: Self.sudoersFile) && files.fileExists(atPath: Self.guardPlist)
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        // -n: never prompt. Without the rule this fails instead of hanging.
        Self.run(Self.sudo, ["-n", Self.pmset, "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
    }

    /// Reads `SleepDisabled` from the power-management root, like the lid state.
    func isSleepDisabled() -> Bool {
        let output = Self.run("/usr/sbin/ioreg", ["-r", "-n", "IOPMrootDomain", "-d1"]).output
        return output.contains("\"SleepDisabled\" = Yes")
    }

    func sleepNow() {
        _ = Self.run(Self.pmset, ["sleepnow"])
    }

    func runSetup(completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(Self.installSetup())
        }
    }

    // MARK: Setup

    private static func installSetup() -> Bool {
        let user = NSUserName()
        // A user name with anything unusual is refused rather than quoted into sudoers.
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else {
            return false
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("awake-night-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try sudoersRule(user: user).write(to: work.appendingPathComponent("sudoers"), atomically: true, encoding: .utf8)
            try guardJob().write(to: work.appendingPathComponent("guard.plist"), atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        // Runs as root after the password prompt. The rule is checked with visudo once
        // it is in place and removed again if it is not valid, so a bad file never stays.
        let dir = work.path
        let script = [
            "set -e",
            "/usr/bin/install -m 0440 -o root -g wheel '\(dir)/sudoers' '\(sudoersFile)'",
            "if ! /usr/sbin/visudo -cf '\(sudoersFile)' >/dev/null; then /bin/rm -f '\(sudoersFile)'; exit 1; fi",
            "/usr/bin/install -m 0644 -o root -g wheel '\(dir)/guard.plist' '\(guardPlist)'",
            "/bin/launchctl bootout system/\(guardLabel) 2>/dev/null || true",
            "/bin/launchctl bootstrap system '\(guardPlist)'",
        ].joined(separator: "; ")

        let appleScript = """
            do shell script "\(escapeForAppleScript(script))" with prompt "Awake needs your password once to set up Night run." with administrator privileges
            """
        return run("/usr/bin/osascript", ["-e", appleScript]).status == 0
    }

    static func sudoersRule(user: String) -> String {
        """
        # Installed by Awake for Night run. Allows only these two commands, without a password.
        \(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1

        """
    }

    /// The root safety job. Every minute and at startup: if Awake isn't running and
    /// sleep is disabled, turn the setting off so the Mac can sleep again.
    static func guardJob() -> String {
        let check = "/usr/bin/pgrep -qx Awake || { /usr/sbin/ioreg -r -n IOPMrootDomain -d1 | /usr/bin/grep -q '\"SleepDisabled\" = Yes' &amp;&amp; \(pmset) -a disablesleep 0; }; exit 0"
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(guardLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/bin/sh</string>
                    <string>-c</string>
                    <string>\(check)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>StartInterval</key>
                <integer>60</integer>
            </dict>
            </plist>

            """
    }

    private static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Running commands

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
