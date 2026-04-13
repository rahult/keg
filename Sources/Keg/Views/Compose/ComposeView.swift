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

struct ComposeView: View {
    @State private var vm = ComposeVM()
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Compose file path...", text: $vm.composeFilePath)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Browse") {
                    showFilePicker = true
                }
                .controlSize(.small)

                TextField("Project", text: $vm.projectName, prompt: Text("project-name"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 150)

                Spacer()

                Button("Up") {
                    Task { await vm.up() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Button("Down") {
                    Task { await vm.down() }
                }
                .controlSize(.small)

                Button {
                    Task { await vm.refreshPS() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

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
                if !vm.services.isEmpty {
                    List(vm.services, id: \.name) { item in
                        HStack {
                            StatusBadge(status: item.state)
                            Text(item.service)
                                .font(.system(.body, design: .monospaced))
                            Text(item.name)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }

                if !vm.output.isEmpty {
                    ScrollView {
                        Text(vm.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }

            if let errorMessage = vm.errorMessage {
                HStack {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Compose")
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.yaml, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.composeFilePath = url.path
            }
        }
    }
}
