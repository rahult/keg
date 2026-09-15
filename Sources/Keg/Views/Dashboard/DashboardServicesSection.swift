import SwiftUI
import ContainerResource

// MARK: - Disk Usage

struct DiskUsageRow: Identifiable, Sendable {
    let id: String
    let type: String
    let total: String
    let active: String
    let size: String
    let reclaimable: String
}

@Observable
@MainActor
final class DiskUsageVM {
    var rows: [DiskUsageRow] = []
    var errorMessage: String?

    func refresh() async {
        do {
            let (code, output) = try await ContainerCLI.run(["container", "system", "df"])
            guard code == 0 else {
                errorMessage = output
                return
            }
            rows = Self.parse(output)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parses `container system df` table. The reclaimable column ends with a
    /// parenthesized percentage, so fields are consumed right-to-left and the
    /// type keeps any internal spaces ("Local Volumes").
    nonisolated static func parse(_ output: String) -> [DiskUsageRow] {
        var rows: [DiskUsageRow] = []
        for line in output.split(separator: "\n").dropFirst() {
            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 7 else { continue }
            let percent = fields.removeLast()            // (100%)
            let reclaimUnit = fields.removeLast()        // GB
            let reclaimable = fields.removeLast()        // e.g. 4.08
            let sizeUnit = fields.removeLast()           // GB
            let size = fields.removeLast()               // e.g. 4.08
            let active = fields.removeLast()
            let total = fields.removeLast()
            let type = fields.joined(separator: " ")
            rows.append(DiskUsageRow(
                id: type,
                type: type,
                total: total,
                active: active,
                size: "\(size) \(sizeUnit)",
                reclaimable: "\(reclaimable) \(reclaimUnit) \(percent)"
            ))
        }
        return rows
    }
}

/// Disk usage across images, containers, and volumes (Davit's "disk usage"
/// dashboard card, as a live section).
struct DiskUsageSection: View {
    @State private var vm = DiskUsageVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Disk Usage")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .labelStyle(.iconOnly)
            }

            if vm.rows.isEmpty {
                if let error = vm.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Total").font(.caption).foregroundStyle(.secondary)
                        Text("Active").font(.caption).foregroundStyle(.secondary)
                        Text("Size").font(.caption).foregroundStyle(.secondary)
                        Text("Reclaimable").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(vm.rows) { row in
                        GridRow {
                            Label(row.type, systemImage: icon(for: row.type))
                                .font(.body)
                            Text(row.total).font(.body.monospacedDigit())
                            Text(row.active).font(.body.monospacedDigit())
                            Text(row.size).font(.body.monospacedDigit())
                            Text(row.reclaimable).font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await vm.refresh()
        }
    }

    private func icon(for type: String) -> String {
        if type.contains("Image") { return "photo.stack" }
        if type.contains("Volume") { return "externaldrive" }
        return "cube.box"
    }
}

// MARK: - Running Services (live CPU / memory)

/// Live view of running containers with per-container CPU and memory —
/// Davit's "live CPU across all running containers" dashboard service.
struct RunningServicesSection: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ContainersVM()

    private var running: [ContainerSnapshot] {
        vm.containers.filter { $0.status == .running }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Services")
                    .font(.headline)
                Text("\(running.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .labelStyle(.iconOnly)
            }

            if running.isEmpty {
                Text("No containers running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(running.enumerated()), id: \.element.id) { index, container in
                        if index > 0 { Divider() }
                        serviceRow(container)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await vm.refresh()
            vm.startLiveStats()
        }
        .onDisappear {
            vm.stopLiveStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRefresh)) { _ in
            Task { await vm.refresh() }
        }
    }

    private func serviceRow(_ container: ContainerSnapshot) -> some View {
        let name = container.configuration.labels["name"].flatMap { $0.isEmpty ? nil : $0 }
            ?? String(container.id.prefix(12))
        let image = container.configuration.image.reference
        let metrics = vm.liveMetrics[container.id]

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .lineLimit(1)
                Text(image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                appState.currentArea = .keg
                appState.selectedKegSection = .containers
                appState.selectedContainerID = container.id
            }

            if let metrics {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.0f%% CPU", metrics.cpuPercent))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(metrics.cpuPercent >= 80 ? .red : .primary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(metrics.memoryUsedBytes), countStyle: .memory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 110, alignment: .trailing)
            } else {
                Text("…")
                    .foregroundStyle(.tertiary)
                    .frame(width: 110, alignment: .trailing)
            }

            Button {
                Task { await vm.stop(id: container.id) }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Stop \(name)")
            .accessibilityLabel("Stop \(name)")
        }
        .padding(.vertical, 6)
    }
}
