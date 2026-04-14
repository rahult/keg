import SwiftUI

struct DevContainerView: View {
    @State private var vm = DevContainerVM()
    @State private var showFilePicker = false

    var body: some View {
        Group {
            if vm.spec != nil {
                loadedView
            } else {
                ContentUnavailableView(
                    "No Dev Container",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    description: Text("Select a project with a .devcontainer/devcontainer.json")
                )
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
        .navigationTitle("Dev Containers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Browse Project...") {
                    showFilePicker = true
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.scanProject(at: url.path)
            }
        }
    }

    private var loadedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(.secondary)
                    Text(vm.spec?.name ?? "Dev Container")
                        .font(.title3)
                    Spacer()
                    Button("Open in Container") {
                        Task { await vm.buildAndRun() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isLaunching)
                }

                Divider()

                // Config summary
                if let image = vm.spec?.image {
                    DetailRow(label: "Image", value: image)
                }

                if let dockerfile = vm.spec?.dockerFile {
                    DetailRow(label: "Dockerfile", value: dockerfile)
                }

                if let ports = vm.spec?.forwardPorts, !ports.isEmpty {
                    let portStr = ports.compactMap { $0.portNumber }.map { "\($0)" }.joined(separator: ", ")
                    DetailRow(label: "Forward Ports", value: portStr)
                }

                if let env = vm.spec?.containerEnv, !env.isEmpty {
                    let envStr = env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
                    DetailRow(label: "Environment", value: envStr)
                }

                if let mounts = vm.spec?.mounts, !mounts.isEmpty {
                    let mountStr = mounts.joined(separator: "\n")
                    DetailRow(label: "Mounts", value: mountStr)
                }

                if let projectPath = vm.spec?.workspaceFolder {
                    DetailRow(label: "Workspace", value: projectPath)
                }

                // Post-create commands
                if let cmd = vm.spec?.postCreateCommand {
                    DetailRow(label: "Post-Create Command", value: cmd)
                }

                if let cmd = vm.spec?.postStartCommand {
                    DetailRow(label: "Post-Start Command", value: cmd)
                }
            }
            .padding(16)
        }
    }
}
