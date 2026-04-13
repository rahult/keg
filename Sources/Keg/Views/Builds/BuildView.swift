import SwiftUI

struct BuildView: View {
    @State private var contextDir = ""
    @State private var dockerfile = ""
    @State private var tags = ""
    @State private var buildArgs = ""
    @State private var platform = ""
    @State private var noCache = false
    @State private var isBuilding = false
    @State private var output = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Form
            VStack(alignment: .leading, spacing: 12) {
                Text("Build Image")
                    .font(.title2)

                HStack {
                    TextField("Context Directory", text: $contextDir, prompt: Text("."))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            contextDir = url.path
                        }
                    }
                    .controlSize(.small)
                }

                HStack {
                    TextField("Dockerfile", text: $dockerfile, prompt: Text("Dockerfile"))
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.item]
                        if panel.runModal() == .OK, let url = panel.url {
                            dockerfile = url.path
                        }
                    }
                    .controlSize(.small)
                }

                TextField("Tags (comma separated)", text: $tags, prompt: Text("my-image:latest"))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Build Args (KEY=VALUE, comma separated)", text: $buildArgs, prompt: Text("VERSION=1.0"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Platform", text: $platform, prompt: Text("linux/arm64"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Toggle("No Cache", isOn: $noCache)
                }
            }
            .padding(16)

            Divider()

            // Build output
            if isBuilding || !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 200, maxHeight: .infinity)
            } else {
                Spacer()
            }

            Divider()

            // Action bar
            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Spacer()
                if isBuilding {
                    Button("Cancel Build") {
                        // TODO: Cancel the build process
                    }
                    .controlSize(.small)
                }
                Button("Build") {
                    startBuild()
                }
                .disabled(contextDir.isEmpty || isBuilding)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(16)
        }
        .navigationTitle("Builds")
    }

    private func startBuild() {
        isBuilding = true
        output = ""
        errorMessage = nil

        Task {
            do {
                var args = ["container", "build"]

                args += ["--file", dockerfile.isEmpty ? "Dockerfile" : dockerfile]

                if !tags.isEmpty {
                    for tag in tags.split(separator: ",").map(String.init).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        args += ["--tag", tag]
                    }
                }

                if !platform.isEmpty {
                    args += ["--platform", platform]
                }

                if noCache {
                    args.append("--no-cache")
                }

                if !buildArgs.isEmpty {
                    for arg in buildArgs.split(separator: ",").map(String.init).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                        args += ["--build-arg", arg]
                    }
                }

                args.append(contextDir.isEmpty ? "." : contextDir)

                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(filePath: "/usr/bin/env")
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe

                // Stream output
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        Task { @MainActor in
                            output += str
                        }
                    }
                }

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let str = String(data: remaining, encoding: .utf8) {
                        output += str
                    }
                    errorMessage = "Build failed (exit code \(process.terminationStatus))"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBuilding = false
        }
    }
}
