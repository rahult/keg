import AppKit
import Foundation

/// Which terminal emulator to open container shells in.
enum TerminalEmulator: String, CaseIterable, Identifiable, Sendable {
    case terminal = "Terminal"
    case iterm = "iTerm"

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        }
    }

    /// iTerm2 only if it is actually installed; otherwise fall back to Terminal.
    var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

/// Opens an interactive shell inside a running container in the user's
/// preferred terminal emulator. The command runs visibly in the terminal
/// window so it stays cancellable and closeable by the user.
enum TerminalLauncher {
    private static let preferredDefaultsKey = "terminal.preferredEmulator"

    static var preferred: TerminalEmulator {
        get {
            if let raw = UserDefaults.standard.string(forKey: preferredDefaultsKey),
               let emulator = TerminalEmulator(rawValue: raw), emulator.isAvailable {
                return emulator
            }
            // Default to iTerm when installed, else Terminal.
            return TerminalEmulator.iterm.isAvailable ? .iterm : .terminal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferredDefaultsKey)
        }
    }

    /// Open the container's default shell (bash when present, else sh).
    static func openShell(containerID: String) {
        let shell = detectShell(containerID: containerID)
        openTerminal(emulator: preferred, command: "container exec -it \(containerID) \(shell)")
    }

    /// Open a specific shell in the container.
    static func openShell(containerID: String, shell: String) {
        openTerminal(emulator: preferred, command: "container exec -it \(containerID) \(shell)")
    }

    /// Ask the container which shell it has. Runs `sh` (present in every
    /// image) to probe for bash so we land people in a comfortable shell
    /// without guessing from the image name.
    private static func detectShell(containerID: String) -> String {
        guard let process = try? ContainerCLI.makeProcess(
            ["exec", containerID, "sh", "-lc", "command -v bash >/dev/null 2>&1 && echo bash || echo sh"]
        ) else {
            return "sh"
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines) == "bash" ? "bash" : "sh"
        } catch {
            return "sh"
        }
    }

    private static func openTerminal(emulator: TerminalEmulator, command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch emulator {
        case .terminal:
            script = "tell application \"Terminal\" to do script \"\(escaped)\""
        case .iterm:
            script = """
                tell application "iTerm"
                    create window with default profile command "\(escaped)"
                    activate
                end tell
                """
        }
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil, emulator != .terminal {
            // iTerm AppleScript failed (e.g. automation permission) — fall back.
            openTerminal(emulator: .terminal, command: command)
        }
    }
}
