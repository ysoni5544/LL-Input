import Foundation
import ServiceManagement

/// Manages the "Launch at Login" login-item registration via SMAppService
/// (macOS 13+). Defaults to enabled on first run.
enum LoginItem {

    private static let didSetDefaultKey = "loginItemDefaultApplied"

    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enable or disable the login item. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// On the very first launch, turn the login item on by default.
    static func applyDefaultIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: didSetDefaultKey) else { return }
        d.set(true, forKey: didSetDefaultKey)
        setEnabled(true)
    }
}
