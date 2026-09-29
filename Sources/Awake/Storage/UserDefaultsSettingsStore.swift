import Foundation

/// The real settings store, backed by `UserDefaults.standard`. The key names are
/// the ones the app has always used, so values saved by earlier versions carry over.
final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let keepAwakeMode = "keepAwakeMode"
        static let legacyKeepAwake = "keepAwakeEnabled"
        static let legacyKeepDisplay = "keepDisplayOn"
        static let batteryCutoff = "stopBelowPercent"
        static let dayReset = "dayResetMinute"
        static let didSetupLoginItem = "didSetupLoginItem"
        static let lastGoalNotifiedDay = "goalNotifiedDay"
    }

    var keepAwakeMode: String? {
        get { defaults.string(forKey: Key.keepAwakeMode) }
        set { defaults.set(newValue, forKey: Key.keepAwakeMode) }
    }

    var batteryCutoffPercent: Int {
        get { defaults.object(forKey: Key.batteryCutoff) as? Int ?? SettingsDefaults.batteryCutoffPercent }
        set { defaults.set(newValue, forKey: Key.batteryCutoff) }
    }

    var dayResetMinute: Int {
        get { defaults.object(forKey: Key.dayReset) as? Int ?? SettingsDefaults.dayResetMinute }
        set { defaults.set(newValue, forKey: Key.dayReset) }
    }

    var didSetupLoginItem: Bool {
        get { defaults.object(forKey: Key.didSetupLoginItem) as? Bool ?? SettingsDefaults.didSetupLoginItem }
        set { defaults.set(newValue, forKey: Key.didSetupLoginItem) }
    }

    var lastGoalNotifiedDay: String? {
        get { defaults.string(forKey: Key.lastGoalNotifiedDay) }
        set { defaults.set(newValue, forKey: Key.lastGoalNotifiedDay) }
    }

    var legacyKeepAwakeEnabled: Bool? { defaults.object(forKey: Key.legacyKeepAwake) as? Bool }
    var legacyKeepDisplayOn: Bool? { defaults.object(forKey: Key.legacyKeepDisplay) as? Bool }

    func removeLegacyKeepAwakeSettings() {
        defaults.removeObject(forKey: Key.legacyKeepAwake)
        defaults.removeObject(forKey: Key.legacyKeepDisplay)
    }
}
