import SwiftUI
import ContainerAPIClient
import ContainerResource

// MARK: - View Model

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

    init(id: String) { self.id = id }

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
                    let newStats = try await client.stats(id: id)
                    stats = newStats
                    onStatsUpdate?(newStats)
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

    /// `ContainerClient` doesn't expose a `start(id:)`, so shell out to the CLI.
    /// This path is only hit when resuming a previously-stopped container.
    func start() async {
        do {
            let (code, out) = try await ContainerCLI.run(["container", "start", id])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to start container" : out
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restart() async {
        do {
            let (stopCode, stopOut) = try await ContainerCLI.run(["container", "stop", id])
            if stopCode != 0 {
                errorMessage = stopOut.isEmpty ? "Failed to stop container" : stopOut
                await load()
                return
            }
            let (code, out) = try await ContainerCLI.run(["container", "start", id])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to restart container" : out
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        do {
            let (code, out) = try await ContainerCLI.run(["container", "stop", id])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to stop container" : out
            }
            await load()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func delete() async {
        do { try await client.delete(id: id, force: true) }
        catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Tabs

enum ContainerDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case environment = "Environment"
    case mounts = "Mounts"
    case files = "Files"
    case logs = "Logs"
    case stats = "Stats"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .overview:    return "info.circle"
        case .environment: return "text.word.spacing"
        case .mounts:      return "externaldrive"
        case .files:       return "folder"
        case .logs:        return "terminal"
        case .stats:       return "waveform.path.ecg"
        }
    }
}

// MARK: - Detail View

struct ContainerDetailView: View {
    let containerID: String
    @State private var vm: ContainerDetailVM
    @State private var metricsVM = MetricsHistoryVM()
    @State private var selectedTab: ContainerDetailTab = .overview
    @State private var showRecreate = false
    @State private var showDeleteConfirmation = false

    init(containerID: String) {
        self.containerID = containerID
        self._vm = State(wrappedValue: ContainerDetailVM(id: containerID))
    }

    var body: some View {
        Group {
            if let container = vm.container {
                VStack(spacing: 0) {
                    DetailHeader(
                        displayName(container),
                        subtitle: container.configuration.image.reference,
                        statusLabel: container.status.rawValue
                    ) {
                        headerActions(container)
                    }

                    Picker(selection: $selectedTab) {
                        ForEach(ContainerDetailTab.allCases) { tab in
                            Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                        }
                    } label: {
                        Label(selectedTab.rawValue, systemImage: selectedTab.systemImage)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    tabContent(container)
                }
                .errorBanner($vm.errorMessage)
                .task {
                    await vm.load()
                    vm.startStatsPolling { stats in
                        metricsVM.addSample(stats: stats)
                    }
                }
                .onDisappear { vm.stopStatsPolling() }
                .sheet(isPresented: $showRecreate) {
                    if let container = vm.container {
                        RecreateContainerView(container: container) {
                            Task { await vm.load() }
                        }
                    }
                }
                .alert("Delete \(displayName(container))?", isPresented: $showDeleteConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        Task { await vm.delete() }
                    }
                } message: {
                    Text("Delete this container. This action cannot be undone.")
                }
            } else {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await vm.load() }
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ container: ContainerSnapshot) -> some View {
        switch selectedTab {
        case .overview:    OverviewTab(container: container, stats: vm.stats, metrics: metricsVM)
        case .environment: EnvironmentTab(container: container)
        case .mounts:      MountsTab(container: container)
        case .files:
            if container.status == .running {
                ContainerFilesView(containerID: container.id)
            } else {
                EmptyState(
                    "Container Not Running",
                    description: "Start the container to browse its filesystem.",
                    systemImage: "folder"
                )
            }
        case .logs:        LogsTab(containerID: container.id)
        case .stats:       StatsTab(metrics: metricsVM)
        }
    }

    @ViewBuilder
    private func headerActions(_ container: ContainerSnapshot) -> some View {
        if container.status == .running {
            Button("Stop") { Task { await vm.stop() } }
            Button("Restart") { Task { await vm.restart() } }
            Button {
                TerminalLauncher.openShell(containerID: container.id)
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
        } else {
            Button("Start") { Task { await vm.start() } }
                .buttonStyle(.borderedProminent)
        }
        Button {
            showRecreate = true
        } label: {
            Label("Edit & Recreate", systemImage: "square.and.pencil")
        }
        .labelStyle(.iconOnly)
        .help("Edit & Recreate…")
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Delete container")
    }

    private func displayName(_ container: ContainerSnapshot) -> String {
        if let name = container.configuration.labels["name"], !name.isEmpty {
            return name
        }
        return String(container.id.prefix(12))
    }
}

// MARK: - Overview Tab

private struct OverviewTab: View {
    let container: ContainerSnapshot
    let stats: ContainerStats?
    let metrics: MetricsHistoryVM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Statistics row
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatCard(
                        icon: "memorychip",
                        value: memoryValue,
                        label: "Memory",
                        tint: .green
                    )
                    StatCard(
                        icon: "network",
                        value: networkValue,
                        label: "Network I/O",
                        tint: .purple
                    )
                    StatCard(
                        icon: "externaldrive.connected.to.line.below",
                        value: blockValue,
                        label: "Block I/O",
                        tint: .orange
                    )
                    StatCard(
                        icon: "cpu",
                        value: cpuValue,
                        label: "CPU",
                        tint: .blue
                    )
                }

                // Sections — single column so rows stay readable at inspector widths
                VStack(alignment: .leading, spacing: 16) {
                    SectionGrid("Overview", rows: overviewRows)
                    SectionGrid("Image", rows: imageRows)
                    SectionGrid("Network", rows: networkRows)
                    SectionGrid("Resources", rows: resourceRows)
                    SectionGrid("Process Configuration", rows: processRows)
                }
            }
            .padding(20)
        }
    }

    // MARK: stat values

    private var memoryValue: String {
        guard let used = stats?.memoryUsageBytes else {
            return ByteCountFormatter.string(fromByteCount: Int64(container.configuration.resources.memoryInBytes), countStyle: .memory)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)
    }
    private var networkValue: String {
        let rx = stats?.networkRxBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        let tx = stats?.networkTxBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        return "↓\(rx) ↑\(tx)"
    }
    private var blockValue: String {
        let r = stats?.blockReadBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        let w = stats?.blockWriteBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "--"
        return "R:\(r) W:\(w)"
    }
    private var cpuValue: String {
        if let delta = metrics.cpuDelta {
            return String(format: "%.0f%%", delta)
        }
        return "\(container.configuration.resources.cpus) cores"
    }

    // MARK: rows

    private var overviewRows: [SectionGrid.Row] {
        var rows: [SectionGrid.Row] = [
            .init("Container ID", container.id, copyable: true),
            .init("Runtime", container.configuration.runtimeHandler),
            .init("Platform", "\(container.configuration.platform.os)/\(container.configuration.platform.architecture)")
        ]
        if let started = container.startedDate {
            rows.append(.init("Started", started.formatted(date: .abbreviated, time: .shortened), monospaced: false))
        }
        return rows
    }

    private var imageRows: [SectionGrid.Row] {
        [
            .init("Reference", container.configuration.image.reference, copyable: true),
            .init("Status", container.status.rawValue, monospaced: false)
        ]
    }

    private var networkRows: [SectionGrid.Row] {
        var rows: [SectionGrid.Row] = []
        if let net = container.networks.first {
            rows.append(.init("Address", net.ipv4Address.description, copyable: true))
            rows.append(.init("Gateway", net.ipv4Gateway.description))
            rows.append(.init("Network", net.network))
        }
        let ports = container.configuration.publishedPorts
            .map { "\($0.hostPort):\($0.containerPort)" }
            .joined(separator: ", ")
        rows.append(.init("Published Ports", ports.isEmpty ? "None configured" : ports, copyable: !ports.isEmpty))
        return rows
    }

    private var resourceRows: [SectionGrid.Row] {
        [
            .init("CPUs", "\(container.configuration.resources.cpus)"),
            .init("Memory", ByteCountFormatter.string(fromByteCount: Int64(container.configuration.resources.memoryInBytes), countStyle: .memory)),
            .init("Rosetta", container.configuration.rosetta ? "Enabled" : "Disabled", monospaced: false)
        ]
    }

    private var processRows: [SectionGrid.Row] {
        let proc = container.configuration.initProcess
        let args = proc.arguments.joined(separator: " ")
        return [
            .init("Executable", proc.executable, copyable: true),
            .init("Working Directory", proc.workingDirectory.isEmpty ? "/" : proc.workingDirectory),
            .init("Terminal", proc.terminal ? "Enabled" : "Disabled", monospaced: false),
            .init("Arguments", args.isEmpty ? "—" : args, copyable: !args.isEmpty)
        ]
    }
}

// MARK: - Environment Tab

private struct EnvironmentTab: View {
    let container: ContainerSnapshot
    @State private var search = ""

    private var entries: [EnvEntry] {
        container.configuration.initProcess.environment
            .map(EnvEntry.init)
            .filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if container.configuration.initProcess.environment.isEmpty {
                EmptyState(
                    "No Environment Variables",
                    description: "This container doesn't declare any environment variables.",
                    systemImage: "text.word.spacing"
                )
            } else {
                Table(entries) {
                    TableColumn("Key") { entry in
                        Text(entry.key)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 160, ideal: 220)
                    TableColumn("Value") { entry in
                        EnvValueCell(entry: entry)
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .searchable(text: $search, prompt: "Search variables")
            }
        }
    }

    private struct EnvValueCell: View {
        let entry: EnvEntry
        @State private var isHovered = false

        var body: some View {
            HStack(spacing: 4) {
                Text(entry.value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(entry.key)=\(entry.value)", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .opacity(isHovered ? 1 : 0)
                .accessibilityLabel("Copy \(entry.key)")
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
        }
    }

    private struct EnvEntry: Identifiable {
        let id = UUID()
        let key: String
        let value: String

        init(_ raw: String) {
            if let eq = raw.firstIndex(of: "=") {
                self.key = String(raw[..<eq])
                self.value = String(raw[raw.index(after: eq)...])
            } else {
                self.key = raw
                self.value = ""
            }
        }
    }
}

// MARK: - Mounts Tab

private struct MountsTab: View {
    let container: ContainerSnapshot

    private var rows: [MountRow] {
        container.configuration.mounts.map { MountRow(mount: $0) }
    }

    var body: some View {
        if rows.isEmpty {
            EmptyState(
                "No Mounts",
                description: "This container doesn't have any bind mounts or volumes attached.",
                systemImage: "externaldrive"
            )
        } else {
            Table(rows) {
                TableColumn("Source") { row in
                    Text(row.source)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Destination") { row in
                    Text(row.destination)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                TableColumn("Type") { row in
                    Text(row.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, max: 120)
                TableColumn("Options") { row in
                    Text(row.options)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
        }
    }

    private struct MountRow: Identifiable {
        let id = UUID()
        let source: String
        let destination: String
        let kind: String
        let options: String

        init(mount: Filesystem) {
            self.source = mount.source
            self.destination = mount.destination
            self.kind = Self.kindString(mount.type)
            self.options = mount.options.joined(separator: ", ")
        }

        private static func kindString(_ type: Filesystem.FSType) -> String {
            switch type {
            case .block:    return "block"
            case .volume:   return "volume"
            case .virtiofs: return "virtiofs"
            case .tmpfs:    return "tmpfs"
            }
        }
    }
}

// MARK: - Logs Tab

private struct LogsTab: View {
    let containerID: String

    var body: some View {
        ContainerLogsView(containerID: containerID)
    }
}

// MARK: - Stats Tab

private struct StatsTab: View {
    let metrics: MetricsHistoryVM

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MetricsTimelineView(title: "CPU Time", points: metrics.cpuHistory, color: .blue, unit: "s")
                MetricsTimelineView(title: "Memory", points: metrics.memoryHistory, color: .green, unit: "%")
                MetricsTimelineView(title: "Network RX", points: metrics.networkRxHistory, color: .purple, unit: "bps")
                MetricsTimelineView(title: "Network TX", points: metrics.networkTxHistory, color: .orange, unit: "bps")
            }
            .padding(20)
        }
    }
}

// MARK: - Shared row

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
        }
    }
}
