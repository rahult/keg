import SwiftUI
import SwiftTerm

// MARK: - Terminal Session (real PTY)

/// A real terminal emulator hosting the user's login shell in a
/// pseudo-terminal via SwiftTerm. Unlike the pipe-and-Text approach it
/// replaces, this handles full VT100/xterm sequences: colors, cursor
/// control, line editing, and interactive full-screen programs.
struct TerminalSessionView: NSViewRepresentable {
    /// Extra environment for the shell: Keg wires the Docker socket and
    /// kubeconfig so `docker` and `kubectl` work without setup.
    var presetCommand: String?
    var onTerminated: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onTerminated: onTerminated)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.processDelegate = context.coordinator

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(
            executable: shell,
            args: ["-l"],
            // SwiftTerm 1.11 takes the environment as KEY=VALUE strings.
            environment: Self.shellEnvironment().map { "\($0.key)=\($0.value)" },
            execName: nil
        )

        if let presetCommand {
            view.getTerminal().feed(text: presetCommand + "\n")
            context.coordinator.lastFedCommand = presetCommand
        }

        // Make the terminal the first responder so keystrokes land in the
        // session without a click first.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onTerminated = onTerminated
        // Presets type into the live session rather than restarting it, so
        // state the user has built up (cd, exports, jobs) survives.
        if let presetCommand, presetCommand != context.coordinator.lastFedCommand {
            context.coordinator.lastFedCommand = presetCommand
            view.getTerminal().feed(text: presetCommand + "\n")
        }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.processDelegate = nil
        // SwiftTerm's deinit deliberately leaves the child shell running, so
        // navigation away has to terminate it here or shells would leak.
        view.process.terminate()
    }

    /// The child shell's environment: the app's own, plus everything a
    /// container workflow expects. Finder-launched apps inherit a minimal
    /// PATH, so the Homebrew prefixes are added by hand.
    static func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/sbin"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let missing = extraPaths.filter { !current.split(separator: ":").contains(Substring($0)) }
        if !missing.isEmpty {
            env["PATH"] = (missing + [current]).joined(separator: ":")
        }
        env["DOCKER_HOST"] = "unix://\(home)/.keg/docker.sock"
        env["KUBECONFIG"] = "\(home)/.keg/kubeconfig"
        if env["TERM"] == nil {
            env["TERM"] = "xterm-256color"
        }
        return env
    }

    /// SwiftTerm fires delegate callbacks on the main thread but declares
    /// the protocol nonisolated; the @preconcurrency conformance lets the
    /// coordinator stay @MainActor without runtime checks.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        var onTerminated: (() -> Void)?
        var lastFedCommand: String?

        init(onTerminated: (() -> Void)?) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onTerminated?()
        }
    }
}

// MARK: - Quick Terminal View

struct QuickTerminalView: View {
    /// New value = fresh session; preset commands are typed into the live
    /// session instead of restarting it.
    @State private var sessionID = UUID()
    @State private var pendingCommand: String?
    @State private var shellExited = false

    var body: some View {
        Group {
            if shellExited {
                exitedState
            } else {
                TerminalSessionView(
                    presetCommand: pendingCommand,
                    onTerminated: { shellExited = true }
                )
                .id(sessionID)
            }
        }
        .navigationTitle("Terminal")
        .toolbar {
            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .terminal)
            }

            ToolbarItem(id: "presets", placement: .primaryAction) {
                Menu {
                    Button("New Shell") {
                        shellExited = false
                        pendingCommand = nil
                        sessionID = UUID()
                    }
                    Divider()
                    Button("docker ps") { run("docker ps -a") }
                    Button("container ls") { run("container list -a") }
                    Button("container images") { run("container image list") }
                    Button("kubectl get pods") { run("kubectl get pods -A") }
                } label: {
                    Label("Presets", systemImage: "terminal")
                }
                .labelStyle(.titleAndIcon)
                .help("Run a preset command in the terminal")
                .accessibilityHint("Run a preset command in the terminal")
            }
        }
        .toolbarRole(.editor)
    }

    /// Type a command into the live shell and run it. If the shell already
    /// exited, a new session starts and runs the command as it boots.
    private func run(_ command: String) {
        if shellExited {
            shellExited = false
            pendingCommand = command
            sessionID = UUID()
        } else {
            pendingCommand = command
        }
    }

    private var exitedState: some View {
        ContentUnavailableView {
            Label("Shell Exited", systemImage: "terminal")
        } description: {
            Text("The shell session ended. Start a new one to keep going.")
        } actions: {
            Button("New Shell") {
                shellExited = false
                pendingCommand = nil
                sessionID = UUID()
            }
        }
    }
}
