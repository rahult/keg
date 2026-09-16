import AppKit
import Darwin
import Foundation

/// TEMPORARY launch diagnostics — remove before shipping.
///
/// Two probes for the launch-stall investigation:
/// 1. An uncaught-exception handler that prints the *unredacted* exception
///    name/reason/stack to stderr (the .ips reports redact the reason).
/// 2. `mark(_:)` — timestamped progress lines; the last mark printed before
///    the stall tells us which startup phase never completed.
enum LaunchDiagnostics {
    private static let start = Date()

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let message = """
            === UNCAUGHT EXCEPTION ===
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "<nil>")
            userInfo: \(String(describing: exception.userInfo))
            stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            ============================
            """
            FileHandle.standardError.write(Data(message.utf8))
            try? FileHandle.standardError.synchronize()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: nil
        ) { _ in
            mark("NSApplication.didFinishLaunching")
        }

        mark("LaunchDiagnostics installed")
    }

    static func mark(_ label: String) -> Bool {
        let elapsed = Date().timeIntervalSince(start)
        FileHandle.standardError.write(Data(String(format: "[mark %6.3fs] %@\n", elapsed, label).utf8))
        return true
    }
}
