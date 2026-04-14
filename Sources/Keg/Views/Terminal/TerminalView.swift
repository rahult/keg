import SwiftUI

// MARK: - Terminal View (PTY-backed)

/// A native terminal emulator view that runs a shell inside the app.
/// Uses Process + Pipe for I/O and renders output in a ScrollView.
struct TerminalView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let command: String?
    @State private var output = ""
    @State private var input = ""
    @State private var process: Process?
    @State private var inputPipe: Pipe?
    @State private var isRunning = false
    @State private var scrollTarget: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("terminal-bottom")
                    }
                    .background(Color.black)
                    .onChange(of: output.count) {
                        if reduceMotion {
                            proxy.scrollTo("terminal-bottom", anchor: .bottom)
                        } else {
                            withAnimation {
                                proxy.scrollTo("terminal-bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                Text("$")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)

                TextField("Type a command...", text: $input)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        runCommand(input)
                        input = ""
                    }

                if isRunning {
                    Button("Kill") {
                        process?.terminate()
                        isRunning = false
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            if let cmd = command {
                runCommand(cmd)
            } else {
                // Interactive shell
                startShell()
            }
        }
        .onDisappear {
            process?.terminate()
        }
    }

    // MARK: - Shell

    private func startShell() {
        let shell = Process()
        let outPipe = Pipe()
        let inPipe = Pipe()

        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-l"] // login shell
        shell.standardOutput = outPipe
        shell.standardError = outPipe
        shell.standardInput = inPipe
        shell.environment = ProcessInfo.processInfo.environment

        // Stream output
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    output += str
                }
            }
        }

        do {
            try shell.run()
            process = shell
            inputPipe = inPipe
            isRunning = true
            output += "Keg Terminal — type commands below\n\n"
        } catch {
            output += "Failed to start shell: \(error.localizedDescription)\n"
        }
    }

    // MARK: - Run Command

    private func runCommand(_ cmd: String) {
        guard !cmd.isEmpty else { return }

        output += "$ \(cmd)\n"

        // If we have an interactive shell, send to it
        if let pipe = inputPipe, process?.isRunning == true {
            let data = (cmd + "\n").data(using: .utf8)!
            pipe.fileHandleForWriting.write(data)
            return
        }

        // Otherwise run as a one-shot process
        let proc = Process()
        let outPipe = Pipe()

        proc.executableURL = URL(filePath: "/bin/zsh")
        proc.arguments = ["-c", cmd]
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.environment = ProcessInfo.processInfo.environment

        // Stream output
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    output += str
                }
            }
        }

        isRunning = true
        do {
            try proc.run()
            process = proc

            // Monitor completion
            Task.detached {
                proc.waitUntilExit()
                let remaining = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: remaining, encoding: .utf8), !str.isEmpty {
                    await MainActor.run { output += str }
                }
                await MainActor.run {
                    isRunning = false
                    output += "\n"
                }
            }
        } catch {
            output += "Error: \(error.localizedDescription)\n\n"
            isRunning = false
        }
    }
}

// MARK: - Quick Terminal Tab View

/// A tab-based terminal with preset commands for quick testing
struct QuickTerminalView: View {
    @State private var selectedTab = "shell"
    @State private var customCommand = ""

    var body: some View {
        VStack(spacing: 0) {
            // Quick command bar
            HStack(spacing: 8) {
                Text("▶")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                TextField("Run a command...", text: $customCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !customCommand.isEmpty {
                            selectedTab = "custom-\(customCommand)"
                        }
                    }

                Divider().frame(height: 16)

                // Quick presets
                Button("docker ps") {
                    selectedTab = "docker-ps"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("container ls") {
                    selectedTab = "container-ls"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("container images") {
                    selectedTab = "container-images"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("kubectl") {
                    selectedTab = "kubectl"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Terminal content
            TerminalView(command: commandForTab(selectedTab))
                .id(selectedTab) // Re-create on tab change
        }
        .navigationTitle("Terminal")
    }

    private func commandForTab(_ tab: String) -> String? {
        switch tab {
        case "docker-ps":
            return "export DOCKER_HOST=unix://\(NSHomeDirectory())/.keg/docker.sock && docker ps -a"
        case "container-ls":
            return "container list -a"
        case "container-images":
            return "container image list"
        case "kubectl":
            return "export KUBECONFIG=\"\(NSHomeDirectory())/.keg/kubeconfig\" && kubectl get pods -A"
        default:
            if tab.hasPrefix("custom-") {
                return String(tab.dropFirst(7))
            }
            return nil // Interactive shell
        }
    }
}
