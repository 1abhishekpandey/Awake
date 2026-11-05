import Foundation
import Testing

@testable import Awake

/// macOS's sleep-disabled setting, held in memory.
final class FakeSleepSwitch: SleepSwitching, @unchecked Sendable {
    var setUp = true
    var disabled = false
    var commandsFail = false
    var setupSucceeds = true
    private(set) var commands: [Bool] = []
    private(set) var sleeps = 0

    func isSetUp() -> Bool { setUp }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        commands.append(disabled)
        guard setUp, !commandsFail else { return false }
        self.disabled = disabled
        return true
    }

    func isSleepDisabled() -> Bool { disabled }
    func sleepNow() { sleeps += 1 }
    private(set) var screenOffs = 0
    func turnScreenOff() { screenOffs += 1 }

    func runSetup(completion: @escaping @Sendable (Bool) -> Void) {
        if setupSucceeds { setUp = true }
        completion(setupSucceeds)
    }
}

@Suite("Night run rules")
struct NightRunRuleTests {
    @Test("Only an agent's signal, the battery cutoff or heat end it")
    func endReasons() {
        #expect(AwakeMath.nightRunEnd(cutOff: false, haltedByAgent: false, tooHot: false) == nil)
        #expect(AwakeMath.nightRunEnd(cutOff: false, haltedByAgent: true, tooHot: false) == .agentSignal)
        #expect(AwakeMath.nightRunEnd(cutOff: true, haltedByAgent: false, tooHot: false) == .lowBattery)
        #expect(AwakeMath.nightRunEnd(cutOff: false, haltedByAgent: false, tooHot: true) == .tooHot)
    }

    @Test("Too hot from serious upward")
    func heat() {
        #expect(!AwakeMath.isTooHot(.nominal))
        #expect(!AwakeMath.isTooHot(.fair))
        #expect(AwakeMath.isTooHot(.serious))
        #expect(AwakeMath.isTooHot(.critical))
    }

    @Test("The sudo rule allows only the two pmset commands")
    func sudoRule() {
        let rule = SystemSleepSwitch.sudoersRule(user: "someone")
        #expect(rule.contains("someone ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"))
        #expect(!rule.contains("*"))
    }

    @Test("The safety job is a valid plist that runs at startup and every minute")
    func guardJob() throws {
        let data = Data(SystemSleepSwitch.guardJob().utf8)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == SystemSleepSwitch.guardLabel)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["StartInterval"] as? Int == 60)
        let args = try #require(plist["ProgramArguments"] as? [String])
        #expect(args.last?.contains("pgrep -qx Awake ||") == true)
        #expect(args.last?.contains("&& /usr/bin/pmset -a disablesleep 0") == true)
    }
}

@MainActor
@Suite("Night run switch")
struct NightRunTests {
    @Test("Launch turns a leftover setting off")
    func launchResets() {
        let system = FakeSleepSwitch()
        system.disabled = true
        _ = NightRun(system: system)
        #expect(!system.disabled)
    }

    @Test("Apply only sends a command when the state changes")
    func applyIsIdempotent() {
        let system = FakeSleepSwitch()
        let night = NightRun(system: system)
        #expect(night.apply(blockSleep: true))
        #expect(night.apply(blockSleep: true))
        #expect(night.apply(blockSleep: false))
        #expect(system.commands == [true, false])
    }

    @Test("A failed start reports an error; a failed off is retried")
    func failures() {
        let system = FakeSleepSwitch()
        let night = NightRun(system: system)
        system.commandsFail = true
        #expect(!night.apply(blockSleep: true))
        #expect(night.errorMessage != nil)

        system.commandsFail = false
        #expect(night.apply(blockSleep: true))
        #expect(night.errorMessage == nil)
        system.commandsFail = true
        #expect(!night.apply(blockSleep: false))
        system.commandsFail = false
        #expect(night.apply(blockSleep: false))
        #expect(!system.disabled)
    }

    @Test("Turning off without a setup is not an error when it is already off")
    func offWithoutSetup() {
        let system = FakeSleepSwitch()
        system.setUp = false
        let night = NightRun(system: system)
        #expect(night.apply(blockSleep: false))
        #expect(night.errorMessage == nil)
    }
}

@MainActor
@Suite("Night run in the power controller")
struct NightRunPowerTests {
    @Test("A saved Night run comes back as off after a restart")
    func notRestored() {
        let settings = InMemorySettingsStore()
        settings.keepAwakeMode = "nightRun"
        let power = PowerController(settings: settings, sleepSwitch: FakeSleepSwitch())
        #expect(power.keepMode == .off)
        power.releaseAll()
    }

    @Test("Picking Night run disables sleep; picking another mode turns it back on")
    func pickAndLeave() {
        let system = FakeSleepSwitch()
        let power = PowerController(settings: InMemorySettingsStore(), sleepSwitch: system)
        power.setMode(.nightRun)
        // A low battery or heat on the test Mac would end it at once; then it is off.
        if power.keepMode == .nightRun {
            #expect(system.disabled)
        }
        power.setMode(.screenCanSleep)
        #expect(!system.disabled)
        power.releaseAll()
    }

    @Test("Without the setup, picking Night run runs it first")
    func setupFirst() async throws {
        let system = FakeSleepSwitch()
        system.setUp = false
        let power = PowerController(settings: InMemorySettingsStore(), sleepSwitch: system)
        power.setMode(.nightRun)
        // The setup reports back on the main actor.
        try await Task.sleep(for: .milliseconds(100))
        #expect(system.setUp)
        #expect(power.keepMode == .nightRun || power.isCutOff || power.tooHot)
        power.releaseAll()
    }

    @Test("A failed setup leaves the mode as it was")
    func failedSetup() async throws {
        let system = FakeSleepSwitch()
        system.setUp = false
        system.setupSucceeds = false
        let power = PowerController(settings: InMemorySettingsStore(), sleepSwitch: system)
        power.setMode(.nightRun)
        try await Task.sleep(for: .milliseconds(100))
        #expect(power.keepMode == .screenCanSleep)
        #expect(power.nightRun.errorMessage != nil)
        power.releaseAll()
    }

    @Test("An agent's halt ends Night run and goes back to off")
    func haltEnds() {
        let system = FakeSleepSwitch()
        let power = PowerController(settings: InMemorySettingsStore(), sleepSwitch: system)
        var ends: [AwakeMath.NightRunEnd] = []
        power.onNightRunEnd = { ends.append($0) }
        power.setMode(.nightRun)
        guard power.keepMode == .nightRun else { return } // ended by this Mac's battery or heat
        power.setHaltedByAgent(at: Date())
        #expect(power.keepMode == .off)
        #expect(!system.disabled)
        #expect(ends == [.agentSignal])
        power.releaseAll()
    }
}
