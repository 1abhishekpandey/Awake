import Foundation
import Testing

@testable import Awake

/// The signal file, held in memory.
private final class FakeSignal {
    var contents: String?
    private(set) var clears = 0

    func clear() {
        contents = nil
        clears += 1
    }
}

@MainActor
@Suite("Sleep when agent is done")
struct AgentSleepTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(
        _ signal: FakeSignal, settings: InMemorySettingsStore = InMemorySettingsStore()
    ) -> (AgentSleep, halts: () -> [Date?]) {
        let sleep = AgentSleep(settings: settings, readSignal: { signal.contents }, clearSignal: { signal.clear() })
        var halts: [Date?] = []
        sleep.onHaltChange = { halts.append($0) }
        return (sleep, { halts })
    }

    @Test("Off by default: a signal does nothing and is left alone")
    func offByDefault() {
        let signal = FakeSignal()
        signal.contents = "true"
        let (sleep, halts) = make(signal)
        #expect(!sleep.isArmed)
        sleep.check(now: t0)
        #expect(!sleep.isHalted)
        #expect(halts().isEmpty)
        #expect(signal.contents == "true")
    }

    @Test("Turning the switch on clears an old signal, so it never fires")
    func armingClearsStaleSignal() {
        let signal = FakeSignal()
        signal.contents = "true"
        let (sleep, halts) = make(signal)
        sleep.setArmed(true)
        sleep.check(now: t0)
        #expect(signal.contents == nil)
        #expect(!sleep.isHalted)
        #expect(halts().isEmpty)
    }

    @Test("A true signal halts once, clears the file and turns the switch off")
    func signalHalts() {
        let signal = FakeSignal()
        let settings = InMemorySettingsStore()
        let (sleep, halts) = make(signal, settings: settings)
        sleep.setArmed(true)
        sleep.check(now: t0)
        #expect(!sleep.isHalted)

        signal.contents = " TRUE\n"
        sleep.check(now: t0)
        #expect(sleep.haltedAt == t0)
        #expect(!sleep.isArmed)
        #expect(settings.agentSleepArmed == false)
        #expect(signal.contents == nil)
        #expect(halts() == [t0])

        // A second signal while halted, or after, does nothing: the switch is off.
        signal.contents = "true"
        sleep.check(now: t0.addingTimeInterval(30))
        sleep.resume()
        sleep.check(now: t0.addingTimeInterval(60))
        #expect(halts() == [t0, nil])
        #expect(!sleep.isHalted)
    }

    @Test("Anything other than true is ignored")
    func otherContentsIgnored() {
        for contents in ["", "false", "1", "yes", "truee"] {
            #expect(!AgentSleep.isDone(contents), "\(contents)")
        }
        #expect(!AgentSleep.isDone(nil))
        #expect(AgentSleep.isDone("true"))
        #expect(AgentSleep.isDone("True\n"))
    }

    @Test("Resume ends the halt; resuming when not halted does nothing")
    func resume() {
        let signal = FakeSignal()
        let (sleep, halts) = make(signal)
        sleep.resume()
        #expect(halts().isEmpty)

        sleep.setArmed(true)
        signal.contents = "true"
        sleep.check(now: t0)
        sleep.resume()
        #expect(!sleep.isHalted)
        #expect(halts() == [t0, nil])
    }

    @Test("The switch survives a restart; a halt does not")
    func restart() {
        let signal = FakeSignal()
        let settings = InMemorySettingsStore()
        let (sleep, _) = make(signal, settings: settings)
        sleep.setArmed(true)

        let (relaunched, _) = make(signal, settings: settings)
        #expect(relaunched.isArmed)

        signal.contents = "true"
        relaunched.check(now: t0)
        #expect(relaunched.isHalted)

        let (again, _) = make(signal, settings: settings)
        #expect(!again.isHalted)
        #expect(!again.isArmed)
    }

    @Test("A mode that requires the switch turns it on and keeps it on")
    func requiredByMode() {
        let signal = FakeSignal()
        let (sleep, _) = make(signal)
        sleep.setRequired(true)
        #expect(sleep.isArmed)
        sleep.setArmed(false) // by hand: refused
        #expect(sleep.isArmed)
        sleep.setRequired(false)
        sleep.setArmed(false)
        #expect(!sleep.isArmed)
    }

    @Test("Required: after a halt, resume turns the switch back on and drops a stale signal")
    func requiredRearmsOnResume() {
        let signal = FakeSignal()
        let (sleep, halts) = make(signal)
        sleep.setRequired(true)
        signal.contents = "true"
        sleep.check(now: t0)
        #expect(sleep.isHalted)
        #expect(!sleep.isArmed)

        signal.contents = "true" // written while halted
        sleep.resume()
        #expect(sleep.isArmed)
        #expect(signal.contents == nil)
        sleep.check(now: t0.addingTimeInterval(30))
        #expect(!sleep.isHalted)
        #expect(halts() == [t0, nil])
    }

    @Test("Required at launch with the switch already on keeps a waiting signal")
    func requiredKeepsWaitingSignal() {
        let signal = FakeSignal()
        let settings = InMemorySettingsStore()
        settings.agentSleepArmed = true
        signal.contents = "true"
        let (sleep, _) = make(signal, settings: settings)
        sleep.setRequired(true)
        sleep.check(now: t0)
        #expect(sleep.isHalted)
    }

    @Test("The real file: written by an agent, read, then deleted")
    func realFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sleep-at")

        let sleep = AgentSleep(settings: InMemorySettingsStore(), signalFile: file)
        sleep.setArmed(true)
        sleep.check(now: t0) // no file yet
        #expect(!sleep.isHalted)

        try "true\n".write(to: file, atomically: true, encoding: .utf8)
        sleep.check(now: t0)
        #expect(sleep.isHalted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
