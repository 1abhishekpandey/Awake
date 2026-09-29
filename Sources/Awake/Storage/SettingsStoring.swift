import Foundation

/// Every persisted setting and small piece of state, as typed properties.
/// The app uses `UserDefaultsSettingsStore`; tests use an in-memory double.
///
/// A getter returns the default when nothing has been stored yet. Range
/// checking (for example "is this a valid cutoff choice") belongs to the
/// code that uses the value, not to the store.
protocol SettingsStoring: AnyObject {
    /// The keep-awake mode, as a `KeepAwakeMode` raw value. `nil` until first saved.
    var keepAwakeMode: String? { get set }
    /// "Stop everything below", in percent.
    var batteryCutoffPercent: Int { get set }
    /// "Day resets at", in minutes after midnight.
    var dayResetMinute: Int { get set }
    /// The first-launch "Open at Login" default has been applied.
    var didSetupLoginItem: Bool { get set }
    /// Work-day key (`yyyy-MM-dd`) for which the 8-hour notification was already sent.
    var lastGoalNotifiedDay: String? { get set }
    /// "Start charging at", in percent.
    var chargeStartPercent: Int { get set }
    /// "Stop charging at", in percent.
    var chargeStopPercent: Int { get set }

    // The two settings `keepAwakeMode` replaced. They are read once, to migrate, and then removed.
    /// Old "Keep Mac awake" switch, or `nil` if it was never saved.
    var legacyKeepAwakeEnabled: Bool? { get }
    /// Old "Keep screen on" switch, or `nil` if it was never saved.
    var legacyKeepDisplayOn: Bool? { get }
    func removeLegacyKeepAwakeSettings()
}

/// What each setting is before the user changes it.
enum SettingsDefaults {
    static let batteryCutoffPercent = AwakeMath.defaultCutoff
    static let dayResetMinute = AwakeMath.defaultResetMinute
    static let didSetupLoginItem = false
    static let chargeStartPercent = AwakeMath.defaultChargeStart
    static let chargeStopPercent = AwakeMath.defaultChargeStop
}
