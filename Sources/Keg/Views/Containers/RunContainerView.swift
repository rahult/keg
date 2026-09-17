import SwiftUI
import ContainerAPIClient
import ContainerResource

struct RunContainerView: View {
    @Environment(\.dismiss) private var dismiss

    /// Optional prefilled image (e.g. "Run" from the Images list).
    var initialImage: String? = nil

    @State private var imageName = ""
    @State private var containerName = ""
    @State private var command = ""
    @State private var envVars = ""
    @State private var ports = ""
    @State private var volumes = ""
    @State private var cpus: Int = 4
    @State private var memory = "1G"
    @State private var detached = true
    @State private var isRunning = false
    @State private var errorMessage: String?

    init(initialImage: String? = nil) {
        self.initialImage = initialImage
        _imageName = State(initialValue: initialImage ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Container")
                .font(.headline)

            Form {
                TextField("Image", text: $imageName, prompt: Text("nginx:latest"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Container image")
                    .accessibilityHint("Docker image name and tag to run")

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

                Toggle("Run detached", isOn: $detached)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { runContainer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageName.isEmpty || isRunning)
                    .help(imageName.isEmpty ? "Enter an image name first" : "Download the image if needed and start the container")
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
        .accessibilityLabel("Run Container")
        .accessibilityHint("Configure and launch a new container")
    }

    private func runContainer() {
        isRunning = true
        errorMessage = nil

        Task {
            do {
                let args = ContainerRunArguments.build(
                    name: containerName,
                    env: ContainerRunArguments.splitList(envVars),
                    ports: ContainerRunArguments.splitList(ports),
                    volumes: ContainerRunArguments.splitList(volumes),
                    cpus: cpus,
                    memory: memory,
                    detached: detached,
                    image: imageName,
                    command: command
                )

                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(filePath: "/usr/bin/env")
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    errorMessage = errorStr
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }
}
