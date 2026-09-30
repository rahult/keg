import AppKit
import SwiftUI

/// Kubernetes cluster summary for Settings: whether the `keg-k8s` cluster
/// container exists and runs, where its kubeconfig lives, and start/stop for
/// the common cases. Full lifecycle (create, bootstrap, delete) stays in the
/// Kubernetes section of the main window, where the bootstrap output is
/// visible.
struct KubernetesSettingsSection: View {
    @State private var status: Status = .checking
    @State private var isWorking = false
    @State private var errorMessage: String?

    enum Status { case checking, absent, running, stopped }

    private let clusterID = "keg-k8s"
    private var kubeconfigPath: String {
        NSString(string: "~/.keg/kubeconfig").expandingTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            statusView

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsValueRow("Cluster container") {
                        SettingsCopyLine(value: clusterID, accessibilityLabel: "Copy cluster container name")
                    }
                    SettingsValueRow("Kubeconfig", description: "Point kubectl here with export KUBECONFIG.", isLast: true) {
                        SettingsCopyLine(value: kubeconfigPath, accessibilityLabel: "Copy kubeconfig path")
                    }
                }
            }

            switch status {
            case .absent:
                Label("No cluster yet — create one from the Kubernetes section in the sidebar.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .stopped:
                SettingsCaption("The cluster container exists but isn't running. Start it to use `kubectl` against it.")
            case .running, .checking:
                EmptyView()
            }

            HStack(spacing: 12) {
                Button {
                    Task { await control("start") }
                } label: {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text("Start Cluster")
                }
                .disabled(status != .stopped || isWorking)

                Button("Stop Cluster") {
                    Task { await control("stop") }
                }
                .disabled(status != .running || isWorking)
            }
            .controlSize(.small)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            SettingsCaption("Deleting the cluster (container and kubeconfig) is done from the Kubernetes section in the sidebar, where the bootstrap output is visible.")
        }
        .padding(.vertical, 4)
        .task { await refresh() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .checking:
            // Still probing the runtime — a spinner, not a state dot.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking cluster…")
                    .font(.headline)
            }
        case .absent:
            SettingsStatusCard(.inactive, title: "No cluster", headerAction: { refreshButton })
        case .running:
            SettingsStatusCard(.ok, title: "Cluster running", headerAction: { refreshButton })
        case .stopped:
            SettingsStatusCard(.warning, title: "Cluster stopped", headerAction: { refreshButton })
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
    }

    private func refresh() async {
        status = .checking
        do {
            let (code, output) = try await ContainerCLI.run(
                ["container", "ls", "-a", "--format", "json"], timeout: .seconds(15))
            guard code == 0,
                  let data = output.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                errorMessage = output.isEmpty ? "Failed to list containers" : output
                status = .absent
                return
            }
            let entry = entries.first { ($0["id"] as? String) == clusterID }
            switch (entry?["status"] as? String)?.lowercased() {
            case "running": status = .running
            case .some: status = .stopped
            case .none: status = .absent
            }
            errorMessage = nil
        } catch {
            errorMessage = "Runtime unreachable: \(error.localizedDescription)"
            status = .absent
        }
    }

    private func control(_ action: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let (code, output) = try await ContainerCLI.run(
                ["container", action, clusterID], timeout: .seconds(300))
            if code != 0 {
                errorMessage = output.isEmpty ? "container \(action) failed" : output
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}
