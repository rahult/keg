import Foundation
import Observation
import Sparkle

/// How often Keg looks for a new release in the background.
///
/// Sparkle refuses intervals under an hour, so the shortest option here is a
/// day — checking more often than that just burns requests on a feed that
/// changes a handful of times a month.
enum UpdateCheckFrequency: TimeInterval, CaseIterable, Identifiable {
    case daily = 86_400
    case weekly = 604_800

    var id: TimeInterval { rawValue }

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    /// Sparkle stores the interval as a raw number of seconds, which may not
    /// match either case — an older build, or a value set by hand in defaults.
    /// Anything unrecognised reads as the default.
    static func closest(to interval: TimeInterval) -> UpdateCheckFrequency {
        allCases.min { abs($0.rawValue - interval) < abs($1.rawValue - interval) } ?? .daily
    }
}

/// Keg's wrapper around Sparkle.
///
/// Sparkle exposes its preferences as KVO properties on `SPUUpdater` and
/// persists them itself, so this type deliberately keeps no storage of its own
/// — the stored properties exist only so SwiftUI has something observable to
/// bind to, and every setter writes straight through to Sparkle.
///
/// ## Why these defaults
///
/// Automatic *checking* is left for Sparkle to ask about on second launch
/// rather than switched on here. That one-time prompt is the honest way to
/// turn on a feature that talks to the network on the user's behalf, and
/// answering it writes the same preference this screen reads.
///
/// Automatic *downloading* is off until asked for. Sparkle installs a
/// background-downloaded update when the app quits, which is safe enough in
/// itself, but Keg is usually sitting in the menu bar next to running
/// containers — spending bandwidth and swapping the binary underneath that
/// without being asked is not a default worth having.
@MainActor
@Observable
final class SoftwareUpdater {
    /// True once Sparkle is idle and able to start a check. The
    /// "Check for Updates…" menu item binds to this so it greys out while a
    /// check is already in flight.
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    var checkFrequency: UpdateCheckFrequency {
        didSet { updater.updateCheckInterval = checkFrequency.rawValue }
    }

    var lastCheckDate: Date? { updater.lastUpdateCheckDate }

    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    init() {
        // `startingUpdater: true` kicks off the scheduled-check timer as soon as
        // the app launches, which is also when Sparkle puts up its one-time
        // permission prompt if it has never been answered.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        checkFrequency = .closest(to: controller.updater.updateCheckInterval)

        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// Check right now, showing progress and any result to the user. This is
    /// the explicit "Check for Updates…" path — unlike the scheduled check it
    /// always reports back, including "you're up to date".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
