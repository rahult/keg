import SwiftUI

struct BuildView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("Build Configuration") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text("Context")
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    TextField("Project directory", text: $contextDir, prompt: Text("."))
                                        .textFieldStyle(.roundedBorder)
                                    Button("Browse…") { showContextPicker = true }
                                }
                            }

                            GridRow {
                                Text("Dockerfile")
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    TextField("Dockerfile path", text: $dockerfile, prompt: Text("Dockerfile"))
                                        .textFieldStyle(.roundedBorder)
                                    Button("Browse…") { showFilePicker = true }
                                }
                            }

                            GridRow {
                                Text("Tags")
                                    .foregroundStyle(.secondary)
                                TextField("my-image:latest, my-image:v1", text: $tags)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Build Args")
                                    .foregroundStyle(.secondary)
                                TextField("KEY=VALUE, FOO=bar", text: $buildArgs)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Platform")
                                    .foregroundStyle(.secondary)
                                TextField("linux/arm64", text: $platform)
                                    .textFieldStyle(.roundedBorder)
                            }

                            GridRow {
                                Text("Options")
                                    .foregroundStyle(.secondary)
                                Toggle("Disable cache", isOn: $noCache)
                                    .toggleStyle(.checkbox)
                                    .controlSize(.small)
                            }
                        }
                        .padding(.top, 4)
                    }

                    GroupBox("Build Output") {
                        if isBuilding || !output.isEmpty {
                            ScrollView {
                                Text(output.isEmpty ? "Building…" : output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(minHeight: 260, alignment: .top)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            ContentUnavailableView(
                                "No Build Output",
                                systemImage: "hammer",
                                description: Text("Configure the build and choose Build from the toolbar.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                    }
                }
                .padding(20)
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
        .toolbar(id: "build-toolbar") {
            ToolbarItem(id: "build", placement: .primaryAction) {
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
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .toolbarRole(.editor)
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
