import AppKit

extension AppState {
    /// Opens the Settings window, top-left aligned with the main window so it
    /// reads as part of the app rather than a floating panel dropped mid-screen.
    func openSettings() {
        captureSettingsFrame()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
