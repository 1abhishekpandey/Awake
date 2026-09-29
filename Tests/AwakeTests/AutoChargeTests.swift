import Foundation
import Testing

@testable import Awake

// MARK: - Tuya frames

/// Reference frames produced by tinytuya 1.20 for a fake device and key, with
/// t = 1700000000 and sequence number 1.
@Suite("Tuya v3.3 frames")
struct TuyaProtocolTests {
    let deviceID = "abcdefghijklmnopqrst"
    let key = Data("0123456789abcdef".utf8)

    @Test("Status query matches tinytuya byte for byte")
    func query() {
        let frame = TuyaProtocol.queryFrame(deviceID: deviceID, key: key, time: 1_700_000_000, sequence: 1)
        #expect(frame.hex == "000055aa000000010000000a0000007883b826e8f182142bfc9263ab20ec22eedbf9e5dceb0ed27dc4b3d9d972aa7c28bce3a3fbedd498818b8ee0bf0f7960878047c27ec9e66056ab7029ce964f44df7e97df37843caaa36fc8cdaedf8b35ca6ac51534ab05ceda2be42c7fd8e74ef4be23f34440aefb47c4fa7fbe7027af018318879c0000aa55")
    }

    @Test("Switch on matches tinytuya byte for byte")
    func switchOn() {
        let frame = TuyaProtocol.controlFrame(deviceID: deviceID, key: key, switchDP: 1, on: true, time: 1_700_000_000, sequence: 1)
        #expect(frame.hex == "000055aa000000010000000700000077332e3300000000000000000000000001ca05cfd1d2e621972136d1d5699177f4238c7231929ac11dc1ac5e13ddd60d5fe83d8db46446cf7976f1c4779d76c4c96ed906db04678c823757f9f4cfd4aa14289c9042f2aa08005786aab66fcc6d5c91b94d45d4e66e522e93cf8c4ab1feb655d4200000aa55")
    }

    @Test("Switch off matches tinytuya byte for byte")
    func switchOff() {
        let frame = TuyaProtocol.controlFrame(deviceID: deviceID, key: key, switchDP: 1, on: false, time: 1_700_000_000, sequence: 1)
        #expect(frame.hex == "000055aa000000010000000700000087332e3300000000000000000000000001ca05cfd1d2e621972136d1d5699177f4238c7231929ac11dc1ac5e13ddd60d5fe83d8db46446cf7976f1c4779d76c4c96ed906db04678c823757f9f4cfd4aa14289c9042f2aa08005786aab66fcc6d7b50fe717963a01b6532a0fa6e056db7377222e061a924c591cd9c27ea163ed49166a83e0000aa55")
    }

    @Test("A status reply decodes to its dps")
    func decodeStatus() throws {
        let json = Data(#"{"devId":"abcdefghijklmnopqrst","dps":{"1":true,"20":2443}}"#.utf8)
        let payload = Data(count: 4) + TuyaProtocol.encrypt(json, key: key) // return code 0, then data
        let frame = TuyaProtocol.frame(command: .query, payload: payload, sequence: 1)

        #expect(TuyaProtocol.frameLength(header: frame.prefix(16)) == frame.count)
        let reply = try TuyaProtocol.decodeReply(frame, key: key)
        let dps = reply?["dps"] as? [String: Any]
        #expect(dps?["1"] as? Bool == true)
    }

    @Test("An empty acknowledgement decodes to nil")
    func decodeAck() throws {
        let frame = TuyaProtocol.frame(command: .control, payload: Data(count: 4), sequence: 1)
        #expect(try TuyaProtocol.decodeReply(frame, key: key) == nil)
    }

    @Test("A corrupted frame is rejected")
    func badChecksum() {
        var frame = TuyaProtocol.frame(command: .control, payload: Data(count: 4), sequence: 1)
        frame[18] ^= 0xFF
        #expect(throws: TuyaProtocol.ProtocolError.badChecksum) { try TuyaProtocol.decodeReply(frame, key: key) }
    }
}

// MARK: - Credentials

@Suite("Plug credentials")
struct PlugCredentialsTests {
    @Test("Valid JSON parses, switch DP defaults to 1")
    func parses() {
        let json = Data(#"{"deviceId":"abc","localKey":"0123456789abcdef","host":"192.168.1.5"}"#.utf8)
        let credentials = PlugCredentials(json: json)
        #expect(credentials?.deviceID == "abc")
        #expect(credentials?.host == "192.168.1.5")
        #expect(credentials?.switchDP == 1)
    }

    @Test("A key that isn't 16 characters is rejected")
    func badKey() {
        let json = Data(#"{"deviceId":"abc","localKey":"short","host":"192.168.1.5"}"#.utf8)
        #expect(PlugCredentials(json: json) == nil)
    }
}

// MARK: - Levels and decisions

@Suite("Auto-charge levels")
struct ChargeLevelTests {
    @Test("Start choices sit above the cutoff and below the stop level, in 5% steps")
    func startChoices() {
        #expect(AwakeMath.chargeStartChoices(cutoff: 10, stop: 40) == [15, 20, 25, 30, 35])
    }

    @Test("Stop choices run from above the start up to 100%")
    func stopChoices() {
        #expect(AwakeMath.chargeStopChoices(start: 80) == [85, 90, 95, 100])
    }

    @Test("A start at or below the cutoff moves just above it")
    func clampStart() {
        #expect(AwakeMath.clampedChargeLevels(cutoff: 30, start: 30, stop: 90) == (35, 90))
        #expect(AwakeMath.clampedChargeLevels(cutoff: 40, start: 25, stop: 90) == (45, 90))
    }

    @Test("A stop that is no longer above the start moves up with it")
    func clampStop() {
        #expect(AwakeMath.clampedChargeLevels(cutoff: 80, start: 30, stop: 80) == (85, 90))
    }

    @Test("Off-grid values snap to the 5% grid")
    func snaps() {
        #expect(AwakeMath.clampedChargeLevels(cutoff: 10, start: 27, stop: 93) == (25, 90))
    }
}

@Suite("Auto-charge decision")
struct PlugActionTests {
    @Test("On battery at or below start: switch on")
    func turnOn() {
        #expect(AwakeMath.plugAction(onAC: false, charge: 30, start: 30, stop: 90) == .turnOn)
        #expect(AwakeMath.plugAction(onAC: false, charge: 12, start: 30, stop: 90) == .turnOn)
    }

    @Test("Charging at or above stop: switch off")
    func turnOff() {
        #expect(AwakeMath.plugAction(onAC: true, charge: 90, start: 30, stop: 90) == .turnOff)
        #expect(AwakeMath.plugAction(onAC: true, charge: 100, start: 30, stop: 90) == .turnOff)
    }

    @Test("Between the levels, or already in the right state: leave it alone")
    func leaveAlone() {
        #expect(AwakeMath.plugAction(onAC: false, charge: 31, start: 30, stop: 90) == nil)
        #expect(AwakeMath.plugAction(onAC: true, charge: 89, start: 30, stop: 90) == nil)
        #expect(AwakeMath.plugAction(onAC: true, charge: 20, start: 30, stop: 90) == nil)
        #expect(AwakeMath.plugAction(onAC: false, charge: 95, start: 30, stop: 90) == nil)
        #expect(AwakeMath.plugAction(onAC: false, charge: nil, start: 30, stop: 90) == nil)
    }
}

// MARK: - AutoCharger

/// Records commands and fails when told to.
private final class FakePlug: @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [AutoCharger.PlugCommand] = []
    var fail = false
    /// What a status query reports.
    var isOn = false

    var commands: [AutoCharger.PlugCommand] { lock.withLock { _commands } }

    var client: AutoCharger.PlugClient {
        { [self] command in
            lock.withLock { _commands.append(command) }
            if fail { throw SmartPlug.PlugError.timedOut }
            switch command {
            case .query: return isOn
            case .set(let on): return on
            }
        }
    }
}

@MainActor
@Suite("Auto-charger")
struct AutoChargerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCharger(plug: FakePlug, setUp: Bool = true) -> (AutoCharger, [String]) {
        let settings = InMemorySettingsStore()
        settings.chargeStartPercent = 30
        settings.chargeStopPercent = 90
        let charger = AutoCharger(
            settings: settings, cutoffPercent: 20, client: plug.client, hasCredentials: { setUp }, notify: { _, _ in }
        )
        return (charger, [])
    }

    /// Lets the charger's command task finish.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test("Plug not set up: never touches the plug")
    func notSetUp() async {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug, setUp: false)
        charger.evaluate(onAC: false, charge: 10, now: t0)
        await settle()
        #expect(plug.commands.isEmpty)
    }

    @Test("Falling to the start level switches on once, not on every 1% after")
    func switchesOnOnce() async {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug)
        charger.evaluate(onAC: false, charge: 31, now: t0)
        charger.evaluate(onAC: false, charge: 30, now: t0)
        await settle()
        charger.evaluate(onAC: false, charge: 29, now: t0.addingTimeInterval(10))
        await settle()
        #expect(plug.commands == [.set(on: true)])
    }

    @Test("Reaching the stop level while charging switches off")
    func switchesOff() async {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug)
        charger.evaluate(onAC: true, charge: 90, now: t0)
        await settle()
        #expect(plug.commands == [.set(on: false)])
        #expect(charger.lastEvent?.hasPrefix("Charger off at 90%") == true)
    }

    @Test("A full cycle: on at start, off at stop")
    func fullCycle() async {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug)
        charger.evaluate(onAC: false, charge: 30, now: t0)
        await settle()
        charger.evaluate(onAC: true, charge: 31, now: t0.addingTimeInterval(20))
        charger.evaluate(onAC: true, charge: 90, now: t0.addingTimeInterval(3600))
        await settle()
        #expect(plug.commands == [.set(on: true), .set(on: false)])
    }

    @Test("A failure is retried after a minute, not sooner")
    func retriesAfterFailure() async {
        let plug = FakePlug()
        plug.fail = true
        let (charger, _) = makeCharger(plug: plug)
        charger.evaluate(onAC: false, charge: 25, now: t0)
        await settle()
        #expect(charger.lastEventFailed)
        charger.evaluate(onAC: false, charge: 25, now: t0.addingTimeInterval(30))
        await settle()
        #expect(plug.commands.count == 1)

        plug.fail = false
        charger.evaluate(onAC: false, charge: 24, now: t0.addingTimeInterval(61))
        await settle()
        #expect(plug.commands.count == 2)
        #expect(!charger.lastEventFailed)
    }

    @Test("Switched on but still on battery after a minute: one more try")
    func notChargingRetry() async {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug)
        charger.evaluate(onAC: false, charge: 30, now: t0)
        await settle()
        charger.evaluate(onAC: false, charge: 29, now: t0.addingTimeInterval(61))
        await settle()
        charger.evaluate(onAC: false, charge: 28, now: t0.addingTimeInterval(200))
        await settle()
        #expect(plug.commands == [.set(on: true), .set(on: true)])
    }

    @Test("The charger button reads the plug first, then flips it")
    func buttonFlipsUnknownState() async {
        let plug = FakePlug()
        plug.isOn = true
        let (charger, _) = makeCharger(plug: plug)
        charger.togglePlug(now: t0)
        await settle()
        #expect(plug.commands == [.query, .set(on: false)])
        #expect(charger.plugIsOn == false)

        charger.togglePlug(now: t0)
        await settle()
        #expect(plug.commands.last == .set(on: true))
        #expect(charger.plugIsOn == true)
    }

    @Test("Turning the charger on by hand above the stop level isn't undone at once")
    func manualSwitchIsRespected() async {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug)
        charger.evaluate(onAC: false, charge: 95, now: t0) // between levels: nothing
        charger.togglePlug(now: t0)                        // user turns the charger on
        await settle()
        charger.evaluate(onAC: false, charge: 95, now: t0.addingTimeInterval(1))
        charger.evaluate(onAC: true, charge: 95, now: t0.addingTimeInterval(5))
        charger.evaluate(onAC: true, charge: 100, now: t0.addingTimeInterval(600))
        await settle()
        #expect(plug.commands == [.query, .set(on: true)])

        // Unplugged later and drained to the start level: automatic again.
        charger.evaluate(onAC: false, charge: 30, now: t0.addingTimeInterval(9000))
        await settle()
        #expect(plug.commands.last == .set(on: true))
        #expect(plug.commands.count == 3)
    }

    @Test("Turning the charger off by hand at a low level isn't undone at once")
    func manualOffIsRespected() async {
        let plug = FakePlug()
        plug.isOn = true
        let (charger, _) = makeCharger(plug: plug)
        charger.togglePlug(now: t0)
        await settle()
        charger.evaluate(onAC: false, charge: 25, now: t0.addingTimeInterval(5))
        charger.evaluate(onAC: false, charge: 24, now: t0.addingTimeInterval(120))
        await settle()
        #expect(plug.commands == [.query, .set(on: false)])
    }

    @Test("Raising the cutoff to the start level moves start above it")
    func cutoffPushesStart() {
        let plug = FakePlug()
        let (charger, _) = makeCharger(plug: plug)
        charger.cutoffChanged(to: 30)
        #expect(charger.startPercent == 35)
        #expect(charger.startChoices.first == 35)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
