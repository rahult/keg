import SwiftUI
import ContainerAPIClient
import ContainerResource

/// Edit & Recreate: containers are immutable, so this sheet prefills a new
/// container from an existing one's configuration — image, env, ports, mounts
/// and resource limits — so the user can tweak and relaunch in seconds.
struct RecreateContainerView: View {
    @Environment(\.dismiss) private var dismiss

    let container: ContainerSnapshot
    let onRecreate: () -> Void

    @State private var imageName: String
    @State private var containerName: String
    @State private var command: String
    @State private var envVars: String
    @State private var ports: String
    @State private var volumes: String
    @State private var cpus: Int
    @State private var memory: String
    @State private var deleteOriginal = false
    @State private var isRunning = false
    @State private var errorMessage: String?

    init(container: ContainerSnapshot, onRecreate: @escaping () -> Void = {}) {
        self.container = container
        self.onRecreate = onRecreate

        let config = container.configuration
        _imageName = State(initialValue: config.image.reference)
        // `--name` on apple/container sets the container ID, not a label, so
        // fall back to the ID prefix (what the rest of the UI displays).
        let currentName = config.labels["name"].flatMap { $0.isEmpty ? nil : $0 }
            ?? String(container.id.prefix(12))
        _containerName = State(initialValue: currentName)
        _command = State(initialValue: Self.prefilledCommand(config))
        _envVars = State(initialValue: config.initProcess.environment.joined(separator: ", "))
        _ports = State(initialValue: config.publishedPorts
            .map { "\($0.hostPort):\($0.containerPort)" }
            .joined(separator: ", "))
        _volumes = State(initialValue: config.mounts
            .map { "\($0.source):\($0.destination)" }
            .joined(separator: ", "))
        _cpus = State(initialValue: Int(config.resources.cpus))
        _memory = State(initialValue: ContainerRunArguments.formatMemory(config.resources.memoryInBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit & Recreate")
                .font(.headline)

            Text("Containers are immutable — this creates a new container from \(displayName)'s configuration. Change anything you need, then run.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                TextField("Image", text: $imageName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Container image")

                TextField("Name", text: $containerName, prompt: Text("my-container"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Container name")

                TextField("Command", text: $command, prompt: Text("Optional: override entrypoint"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Command override")

                TextField("Environment Variables", text: $envVars, prompt: Text("KEY=VALUE, separated by commas"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Environment variables")

                TextField("Ports", text: $ports, prompt: Text("8080:80, 443:443"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Port mappings")

                TextField("Volumes", text: $volumes, prompt: Text("host-path:/container-path"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Volume mounts")

                HStack {
                    Stepper("CPUs: \(cpus)", value: $cpus, in: 1...32)
                    Spacer()
                    TextField("Memory", text: $memory, prompt: Text("1G"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                Toggle("Delete original container after recreate", isOn: $deleteOriginal)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(deleteOriginal ? "Recreate" : "Run New Container") {
                    recreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(imageName.isEmpty || isRunning)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityLabel("Edit and Recreate Container")
    }

    private var displayName: String {
        if let name = container.configuration.labels["name"], !name.isEmpty {
            return name
        }
        return String(container.id.prefix(12))
    }

    private static func prefilledCommand(_ config: ContainerConfiguration) -> String {
        let process = config.initProcess
        let parts = [process.executable] + process.arguments
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func recreate() {
        isRunning = true
        errorMessage = nil

        Task {
            let args = ContainerRunArguments.build(
                name: containerName.trimmingCharacters(in: .whitespaces),
                env: ContainerRunArguments.splitList(envVars),
                ports: ContainerRunArguments.splitList(ports),
                volumes: ContainerRunArguments.splitList(volumes),
                cpus: cpus,
                memory: memory.trimmingCharacters(in: .whitespaces),
                detached: true,
                image: imageName.trimmingCharacters(in: .whitespaces),
                command: command
            )

            do {
                let (code, output) = try await ContainerCLI.run(args)
                guard code == 0 else {
                    errorMessage = output.isEmpty ? "Failed to create container" : output
                    isRunning = false
                    return
                }

                if deleteOriginal {
                    let client = ContainerClient()
                    try? await client.delete(id: container.id, force: true)
                }

                dismiss()
                onRecreate()
            } catch {
                errorMessage = error.localizedDescription
                isRunning = false
            }
        }
    }
}
