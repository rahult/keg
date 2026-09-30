import AppKit
import SwiftUI

/// Settings → Apple Containers: the container CLI, the system status card,
/// the data location, the boot kernel, and platform defaults. The runtime
/// pane — status sits on top.
struct AppleContainersSettingsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Container CLI", caption: "Keg needs Apple's container CLI to manage containers, images, and Kubernetes.") {
                ContainerCLIStatusRow()
                if !ContainerCLI.isInstalled {
                    PlatformSetupCard()
                }
            }

            SettingsGroup("Container System", caption: "The Apple container runtime — one lightweight VM per container. Start and stop it here; lists stay empty while it's off.") {
                systemStatusCard
                ContainerDataLocationRow()
                BootKernelStatusCard()
            }

            PlatformSettingsSection()
        }
    }

    @ViewBuilder
    private var systemStatusCard: some View {
        switch appState.systemStatus {
        case .running(let health):
            SettingsStatusCard(.ok, title: "Running") {
                SettingsCaption("Version: \(health.apiServerVersion)")
                SettingsCaption("Build: \(health.apiServerBuild)")
            } headerAction: {
                Button("Stop System") {
                    Task { await appState.stopSystem() }
                }
                .controlSize(.small)
            }

        case .stopped:
            SettingsStatusCard(.stopped, title: "Stopped", detail: { EmptyView() }, headerAction: {
                Button("Start System") {
                    Task { await appState.startSystem() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            })

        case .unresponsive:
            SettingsStatusCard(.warning, title: "Unresponsive") {
                SettingsCaption("Services are running but not answering. Lists will stay empty until it recovers.")
            } headerAction: {
                Button("Restart Services") {
                    Task {
                        await appState.stopSystem()
                        await appState.startSystem()
                    }
                }
                .controlSize(.small)
            }

        case .error(let message):
            SettingsStatusCard(.warning, title: "Error") {
                SettingsCaption(message)
            } headerAction: {
                Button("Retry") {
                    Task { await appState.startSystem() }
                }
                .controlSize(.small)
            }
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
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsStatusCard(
                resolvedPath != nil ? .ok : .stopped,
                title: resolvedPath != nil ? "Installed" : "Not Installed"
            ) {
                if let path = resolvedPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    SettingsCaption("Keg needs Apple's container CLI to manage containers, images, and Kubernetes.")
                }
            } headerAction: {
                Button("Re-check") { resolvedPath = ContainerCLI.resolve() }
                    .controlSize(.small)
            }

            if resolvedPath == nil {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsCopyLine(value: brewCommand, accessibilityLabel: "Copy install command")
                        HStack(spacing: 8) {
                            Button("Open in Terminal") { runBrewInstall() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("Download from GitHub") { NSWorkspace.shared.open(releasesURL) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
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

/// Configures where the container runtime stores its data (the app-root
/// passed to `container system start`). Machine-specific: most installs stay
/// on the default `~/.container`, others keep it on a dedicated volume.
private struct ContainerDataLocationRow: View {
    @Environment(AppState.self) private var appState
    @AppStorage(ContainerCLI.appRootDefaultsKey) private var path = ""
    @State private var problem: String? = ContainerCLI.appRootProblem()

    private var isDefault: Bool {
        path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The path in effect right now: the configured override with ~ expanded,
    /// or the platform default when nothing is set.
    private var effectivePath: String {
        NSString(string: isDefault ? "~/.container" : path).expandingTildeInPath
    }

    /// The runtime answering with a different root than configured means the
    /// setting won't take effect until services restart.
    private var runningRootMismatch: String? {
        guard let configured = ContainerCLI.configuredAppRoot,
              let running = appState.lastKnownRuntimeAppRoot,
              running != configured else { return nil }
        return "Running runtime uses \(running) — restart services to apply \(configured)."
    }

    var body: some View {
        SettingsCard {
            VStack(spacing: 0) {
                SettingsValueRow("Data location", isLast: true) {
                    HStack(spacing: 8) {
                        Text(effectivePath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: 180)
                        if isDefault {
                            Text("default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Button("Browse…") { browse() }
                            .controlSize(.small)
                        if !isDefault {
                            Button("Reset") {
                                path = ""
                                problem = ContainerCLI.appRootProblem()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            if isDefault {
                SettingsCaption("Where the runtime keeps containers, images, and volumes. Using the platform default — pick a custom folder (for example a dedicated volume) with Browse.")
            } else {
                SettingsCaption("Where the runtime keeps containers, images, and volumes. Change it while the system is stopped, then use Start System.")
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let runningRootMismatch {
                Text(runningRootMismatch)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = "Choose Container Data Location"
        panel.message = "This folder will hold the runtime's containers, images, volumes, and snapshots."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // Start inside the current location when it exists, otherwise fall
        // back to the containing volume or home.
        var start = URL(fileURLWithPath: effectivePath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: start.path) {
            start = URL(filePath: NSHomeDirectory())
        }
        panel.directoryURL = start
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            path = url.path
            problem = ContainerCLI.appRootProblem()
        }
    }
}
