import SwiftUI

struct DevContainerView: View {
    @State private var vm = DevContainerVM()
    @State private var showDirPicker = false
    @State private var showFilePicker = false

    var body: some View {
        Group {
            if vm.isRunning {
                VStack(spacing: 16) {
                    ProgressView("Setting up dev container...")
                    if !vm.output.isEmpty {
                        ScrollView {
                            Text(vm.output)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let spec = vm.spec {
                specLoadedView(spec)
            } else {
                ContentUnavailableView(
                    "No Dev Container",
                    systemImage: "swift",
                    description: Text("Select a project directory containing .devcontainer/devcontainer.json")
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
                Button("Open in Container") {
                    vm.openInContainer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.spec == nil || vm.isRunning)
            }

            ToolbarItem(placement: .automatic) {
                Button("Select Project...") {
                    showDirPicker = true
                }
            }

            ToolbarItem(placement: .automatic) {
                Button("Open JSON...") {
                    showFilePicker = true
                }
            }
        }
        .fileImporter(
            isPresented: $showDirPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.detectDevContainer(in: url.path)
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.projectDirectory = url.deletingLastPathComponent().path
                vm.devcontainerPath = url.path
                vm.parseDevContainer(at: url.path)
            }
        }
    }

    // MARK: - Spec Loaded View

    @ViewBuilder
    private func specLoadedView(_ spec: DevContainerSpec) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Output log (if we ran)
                if !vm.output.isEmpty {
                    outputSection
                }

                // Config summary
                configSection(spec)

                // Generated command preview
                commandPreviewSection
            }
            .padding(16)
        }
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output")
                .font(.headline)
            Text(vm.output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Config Summary

    @ViewBuilder
    private func configSection(_ spec: DevContainerSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            if let name = spec.name {
                DetailRow(label: "Name", value: name)
            }

            if let image = spec.resolvedImage {
                DetailRow(label: "Image", value: image)
            } else if let dockerfile = spec.dockerFile {
                DetailRow(label: "Dockerfile", value: dockerfile)
            }

            if let context = spec.context ?? spec.build?.context {
                DetailRow(label: "Build Context", value: context)
            }

            if let ports = spec.forwardPorts, !ports.isEmpty {
                DetailRow(label: "Forward Ports", value: ports.map(\.displayValue).joined(separator: ", "))
            }

            if let env = spec.containerEnv, !env.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Environment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(env.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                        Text("\(key)=\(value)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if let mounts = spec.mounts, !mounts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mounts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(mounts, id: \.self) { mount in
                        Text(mount)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if let workspace = spec.workspaceFolder {
                DetailRow(label: "Workspace", value: workspace)
            }

            if let cmd = spec.postCreateCommand {
                DetailRow(label: "Post-Create Command", value: cmd)
            }

            if let features = spec.features, !features.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Features (\(features.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(features.keys.sorted()), id: \.self) { feature in
                        Text(feature)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Command Preview

    private var commandPreviewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Generated Command")
                    .font(.headline)
                Spacer()
                Button {
                    let cmd = vm.generateRunArgs().joined(separator: " ")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Text(vm.generateRunArgs().joined(separator: " "))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
