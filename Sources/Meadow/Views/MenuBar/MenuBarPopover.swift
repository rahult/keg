import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection

            Divider()

            quickActionsSection

            if appState.isSystemRunning {
                Divider()
                runningContainersSection
            }

            Divider()

            dockerAPISection
        }
        .padding(12)
        .frame(width: 340)
        .task {
            await appState.checkSystemStatus()
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            statusCircle

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.headline)
                Text(containerCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var quickActionsSection: some View {
        HStack(spacing: 8) {
            if appState.isSystemRunning {
                Button("Stop") {
                    Task { await appState.stopSystem() }
                }
                .controlSize(.small)
            } else {
                Button("Start") {
                    Task { await appState.startSystem() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            Button("Open Meadow") {
                openWindow(id: "main")
            }
            .controlSize(.small)

            Button("Settings") {
                appState.openSettings()
            }
            .controlSize(.small)
        }
    }

    private var statusCircle: some View {
        Circle()
            .fill(appState.isSystemRunning ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }

    private var statusText: String {
        switch appState.systemStatus {
        case .running:
            return "Container System Running"
        case .stopped:
            return "Container System Stopped"
        case .error(let msg):
            return msg
        }
    }

    private var containerCountText: String {
        let running = appState.runningContainerCount
        if running == 0 { return "No running containers" }
        return running == 1 ? "1 running container" : "\(running) running containers"
    }

    private var runningContainersSection: some View {
        Group {
            Text("Quick Access")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "terminal")
                        .frame(width: 16)
                    Text("Terminal")
                        .font(.caption)
                    Spacer()
                }
                HStack {
                    Image(systemName: "cube.box")
                        .frame(width: 16)
                    Text("Containers")
                        .font(.caption)
                    Spacer()
                }
            }
        }
    }

    private var dockerAPISection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Docker API")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.isDockerAPIRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(appState.isDockerAPIRunning ? "Running" : "Stopped")
                    .font(.caption)
                Spacer()
                if appState.isDockerAPIRunning {
                    Button("Stop") { appState.stopDockerAPI() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.caption)
                } else {
                    Button("Start") { appState.startDockerAPI() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.caption)
                }
            }

            if appState.isDockerAPIRunning {
                Text(appState.dockerSocketPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
