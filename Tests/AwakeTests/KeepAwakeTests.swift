import Testing

@testable import Awake

private typealias Mode = KeepAwakeMode

@Suite("Keep-awake mode")
struct KeepAwakeModeTests {
    @Test("Assertions held per mode")
    func assertionsPerMode() {
        #expect(Mode.off.heldAssertions == .init(systemSleep: false, displaySleep: false))
        #expect(Mode.screenCanSleep.heldAssertions == .init(systemSleep: true, displaySleep: false))
        // Screen-on holds the system assertion too: redundant, but explicit.
        #expect(Mode.screenOn.heldAssertions == .init(systemSleep: true, displaySleep: true))
    }

    @Test("Migration from the old two settings, all nine combinations")
    func migration() {
        let cases: [(keepAwake: Bool?, display: Bool?, expected: Mode)] = [
            // keepDisplayOn true always wins.
            (nil, true, .screenOn), (true, true, .screenOn), (false, true, .screenOn),
            // Otherwise the old keep-awake switch decides; never saved means on (its default).
            (nil, false, .screenCanSleep), (true, false, .screenCanSleep), (false, false, .off),
            (nil, nil, .screenCanSleep), (true, nil, .screenCanSleep), (false, nil, .off),
        ]
        #expect(cases.count == 9)
        for c in cases {
            #expect(
                Mode.migrated(keepAwakeEnabled: c.keepAwake, keepDisplayOn: c.display) == c.expected,
                "keepAwakeEnabled \(String(describing: c.keepAwake)), keepDisplayOn \(String(describing: c.display))"
            )
        }
    }
}

@MainActor
@Suite("Keep-awake settings persistence")
struct KeepAwakeSettingsTests {
    @Test("Nothing saved at all comes up as keep awake, screen off, and is saved")
    func freshInstall() {
        let store = InMemorySettingsStore()
        #expect(KeepAwakeSettings(settings: store).mode == .screenCanSleep)
        #expect(store.keepAwakeMode == "screenCanSleep")
    }

    @Test("The user's existing state (screen on saved) migrates to screen on, and the old keys are removed")
    func migratesScreenOn() {
        let store = InMemorySettingsStore()
        store.legacyKeepDisplayOn = true
        let keep = KeepAwakeSettings(settings: store)
        #expect(keep.mode == .screenOn)
        #expect(store.keepAwakeMode == "screenOn")
        #expect(store.legacyKeepDisplayOn == nil && store.legacyKeepAwakeEnabled == nil)
        #expect(store.legacyRemovals == 1)
    }

    @Test("Old keep-awake off migrates to off")
    func migratesOff() {
        let store = InMemorySettingsStore()
        store.legacyKeepAwakeEnabled = false
        #expect(KeepAwakeSettings(settings: store).mode == .off)
        #expect(store.keepAwakeMode == "off")
    }

    @Test("Once a mode is saved the old keys are never read again")
    func migratesOnlyOnce() {
        let store = InMemorySettingsStore()
        store.keepAwakeMode = "off"
        store.legacyKeepDisplayOn = true // stale leftover that must be ignored
        #expect(KeepAwakeSettings(settings: store).mode == .off)
        #expect(store.legacyRemovals == 0)
    }

    @Test("An unrecognised saved value is treated as missing")
    func unrecognisedValue() {
        let store = InMemorySettingsStore()
        store.keepAwakeMode = "bogus"
        #expect(KeepAwakeSettings(settings: store).mode == .screenCanSleep)
        #expect(store.keepAwakeMode == "screenCanSleep")
    }

    @Test("Picking a mode saves it, and a new instance reads it back")
    func saveAndRoundTrip() {
        let store = InMemorySettingsStore()
        let keep = KeepAwakeSettings(settings: store)
        for mode in KeepAwakeMode.allCases {
            keep.setMode(mode)
            #expect(store.keepAwakeMode == mode.rawValue)
            #expect(KeepAwakeSettings(settings: store).mode == mode)
        }
    }

    @Test("Picking the mode that is already selected reports no change")
    func noOpPick() {
        let keep = KeepAwakeSettings(settings: InMemorySettingsStore()) // screenCanSleep
        #expect(!keep.setMode(.screenCanSleep))
        #expect(keep.setMode(.screenOn))
        #expect(!keep.setMode(.screenOn))
    }
}
