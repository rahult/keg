import SwiftUI
import ContainerAPIClient
import ContainerResource

struct RunContainerView: View {
    @Environment(\.dismiss) private var dismiss
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Container")
                .font(.headline)

            Form {
                TextField("Image", text: $imageName, prompt: Text("nginx:latest"))
                    .textFieldStyle(.roundedBorder)

                TextField("Name", text: $containerName, prompt: Text("my-container"))
                    .textFieldStyle(.roundedBorder)

                TextField("Command", text: $command, prompt: Text("Optional: override entrypoint"))
                    .textFieldStyle(.roundedBorder)

                TextField("Environment Variables", text: $envVars, prompt: Text("KEY=VALUE, separated by commas"))
                    .textFieldStyle(.roundedBorder)

                TextField("Ports", text: $ports, prompt: Text("8080:80, 443:443"))
                    .textFieldStyle(.roundedBorder)

                TextField("Volumes", text: $volumes, prompt: Text("host-path:/container-path"))
                    .textFieldStyle(.roundedBorder)

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
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func runContainer() {
        isRunning = true
        errorMessage = nil

        Task {
            do {
                var args = ["container", "run"]

                if detached { args.append("-d") }
                if !containerName.isEmpty {
                    args += ["--name", containerName]
                }
                for env in envVars.split(separator: ",").map(String.init).map({ $0.trimmingCharacters(in: .whitespaces) }) where !env.isEmpty {
                    args += ["-e", env]
                }
                for port in ports.split(separator: ",").map(String.init).map({ $0.trimmingCharacters(in: .whitespaces) }) where !port.isEmpty {
                    args += ["-p", port]
                }
                for vol in volumes.split(separator: ",").map(String.init).map({ $0.trimmingCharacters(in: .whitespaces) }) where !vol.isEmpty {
                    args += ["-v", vol]
                }
                args += ["--cpus", "\(cpus)"]
                args += ["--memory", memory]

                args.append(imageName)

                if !command.isEmpty {
                    args += command.split(separator: " ").map(String.init)
                }

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
