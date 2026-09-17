import SwiftUI

struct BuildView: View {
    private enum Field: Hashable {
        case contextDir
        case dockerfile
        case tags
        case buildArgs
        case platform
    }

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
    @State private var buildProcess: Process?
    @State private var didCancelBuild = false
    @FocusState private var focusedField: Field?

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
                                        .focused($focusedField, equals: .contextDir)
                                        .accessibilityLabel("Build context directory")
                                        .accessibilityHint("Choose the folder to build from")
                                    Button("Browse…") { showContextPicker = true }
                                        .accessibilityLabel("Browse for build context")
                                }
                            }

                            GridRow {
                                Text("Dockerfile")
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    TextField("Dockerfile path", text: $dockerfile, prompt: Text("Dockerfile"))
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: .dockerfile)
                                        .accessibilityLabel("Dockerfile path")
                                    Button("Browse…") { showFilePicker = true }
                                        .accessibilityLabel("Browse for Dockerfile")
                                }
                            }

                            GridRow {
                                Text("Tags")
                                    .foregroundStyle(.secondary)
                                TextField("my-image:latest, my-image:v1", text: $tags)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .tags)
                                    .accessibilityLabel("Image tags")
                            }

                            GridRow {
                                Text("Build Args")
                                    .foregroundStyle(.secondary)
                                TextField("KEY=VALUE, FOO=bar", text: $buildArgs)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .buildArgs)
                                    .accessibilityLabel("Build arguments")
                            }

                            GridRow {
                                Text("Platform")
                                    .foregroundStyle(.secondary)
                                TextField("linux/arm64", text: $platform)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .platform)
                                    .accessibilityLabel("Build platform")
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
                            .accessibilityLabel("Build output")
                            .accessibilityHint("Read-only build logs")
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
        .errorBanner($errorMessage)
        .navigationTitle("Builds")
        .onAppear {
            if focusedField == nil {
                focusedField = .contextDir
            }
        }
        .onExitCommand {
            if errorMessage != nil {
                errorMessage = nil
                return
            }

            focusedField = nil
        }
        .toolbar {
            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .builds)
            }

            ToolbarItem(id: "build", placement: .primaryAction) {
                if isBuilding {
                    Button("Cancel Build") {
                        cancelBuild()
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the active container build")
                    .accessibilityHint("Stop the active container build")
                } else {
                    Button("Build") {
                        startBuild()
                    }
                    .disabled(contextDir.isEmpty)
                    .help(contextDir.isEmpty ? "Choose the folder containing your Dockerfile first" : "Build an image from the Dockerfile in the chosen folder")
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Start building the selected container image")
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
        didCancelBuild = false

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

                await MainActor.run {
                    buildProcess = process
                }

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

                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: remaining, encoding: .utf8), !str.isEmpty {
                    await MainActor.run {
                        output += str
                    }
                }

                await MainActor.run {
                    pipe.fileHandleForReading.readabilityHandler = nil

                    if didCancelBuild || process.terminationReason == .uncaughtSignal {
                        output += output.hasSuffix("\n") || output.isEmpty ? "Build canceled.\n" : "\nBuild canceled.\n"
                    } else if process.terminationStatus != 0 {
                        errorMessage = "Build failed (exit code \(process.terminationStatus))"
                    }

                    buildProcess = nil
                    isBuilding = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    buildProcess = nil
                    isBuilding = false
                }
            }
        }
    }

    private func cancelBuild() {
        didCancelBuild = true
        buildProcess?.terminate()
    }
}
