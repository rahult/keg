import SwiftUI

@Observable
@MainActor
final class ComposeVM {
    var composeFilePath = ""
    var projectName = ""
    var isRunning = false
    var output = ""
    var errorMessage: String?
    var services: [(name: String, service: String, state: String)] = []

    private let orchestrator = ComposeOrchestrator()

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
                detached: detached
            )
            output = "Compose up completed successfully"
            await refreshPS()
        } catch {
            errorMessage = error.localizedDescription
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
                projectName: projectName.isEmpty ? nil : projectName
            )
            output = "Compose down completed"
            services = []
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
        }
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

    private var composeServices: [ComposeServiceRow] {
        vm.services.map { ComposeServiceRow(id: $0.name, name: $0.name, service: $0.service, state: $0.state) }
    }

    var body: some View {
        Group {
            if vm.isRunning {
                ProgressView("Running compose...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.services.isEmpty && vm.output.isEmpty {
                ContentUnavailableView(
                    "No Compose Project",
                    systemImage: "doc.text",
                    description: Text("Select a docker-compose.yml file to get started")
                )
            } else {
                VStack(spacing: 0) {
                    if !composeServices.isEmpty {
                        Table(composeServices, selection: $selectedServiceID) {
                            TableColumn("Service") { item in
                                Text(item.service)
                                    .font(.system(.body, design: .monospaced))
                            }
                            .width(min: 120)

                            TableColumn("Name") { item in
                                Text(item.name)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .width(min: 100)

                            TableColumn("State") { item in
                                StatusBadge(status: item.state)
                            }
                            .width(min: 80, max: 120)
                        }
                        .tableStyle(.inset(alternatesRowBackgrounds: true))
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let id = ids.first, let svc = composeServices.first(where: { $0.id == id }) {
                                ComposeRowContextMenu(service: svc)
                            }
                        }
                    }

                    if !vm.output.isEmpty {
                        Divider()
                        ScrollView {
                            Text(vm.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = vm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { vm.errorMessage = nil }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
            }
        }
        .navigationTitle("Compose")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    TextField("Compose file...", text: $vm.composeFilePath)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 200)
                    Button("Browse") {
                        showFilePicker = true
                    }
                    .controlSize(.small)

                    TextField("Project", text: $vm.projectName, prompt: Text("project-name"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 120)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button("Up") {
                        Task { await vm.up() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.composeFilePath.isEmpty)

                    Button("Down") {
                        Task { await vm.down() }
                    }
                    .disabled(vm.composeFilePath.isEmpty)

                    Button {
                        Task { await vm.refreshPS() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.yaml, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.composeFilePath = url.path
            }
        }
    }
}

struct ComposeRowContextMenu: View {
    let service: ComposeServiceRow

    var body: some View {
        Button("Copy Service Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(service.service, forType: .string)
        }
        Divider()
        Button("View Logs") { /* TODO: open logs */ }
        Button("Restart") { /* TODO: restart service */ }
    }
}
