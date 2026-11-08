import AppKit
import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`. Registration can fail for an
/// ad-hoc build, a moved bundle, or a missing Applications folder; callers
/// must surface the error instead of silently pretending the toggle worked.
enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.users",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
