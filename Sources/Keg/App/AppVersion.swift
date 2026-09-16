import Foundation

/// The running app's version, read from the bundle that the Makefile stamps at
/// build time.
///
/// `short` is the marketing version shown to people (`0.2.0`); `build` is the
/// monotonically increasing number Sparkle actually compares when deciding
/// whether a release is newer. In CI the build number is the workflow run
/// number, which only ever goes up.
enum AppVersion {
    static let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    /// `0.2.0 (417)` for a published build, or bare `0.2.0` for a local one.
    ///
    /// A local `make app` always stamps build 1, so showing it would be noise
    /// that looks like a real build number. Only CI produces a number worth
    /// putting in front of someone filing a bug report.
    static func displayString(short: String, build: String) -> String {
        guard build != "0", build != "1" else { return short }
        return "\(short) (\(build))"
    }

    static var displayString: String {
        displayString(short: short, build: build)
    }
}
