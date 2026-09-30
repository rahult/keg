import AppKit

extension AppState {
    /// Opens the Settings window.
    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
