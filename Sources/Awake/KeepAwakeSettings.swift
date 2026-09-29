import Observation

/// Owns the keep-awake mode and saves it.
///
/// Kept apart from `PowerController` (which talks to IOKit) so the migration and what
/// gets saved can be tested against in-memory settings.
@MainActor
@Observable
final class KeepAwakeSettings {
    private(set) var mode: KeepAwakeMode

    @ObservationIgnored private let settings: any SettingsStoring

    /// Loads the saved mode. When none is saved (first run of this version), it is migrated
    /// once from the two old settings, saved, and the old keys are removed so they are
    /// never read again.
    init(settings: any SettingsStoring) {
        self.settings = settings
        if let raw = settings.keepAwakeMode, let saved = KeepAwakeMode(rawValue: raw) {
            mode = saved
        } else {
            let migrated = KeepAwakeMode.migrated(
                keepAwakeEnabled: settings.legacyKeepAwakeEnabled,
                keepDisplayOn: settings.legacyKeepDisplayOn
            )
            settings.keepAwakeMode = migrated.rawValue
            // Only drop the old keys once the new value is safely stored.
            if settings.keepAwakeMode == migrated.rawValue {
                settings.removeLegacyKeepAwakeSettings()
            }
            mode = migrated
        }
    }

    /// The user picked a mode. Returns true when it changed (so the caller re-evaluates
    /// the assertions).
    @discardableResult
    func setMode(_ new: KeepAwakeMode) -> Bool {
        guard new != mode else { return false }
        settings.keepAwakeMode = new.rawValue
        mode = new
        return true
    }
}
