import AppKit
import ServiceManagement

/// "Open at Login" through SMAppService. macOS may ask the user to approve it in
/// System Settings → General → Login Items the first time.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSLog("LaunchDeck: login item change failed: \(error)")
        }
    }
}
