import Foundation
import Observation
import ServiceManagement

/// "Open at Login" via `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status
    private(set) var errorMessage: String?

    @ObservationIgnored private let service = SMAppService.mainApp
    @ObservationIgnored private let settings: any SettingsStoring

    var isEnabled: Bool { status == .enabled }
    /// The user switched it off in System Settings; only they can switch it back on there.
    var needsApproval: Bool { status == .requiresApproval }

    init(settings: any SettingsStoring) {
        self.settings = settings
        status = SMAppService.mainApp.status
    }

    /// Re-reads the real state, since the user can change it in System Settings at any time.
    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Login item: \(error.localizedDescription)"
        }
        refresh()
    }

    /// On the very first launch only, turn "Open at Login" on. If the user later
    /// turns it off it is never switched back on. Runs only from an Applications
    /// folder, so a development build in `build/` neither registers its own path
    /// nor uses up the first-launch chance.
    func enableOnFirstLaunch() {
        guard !settings.didSetupLoginItem else { return }
        guard Bundle.main.bundlePath.contains("/Applications/") else { return }
        settings.didSetupLoginItem = true
        setEnabled(true)
    }
}
