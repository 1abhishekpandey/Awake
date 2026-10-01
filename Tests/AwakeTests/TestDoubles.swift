import Foundation

@testable import Awake

// In-memory stand-ins for the real storage. Tests use only these, so they never
// touch the real history file or the real preferences.

/// Keeps the history in memory. A second tracker built on the same instance
/// behaves like the app restarting: it sees exactly what was saved.
final class InMemoryHistoryStore: HistoryStoring {
    private(set) var stored: [String: TimeInterval]

    init(_ stored: [String: TimeInterval] = [:]) {
        self.stored = stored
    }

    func load() -> [String: TimeInterval] { stored }
    func save(_ history: [String: TimeInterval]) { stored = history }
}

/// Wraps another store and counts how many times it was asked to save.
final class SpyHistoryStore: HistoryStoring {
    private let wrapped: any HistoryStoring
    private(set) var saveCount = 0

    init(wrapping wrapped: any HistoryStoring = InMemoryHistoryStore()) {
        self.wrapped = wrapped
    }

    func load() -> [String: TimeInterval] { wrapped.load() }

    func save(_ history: [String: TimeInterval]) {
        saveCount += 1
        wrapped.save(history)
    }
}

/// Settings held in memory, starting from the app's defaults.
final class InMemorySettingsStore: SettingsStoring {
    var keepAwakeMode: String?
    var batteryCutoffPercent = SettingsDefaults.batteryCutoffPercent
    var dayResetMinute = SettingsDefaults.dayResetMinute
    var didSetupLoginItem = SettingsDefaults.didSetupLoginItem
    var lastGoalNotifiedDay: String?
    var chargeStartPercent = SettingsDefaults.chargeStartPercent
    var chargeStopPercent = SettingsDefaults.chargeStopPercent
    var plugEnabled = SettingsDefaults.plugEnabled

    // The pre-mode keep-awake settings, `nil` when "never saved".
    var legacyKeepAwakeEnabled: Bool?
    var legacyKeepDisplayOn: Bool?
    private(set) var legacyRemovals = 0

    func removeLegacyKeepAwakeSettings() {
        legacyKeepAwakeEnabled = nil
        legacyKeepDisplayOn = nil
        legacyRemovals += 1
    }
}
