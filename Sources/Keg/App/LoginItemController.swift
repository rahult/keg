import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (the modern replacement for
/// LSSharedFileList login items). The main-app registration survives
/// relocation of the bundle as long as the app keeps its bundle id.
@Observable
@MainActor
final class LoginItemController {
    /// Toggle binding target; registering happens in didSet.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            applyRegistration()
        }
    }

    init() {
        self.isEnabled = Self.status() == .enabled
    }

    private static func status() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    private func applyRegistration() {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails (rarely) when the app runs from a location
            // macOS refuses to launch at login, e.g. a DMG. Reflect reality.
            isEnabled = Self.status() == .enabled
        }
    }
}
