import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with status
            HStack {
                statusCircle
                Text(statusText)
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Quick actions
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

                Button("Open Keg") {
                    openWindow(id: "main")
                }
                .controlSize(.small)
            }

            if appState.isSystemRunning {
                Divider()
                runningContainersSection
            }
        }
        .padding(12)
        .frame(width: 280)
        .task {
            await appState.checkSystemStatus()
        }
    }

    private var statusCircle: some View {
        Circle()
            .fill(appState.isSystemRunning ? Color.green : Color.red)
            .frame(width: 10, height: 10)
    }

    private var statusText: String {
        switch appState.systemStatus {
        case .running: return "Container System Running"
        case .stopped: return "Container System Stopped"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var runningContainersSection: some View {
        Group {
            Text("Running Containers")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // TODO: Add running containers list when ContainersVM is connected
            Text("No containers running")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
