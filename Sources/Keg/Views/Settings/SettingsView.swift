import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Container CLI") {
                ContainerCLIStatusRow()
            }

            Section("Container System") {
                HStack {
                    switch appState.systemStatus {
                    case .running(let health):
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Running")
                                .font(.headline)
                            Text("Version: \(health.apiServerVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Build: \(health.apiServerBuild)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop System") {
                            Task { await appState.stopSystem() }
                        }
                        .controlSize(.small)

                    case .stopped:
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("Stopped")
                            .font(.headline)
                        Spacer()
                        Button("Start System") {
                            Task { await appState.startSystem() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    case .error(let message):
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Error")
                                .font(.headline)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry") {
                            Task { await appState.startSystem() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Docker API") {
                HStack {
                    Circle()
                        .fill(appState.isDockerAPIRunning ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading) {
                        Text(appState.isDockerAPIRunning ? "Running" : "Stopped")
                            .font(.headline)
                        HStack(spacing: 4) {
                            Text(appState.dockerSocketPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(appState.dockerSocketPath, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Copy socket path")
                        }
                        HStack(spacing: 4) {
                            Text("export DOCKER_HOST=unix://\(appState.dockerSocketPath)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                            Button {
                                let command = "export DOCKER_HOST=unix://\(appState.dockerSocketPath)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .accessibilityLabel("Copy DOCKER_HOST command")
                        }
                    }
                    Spacer()
                    if appState.isDockerAPIRunning {
                        Button("Stop") { appState.stopDockerAPI() }
                            .controlSize(.small)
                    } else {
                        Button("Start") { appState.startDockerAPI() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }

                @Bindable var state = appState
                Toggle("Start Docker API automatically", isOn: $state.dockerAPIAutoStart)
                Text("Enables Docker CLI compatibility via Unix socket")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("App", value: "Keg")
                LabeledContent("Description", value: "Docker Desktop replacement for macOS — native containers, Docker API, Compose, and Kubernetes")
                LabeledContent("Runtime", value: "Apple Containerization")
                LabeledContent("Requirements", value: "macOS 26+, Apple Silicon, Apple container CLI")
                LabeledContent("License", value: "Apache 2.0")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .task {
            await appState.checkSystemStatus()
        }
    }
}

/// Detection + install flow for Apple's `container` CLI. Refreshes whenever the
/// Settings pane becomes active so users see the updated state after an install.
private struct ContainerCLIStatusRow: View {
    @State private var resolvedPath: String? = ContainerCLI.resolve()

    private let brewCommand = "brew install container"
    private let releasesURL = URL(string: "https://github.com/apple/container/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(resolvedPath != nil ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolvedPath != nil ? "Installed" : "Not Installed")
                        .font(.headline)
                    if let path = resolvedPath {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Text("Keg needs Apple's container CLI to manage containers, images, and Kubernetes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Re-check") { resolvedPath = ContainerCLI.resolve() }
                    .controlSize(.small)
            }

            if resolvedPath == nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text(brewCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(brewCommand, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Copy install command")
                    }
                    HStack(spacing: 8) {
                        Button("Open in Terminal") { runBrewInstall() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Download from GitHub") { NSWorkspace.shared.open(releasesURL) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }

    /// Open Terminal.app and prefill the brew install command. We don't run it
    /// directly because installing CLIs with sudo from a GUI app is hostile —
    /// the user should see what's being run and approve it themselves.
    private func runBrewInstall() {
        let script = "tell application \"Terminal\" to do script \"\(brewCommand)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
