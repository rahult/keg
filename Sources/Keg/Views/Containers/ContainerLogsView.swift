import SwiftUI

struct ContainerLogsView: View {
    let containerID: String
    @State private var logs = ""
    @State private var isFollowing = true
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Logs: \(containerID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow", isOn: $isFollowing)
                    .controlSize(.small)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logs, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(logs)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("logs")
                    }
                    .onChange(of: logs) {
                        if isFollowing {
                            withAnimation {
                                proxy.scrollTo("logs", anchor: .bottom)
                            }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .task {
            await loadLogs()
        }
        .onChange(of: isFollowing) {
            if isFollowing {
                Task { await loadLogs() }
            }
        }
    }

    private func loadLogs() async {
        isLoading = true
        errorMessage = nil

        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "logs", isFollowing ? "-f" : "", containerID].compactMap { $0.isEmpty ? nil : $0 }
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            if isFollowing {
                // Stream logs
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                        Task { @MainActor in
                            logs += str
                        }
                    }
                }
                // Keep running while following
                try? await Task.sleep(for: .seconds(Int.max))
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                logs = String(data: data, encoding: .utf8) ?? ""
                process.waitUntilExit()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
