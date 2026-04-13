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
    @State private var showContextPicker = false
    @State private var showFilePicker = false

    var body: some View {
        Group {
            if isBuilding || !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                ContentUnavailableView(
                    "No Build Output",
                    systemImage: "hammer",
                    description: Text("Configure build settings and click Build")
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Dismiss") { errorMessage = nil }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
            }
        }
        .navigationTitle("Builds")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isBuilding {
                    Button("Cancel Build") {
                        // TODO: Cancel the build process
                    }
                } else {
                    Button("Build") {
                        startBuild()
                    }
                    .disabled(contextDir.isEmpty)
                    .buttonStyle(.borderedProminent)
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                HStack(spacing: 8) {
                    TextField("Context", text: $contextDir, prompt: Text("."))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 140)
                    Button("...") { showContextPicker = true }
                        .controlSize(.small)

                    TextField("Dockerfile", text: $dockerfile, prompt: Text("Dockerfile"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 100)
                    Button("...") { showFilePicker = true }
                        .controlSize(.small)

                    TextField("Tags", text: $tags, prompt: Text("my-image:latest"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 120)

                    TextField("Args", text: $buildArgs, prompt: Text("KEY=VALUE"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 120)

                    TextField("Platform", text: $platform, prompt: Text("linux/arm64"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 100)
                }
            }

            ToolbarItemGroup(placement: .automatic) {
                Toggle("No Cache", isOn: $noCache)
                    .controlSize(.small)
            }
        }
        .fileImporter(isPresented: $showContextPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                contextDir = url.path
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                dockerfile = url.path
            }
        }
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
