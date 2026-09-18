import AppKit
import SwiftUI

/// Copies the container-runtime triage bundle (data location, live container
/// processes, launchd service states, recent CLI calls) to the clipboard.
struct CopyDiagnosticsButton: View {
    var label = "Copy Diagnostics"
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : label) {
            Task { @MainActor in
                let report = await ContainerCLI.diagnosticsReport()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                copied = true
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
        .controlSize(.small)
    }
}

/// Shown when the container runtime's services are alive but not answering.
/// The point is recovery and diagnosis in one place: retry, restart the
/// services, or copy a triage bundle instead of staring at a stuck spinner.
struct RuntimeUnresponsiveBanner: View {
    @Environment(AppState.self) private var appState
    @State private var restarting = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Container runtime is unresponsive")
                    .font(.headline)
                Text("Its services are running but not answering. Lists stay empty and operations will time out until it recovers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Retry") {
                Task { await appState.refreshMetrics() }
            }
            .controlSize(.small)

            Button(restarting ? "Restarting…" : "Restart Services") {
                restarting = true
                Task {
                    await appState.stopSystem()
                    await appState.startSystem()
                    restarting = false
                }
            }
            .controlSize(.small)
            .disabled(restarting)

            CopyDiagnosticsButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}
