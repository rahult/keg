import SwiftUI
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class ContainerDetailVM {
    var container: ContainerSnapshot?
    var stats: ContainerStats?
    var isLoading = false
    var errorMessage: String?

    private let client = ContainerClient()
    private var statsTask: Task<Void, Never>?
    private var onStatsUpdate: ((ContainerStats) -> Void)?

    var id: String

    init(id: String) {
        self.id = id
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            container = try await client.get(id: id)
            stats = try? await client.stats(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startStatsPolling(onUpdate: ((ContainerStats) -> Void)? = nil) {
        onStatsUpdate = onUpdate
        statsTask = Task {
            while !Task.isCancelled {
                do {
                    stats = try await client.stats(id: id)
                onStatsUpdate?(stats!)
                } catch {
                    break
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopStatsPolling() {
        statsTask?.cancel()
        statsTask = nil
    }

    func stop() async {
        do {
            try await client.stop(id: id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete() async {
        do {
            try await client.delete(id: id, force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContainerDetailView: View {
    let containerID: String
    @State private var vm: ContainerDetailVM
    @State private var metricsVM = MetricsHistoryVM()

    init(containerID: String) {
        self.containerID = containerID
        self._vm = State(wrappedValue: ContainerDetailVM(id: containerID))
    }

    var body: some View {
        if let container = vm.container {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header
                    HStack {
                        StatusBadge(status: container.status.rawValue)
                        Text(String(container.id.prefix(12)))
                            .font(.title3.monospaced())
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(container.id, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        Spacer()
                        if container.status == .running {
                            Button("Stop") { Task { await vm.stop() } }
                                .controlSize(.small)
                        }
                        Button("Delete", role: .destructive) { Task { await vm.delete() } }
                            .controlSize(.small)
                    }

                    Divider()

                    // Config
                    DetailRow(label: "Image", value: container.configuration.image.reference)
                    DetailRow(label: "Platform", value: "\(container.configuration.platform.os)/\(container.configuration.platform.architecture)")
                    DetailRow(label: "CPUs", value: "\(container.configuration.resources.cpus)")
                    DetailRow(label: "Memory", value: ByteCountFormatter.string(fromByteCount: Int64(container.configuration.resources.memoryInBytes), countStyle: .memory))
                    if let date = container.startedDate {
                        DetailRow(label: "Started", value: date.formatted())
                    }
                    let ip = container.networks.map(\.ipv4Address.description).joined(separator: ", ")
                    if !ip.isEmpty {
                        DetailRow(label: "IP", value: ip)
                    }
                    if !container.configuration.publishedPorts.isEmpty {
                        DetailRow(label: "Ports", value: container.configuration.publishedPorts.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", "))
                    }
                    if !container.configuration.initProcess.environment.filter({ !$0.hasPrefix("PATH=") }).isEmpty {
                        let envStr = container.configuration.initProcess.environment
                            .filter { !$0.hasPrefix("PATH=") }
                            .joined(separator: "\n")
                        DetailRow(label: "Env", value: envStr)
                    }

                    // Live metrics
                    Divider()
                    Text("Resource Usage")
                        .font(.headline)

                    MetricsTimelineView(
                        title: "CPU",
                        points: metricsVM.cpuHistory,
                        color: .blue,
                        unit: "%"
                    )

                    MetricsTimelineView(
                        title: "Memory",
                        points: metricsVM.memoryHistory,
                        color: .green,
                        unit: "%"
                    )

                    MetricsTimelineView(
                        title: "Network RX",
                        points: metricsVM.networkRxHistory,
                        color: .purple,
                        unit: "bps"
                    )

                    MetricsTimelineView(
                        title: "Network TX",
                        points: metricsVM.networkTxHistory,
                        color: .orange,
                        unit: "bps"
                    )
                }
                .padding(16)
            }
            .inspectorColumnWidth(min: 280, ideal: 320)
            .task {
                await vm.load()
                vm.startStatsPolling { stats in
                    metricsVM.addSample(stats: stats)
                }
            }
            .onDisappear {
                vm.stopStatsPolling()
            }
        } else {
            ProgressView("Loading...")
                .task { await vm.load() }
        }
    }

    private func cpuString(_ stats: ContainerStats) -> String {
        if let usage = stats.cpuUsageUsec {
            let seconds = Double(usage) / 1_000_000
            return String(format: "%.1f s", seconds)
        }
        return "--"
    }

    private func memString(_ stats: ContainerStats) -> String {
        let used = stats.memoryUsageBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "--"
        let limit = stats.memoryLimitBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "--"
        return "\(used) / \(limit)"
    }

    private func netString(_ stats: ContainerStats) -> String {
        let rx = stats.networkRxBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        let tx = stats.networkTxBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        return "↓\(rx) ↑\(tx)"
    }

    private func blockString(_ stats: ContainerStats) -> String {
        let read = stats.blockReadBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        let write = stats.blockWriteBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        return "R:\(read) W:\(write)"
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
