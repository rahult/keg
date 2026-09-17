import SwiftUI

@Observable
@MainActor
final class ComposeVM {
    private static let composeFilePathDefaultsKey = "compose.filePath"
    private static let projectNameDefaultsKey = "compose.projectName"

    var composeFilePath = "" {
        didSet {
            UserDefaults.standard.set(composeFilePath, forKey: Self.composeFilePathDefaultsKey)
        }
    }
    var projectName = "" {
        didSet {
            UserDefaults.standard.set(projectName, forKey: Self.projectNameDefaultsKey)
        }
    }
    var isRunning = false
    var output = ""
    var errorMessage: String?
    var services: [(name: String, service: String, state: String)] = []
    var plan: ComposeOrchestrator.ComposePlan?

    private let orchestrator = ComposeOrchestrator()

    init() {
        composeFilePath = UserDefaults.standard.string(forKey: Self.composeFilePathDefaultsKey) ?? ""
        projectName = UserDefaults.standard.string(forKey: Self.projectNameDefaultsKey) ?? ""
    }

    func up(detached: Bool = true) async {
        guard !composeFilePath.isEmpty else {
            errorMessage = "Select a compose file first"
            return
        }
        isRunning = true
        output = ""
        errorMessage = nil

        do {
            try await orchestrator.up(
                filePath: composeFilePath,
                projectName: projectName.isEmpty ? nil : projectName,
                detached: detached,
                progress: { [self] line in
                    appendOutput(line)
                }
            )
            await refreshPS()
        } catch {
            errorMessage = describe(error)
        }
        isRunning = false
    }

    func down() async {
        guard !composeFilePath.isEmpty else {
            errorMessage = "Select a compose file first"
            return
        }
        isRunning = true
        output = ""
        errorMessage = nil

        do {
            try await orchestrator.down(
                filePath: composeFilePath,
                projectName: projectName.isEmpty ? nil : projectName,
                progress: { [self] line in
                    appendOutput(line)
                }
            )
            services = []
        } catch {
            errorMessage = describe(error)
        }
        isRunning = false
    }

    func refreshPS() async {
        guard !composeFilePath.isEmpty else { return }
        do {
            services = try await orchestrator.ps(
                filePath: composeFilePath,
                projectName: projectName.isEmpty ? nil : projectName
            )
        } catch {
            errorMessage = describe(error)
        }
    }

    func selectComposeFile(_ path: String) async {
        composeFilePath = path
        await refreshPS()
        await refreshPlan()
    }

    /// Recompute the import preview (dependency order, equivalent commands,
    /// warnings) whenever the file or project name changes.
    func refreshPlan() async {
        guard !composeFilePath.isEmpty else {
            plan = nil
            return
        }
        do {
            plan = try await orchestrator.plan(
                filePath: composeFilePath,
                projectName: projectName.isEmpty ? nil : projectName
            )
            errorMessage = nil
        } catch {
            plan = nil
            errorMessage = describe(error)
        }
    }

    func showLogs(for service: String) async {
        guard !composeFilePath.isEmpty else { return }
        isRunning = true
        errorMessage = nil
        do {
            let logs = try await orchestrator.logs(
                filePath: composeFilePath,
                projectName: projectName.isEmpty ? nil : projectName,
                serviceName: service,
                tail: 200
            )
            if let entry = logs.first {
                let body = entry.logs.isEmpty ? "No logs available" : entry.logs
                output = "==> Logs: \(entry.service)\n\n\(body)"
            } else {
                output = "==> Logs: \(service)\n\nNo logs available"
            }
        } catch {
            errorMessage = describe(error)
        }
        isRunning = false
    }

    func restart(service: String) async {
        guard !composeFilePath.isEmpty else { return }
        isRunning = true
        output = ""
        errorMessage = nil

        do {
            try await orchestrator.restart(
                filePath: composeFilePath,
                projectName: projectName.isEmpty ? nil : projectName,
                serviceName: service,
                progress: { [self] line in
                    appendOutput(line)
                }
            )
            await refreshPS()
        } catch {
            errorMessage = describe(error)
        }
        isRunning = false
    }

    private func appendOutput(_ line: String) {
        if output.isEmpty {
            output = line
        } else {
            output += "\n" + line
        }
    }

    private func describe(_ error: Error) -> String {
        if let composeError = error as? ComposeError {
            return composeError.description
        }
        return error.localizedDescription
    }
}

struct ComposeServiceRow: Identifiable {
    let id: String
    let name: String
    let service: String
    let state: String
}

struct ComposeView: View {
    @State private var vm = ComposeVM()
    @State private var showFilePicker = false
    @State private var selectedServiceID: String?
    @State private var selectedGraphNode: String?

    private var composeServices: [ComposeServiceRow] {
        vm.services.map { ComposeServiceRow(id: $0.name, name: $0.name, service: $0.service, state: $0.state) }
    }

    /// service name → lifecycle state, for coloring graph nodes.
    private var serviceStates: [String: String] {
        Dictionary(uniqueKeysWithValues: vm.services.map { ($0.service, $0.state) })
    }

    private var isUp: Bool { !composeServices.isEmpty }

    private var runningCount: Int {
        composeServices.filter { $0.state.lowercased() == "running" }.count
    }

    /// Disabled tooltips state the blocking condition (DESIGN.md §2.1).
    private var startButtonHelp: String {
        if vm.composeFilePath.isEmpty { return "Choose a compose file first" }
        if vm.isRunning { return "Waiting for the current operation to finish" }
        if runningCount > 0 { return "Services are already running — stop them first" }
        return "Start all services defined in the compose file"
    }

    private var stopButtonHelp: String {
        if vm.composeFilePath.isEmpty { return "Choose a compose file first" }
        if vm.isRunning { return "Waiting for the current operation to finish" }
        if !isUp { return "No services are defined" }
        return "Stop and remove all services defined in the compose file"
    }

    private var statusText: String {
        if vm.isRunning { return "Working…" }
        if composeServices.isEmpty { return "Stopped" }
        if runningCount > 0 {
            return "\(runningCount) of \(composeServices.count) service\(composeServices.count == 1 ? "" : "s") running"
        }
        return "Stopped — \(composeServices.count) service\(composeServices.count == 1 ? "" : "s") defined"
    }

    private var statusColor: Color {
        if vm.isRunning { return .secondary }
        return runningCount > 0 ? .green : .gray
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Compose Configuration") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text("Compose File")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                TextField("/path/to/docker-compose.yml", text: $vm.composeFilePath)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Compose file path")
                                Button("Browse…") {
                                    showFilePicker = true
                                }
                                .accessibilityLabel("Browse for compose file")
                                .accessibilityHint("Opens a file picker to select a Docker Compose file")
                            }
                        }

                        GridRow {
                            Text("Project")
                                .foregroundStyle(.secondary)
                            TextField("project-name (optional)", text: $vm.projectName)
                                .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("Status")
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor)
                                    .frame(width: 8, height: 8)
                                Text(statusText)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Status: \(statusText)")
                        }
                    }
                    .padding(.top, 4)
                }

                if let plan = vm.plan {
                    GroupBox("What Will Run") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !plan.warnings.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.orange)
                                    ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                                        Text("• \(warning)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Startup order")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                ForEach(Array(plan.services.enumerated()), id: \.offset) { index, service in
                                    DisclosureGroup {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Equivalent command")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(service.command)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(6)
                                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text("\(index + 1).")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 20, alignment: .trailing)
                                            Text(service.name)
                                                .font(.system(.body, design: .monospaced))
                                            if !service.warnings.isEmpty {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundStyle(.orange)
                                                    .help(service.warnings.joined(separator: "\n"))
                                            }
                                        }
                                    }
                                }
                            }

                            HStack(spacing: 16) {
                                if !plan.networks.isEmpty {
                                    Label("\(plan.networks.count) networks", systemImage: "network")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !plan.volumes.isEmpty {
                                    Label("\(plan.volumes.count) volumes", systemImage: "externaldrive")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                if let plan = vm.plan, plan.services.count > 1 {
                    GroupBox("Topology") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Arrows point at dependencies — traffic flows the same way. Click a node to trace what it talks to; right-click for actions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ComposeGraphView(
                                plan: plan,
                                states: serviceStates,
                                selectedService: $selectedGraphNode,
                                onViewLogs: { service in
                                    Task { await vm.showLogs(for: service) }
                                },
                                onRestart: { service in
                                    Task { await vm.restart(service: service) }
                                }
                            )
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox("Services") {
                    if composeServices.isEmpty {
                        ContentUnavailableView(
                            "No Services Running",
                            systemImage: "doc.text",
                            description: Text("Choose a compose file above, then choose Start Services in the toolbar.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        Table(composeServices, selection: $selectedServiceID) {
                            TableColumn("Service") { item in
                                Text(item.service)
                                    .font(.system(.body, design: .monospaced))
                            }
                            .width(min: 140)

                            TableColumn("Container") { item in
                                Text(item.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .width(min: 120)

                            TableColumn("State") { item in
                                StatusBadge(status: item.state)
                            }
                            .width(min: 80, max: 120)
                        }
                        .frame(minHeight: 180)
                        .tableStyle(.inset(alternatesRowBackgrounds: false))
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let id = ids.first, let svc = composeServices.first(where: { $0.id == id }) {
                                ComposeRowContextMenu(
                                    service: svc,
                                    onViewLogs: {
                                        Task { await vm.showLogs(for: svc.service) }
                                    },
                                    onRestart: {
                                        Task { await vm.restart(service: svc.service) }
                                    }
                                )
                            }
                        }
                    }
                }

                GroupBox("Output") {
                    if vm.isRunning || !vm.output.isEmpty {
                        ScrollView {
                            Text(vm.output.isEmpty ? "Working…" : vm.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(minHeight: 220, alignment: .top)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        ContentUnavailableView(
                            "No Output",
                            systemImage: "text.alignleft",
                            description: Text("Output from Start Services and Stop Services appears here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
            }
            .padding(20)
        }
        .errorBanner($vm.errorMessage)
        .accessibilityLabel("Compose")
        .accessibilityHint("Manage Docker Compose services")
        .navigationTitle("Compose")
        .toolbar {
            ToolbarItem(id: "up", placement: .primaryAction) {
                Button {
                    Task { await vm.up() }
                } label: {
                    Label("Start Services", systemImage: "play.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .disabled(vm.composeFilePath.isEmpty || vm.isRunning || runningCount > 0)
                .help(startButtonHelp)
                .accessibilityLabel("Start Services")
                .accessibilityHint("Start all services defined in the compose file")
            }

            ToolbarItem(id: "down", placement: .automatic) {
                Button {
                    Task { await vm.down() }
                } label: {
                    Label("Stop Services", systemImage: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
                .disabled(vm.composeFilePath.isEmpty || vm.isRunning || !isUp)
                .help(stopButtonHelp)
                .accessibilityLabel("Stop Services")
                .accessibilityHint("Stop and remove all services defined in the compose file")
            }

            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refreshPS() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(vm.composeFilePath.isEmpty || vm.isRunning)
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload the services list (⌘R)")
                .accessibilityLabel("Refresh services")
            }

            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .compose)
            }
        }
        .toolbarRole(.editor)
        .task {
            if !vm.composeFilePath.isEmpty {
                await vm.refreshPS()
                await vm.refreshPlan()
            }
        }
        .onChange(of: vm.composeFilePath) {
            Task { await vm.refreshPlan() }
        }
        .onChange(of: vm.projectName) {
            Task { await vm.refreshPlan() }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.yaml, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await vm.selectComposeFile(url.path) }
            }
        }
    }
}

struct ComposeRowContextMenu: View {
    let service: ComposeServiceRow
    let onViewLogs: () -> Void
    let onRestart: () -> Void

    var body: some View {
        Button("Copy Service Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(service.service, forType: .string)
        }
        Divider()
        Button("View Logs", action: onViewLogs)
        Button("Restart", action: onRestart)
    }
}
