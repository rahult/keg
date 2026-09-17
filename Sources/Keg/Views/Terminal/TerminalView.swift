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

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { _ in
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

            HStack(spacing: 8) {
                Text("$")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)

                TextField("Enter command", text: $input)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
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
                startShell()
            }
        }
        .onDisappear {
            process?.terminate()
        }
    }

    private func startShell() {
        let shell = Process()
        let outPipe = Pipe()
        let inPipe = Pipe()

        shell.executableURL = URL(filePath: "/bin/zsh")
        shell.arguments = ["-l"]
        shell.standardOutput = outPipe
        shell.standardError = outPipe
        shell.standardInput = inPipe
        shell.environment = ProcessInfo.processInfo.environment

        // Detach the handler as soon as the child closes stdout. Without this
        // self-heal, after the shell exits macOS keeps firing the handler on
        // an empty pipe and availableData becomes a busy spin on EOF reads —
        // ~50% CPU per leaked handler on the fd_monitoring dispatch queue.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8) {
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
            output += "Keg Terminal — shell ready\n\n"
        } catch {
            output += "Failed to start shell: \(error.localizedDescription)\n"
        }
    }

    private func runCommand(_ cmd: String) {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        output += "$ \(trimmed)\n"

        if let pipe = inputPipe, process?.isRunning == true {
            guard let data = (trimmed + "\n").data(using: .utf8) else { return }
            pipe.fileHandleForWriting.write(data)
            return
        }

        let proc = Process()
        let outPipe = Pipe()

        proc.executableURL = URL(filePath: "/bin/zsh")
        proc.arguments = ["-c", trimmed]
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.environment = ProcessInfo.processInfo.environment

        // Same self-heal as startShell() — see comment there.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let str = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    output += str
                }
            }
        }

        isRunning = true
        do {
            try proc.run()
            process = proc

            Task.detached {
                proc.waitUntilExit()
                // Clear the handler before readDataToEndOfFile to avoid the
                // handler racing with the manual read and double-reporting.
                outPipe.fileHandleForReading.readabilityHandler = nil
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
            output += "\(error.localizedDescription)\n\n"
            isRunning = false
        }
    }
}

// MARK: - Quick Terminal View

struct QuickTerminalView: View {
    @State private var selectedCommand: TerminalPreset = .shell

    var body: some View {
        TerminalView(command: selectedCommand.command)
            .id(selectedCommand.id)
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(id: "help", placement: .automatic) {
                    SectionHelpButton(section: .terminal)
                }

                ToolbarItem(id: "presets", placement: .primaryAction) {
                    Menu {
                        Button("Shell") { selectedCommand = .shell }
                        Divider()
                        Button("docker ps") { selectedCommand = .dockerPS }
                        Button("container ls") { selectedCommand = .containerList }
                        Button("container images") { selectedCommand = .containerImages }
                        Button("kubectl get pods") { selectedCommand = .kubectlPods }
                    } label: {
                        Label("Presets", systemImage: "terminal")
                    }
                    .accessibilityHint("Run a preset command in a fresh terminal")
                }
            }
            .toolbarRole(.editor)
    }
}

private enum TerminalPreset: String, Identifiable {
    case shell
    case dockerPS
    case containerList
    case containerImages
    case kubectlPods

    var id: String { rawValue }

    var command: String? {
        switch self {
        case .shell:
            return nil
        case .dockerPS:
            return "export DOCKER_HOST=unix://\(NSHomeDirectory())/.keg/docker.sock && docker ps -a"
        case .containerList:
            return "container list -a"
        case .containerImages:
            return "container image list"
        case .kubectlPods:
            return "export KUBECONFIG=\"\(NSHomeDirectory())/.keg/kubeconfig\" && kubectl get pods -A"
        }
    }
}
