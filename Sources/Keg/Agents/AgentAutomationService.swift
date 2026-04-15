import AppKit
import Foundation
import UserNotifications

actor AgentAutomationService {
    func captureState() async -> AgentAutomationState {
        let activeAppName = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }

        let finderSelection = captureFinderSelection()
        let terminalContext = captureTerminalContext(activeAppName: activeAppName)
        let browserContext = captureBrowserContext(activeAppName: activeAppName)
        let notifications = await notificationStatus()

        return AgentAutomationState(
            context: AgentDesktopContextSnapshot(
                activeAppName: activeAppName,
                selectedFiles: finderSelection,
                terminalAppName: terminalContext.appName,
                terminalSnapshot: terminalContext.snapshot,
                pageTitle: browserContext.title,
                pageURL: browserContext.url,
                selectedText: browserContext.selectedText
            ),
            notificationStatus: notifications
        )
    }

    func requestNotificationAuthorization() async -> AgentNotificationStatus {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                return await notificationStatus()
            }
            return .denied
        } catch {
            return .denied
        }
    }

    func scheduleNotification(for item: AgentApprovalItem) async {
        let center = UNUserNotificationCenter.current()
        guard await notificationStatus().isDeliverable else { return }

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.summary
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: item.id.uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try? await center.add(request)
    }

    private func notificationStatus() async -> AgentNotificationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    private func captureFinderSelection() -> [String] {
        let output = runAppleScript([
            "tell application \"Finder\"",
            "if not (exists Finder window 1) then return \"\"",
            "if (count of selection) is 0 then return \"\"",
            "set selectedPaths to {}",
            "repeat with itemRef in selection",
            "set end of selectedPaths to POSIX path of (itemRef as alias)",
            "end repeat",
            "set AppleScript's text item delimiters to linefeed",
            "return selectedPaths as text",
            "end tell"
        ])

        return output?
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private func captureTerminalContext(activeAppName: String?) -> (appName: String?, snapshot: String?) {
        guard let activeAppName else { return (nil, nil) }

        if activeAppName == "Terminal" {
            let output = runAppleScript([
                "tell application \"Terminal\"",
                "if not (exists front window) then return \"\"",
                "set rawHistory to history of selected tab of front window",
                "if rawHistory is missing value then return \"\"",
                "return rawHistory",
                "end tell"
            ])
            return ("Terminal", Self.truncateTranscript(output))
        }

        if activeAppName == "iTerm2" || activeAppName == "iTerm" {
            let output = runAppleScript([
                "tell application \"iTerm2\"",
                "if not (exists current window) then return \"\"",
                "set sessionText to contents of current session of current window",
                "return sessionText",
                "end tell"
            ])
            return ("iTerm2", Self.truncateTranscript(output))
        }

        return (nil, nil)
    }

    private func captureBrowserContext(activeAppName: String?) -> (title: String?, url: String?, selectedText: String?) {
        guard let activeAppName else { return (nil, nil, nil) }

        if activeAppName == "Safari" {
            let output = runAppleScript([
                "tell application \"Safari\"",
                "if not (exists front window) then return \"\"",
                "set pageTitle to name of front document",
                "set pageURL to URL of front document",
                "set pageSelection to do JavaScript \"window.getSelection().toString()\" in front document",
                "return pageTitle & linefeed & pageURL & linefeed & pageSelection",
                "end tell"
            ])
            return Self.parseBrowserContext(output)
        }

        let chromiumApps = ["Google Chrome", "Arc", "Brave Browser", "Microsoft Edge", "Chromium"]
        guard chromiumApps.contains(activeAppName) else { return (nil, nil, nil) }

        let output = runAppleScript([
            "tell application \"\(activeAppName)\"",
            "if not (exists front window) then return \"\"",
            "set pageTitle to title of active tab of front window",
            "set pageURL to URL of active tab of front window",
            "set pageSelection to execute active tab of front window javascript \"window.getSelection().toString()\"",
            "return pageTitle & linefeed & pageURL & linefeed & pageSelection",
            "end tell"
        ])

        return Self.parseBrowserContext(output)
    }

    private func runAppleScript(_ lines: [String]) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = lines.flatMap { ["-e", $0] }
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func truncateTranscript(_ input: String?, maxLines: Int = 20) -> String? {
        guard let input else { return nil }
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }
        return lines.suffix(maxLines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseBrowserContext(_ output: String?) -> (title: String?, url: String?, selectedText: String?) {
        guard let output else { return (nil, nil, nil) }
        let lines = output.components(separatedBy: .newlines)
        let title = lines.first?.nilIfEmpty
        let url = lines.dropFirst().first?.nilIfEmpty
        let selectedText = lines.dropFirst(2).joined(separator: "\n").nilIfEmpty
        return (title, url, selectedText)
    }
}

private extension AgentNotificationStatus {
    var isDeliverable: Bool {
        self == .authorized || self == .provisional
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
