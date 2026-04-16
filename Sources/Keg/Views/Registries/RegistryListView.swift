import SwiftUI

struct RegistryListView: View {
    @State private var registries: [String] = []
    @State private var isLoading = false
    @State private var showLoginSheet = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading registries...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if registries.isEmpty {
                ContentUnavailableView("No Registries", systemImage: "globe", description: Text("Log in to a container registry"))
            } else {
                List(registries, id: \.self) { registry in
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(registry)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                    .contextMenu {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(registry, forType: .string)
                        }
                        Divider()
                        Button("Logout", role: .destructive) {
                            logout(registry: registry)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Registries")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Login...") {
                    showLoginSheet = true
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await loadRegistries() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await loadRegistries()
        }
        .sheet(isPresented: $showLoginSheet) {
            RegistryLoginView { _ in
                Task { await loadRegistries() }
            }
        }
    }

    private func loadRegistries() async {
        isLoading = true
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["container", "registry", "list"]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let output = String(data: data, encoding: .utf8) {
            registries = output.split(separator: "\n").map(String.init)
        }
        isLoading = false
    }

    @State private var logoutError: String?

    private func logout(registry: String) {
        Task {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "registry", "logout", registry]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    logoutError = String(data: data, encoding: .utf8) ?? "Logout failed with exit code \(process.terminationStatus)"
                } else {
                    logoutError = nil
                }
            } catch {
                logoutError = "Failed to run logout: \(error.localizedDescription)"
            }
            await loadRegistries()
        }
    }
}

struct RegistryLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var registryURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    let onLogin: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Registry Login")
                .font(.headline)

            TextField("Registry URL", text: $registryURL, prompt: Text("https://registry.example.com"))
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Login") {
                    login()
                }
                .disabled(registryURL.isEmpty || username.isEmpty || isLoggingIn)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func login() {
        isLoggingIn = true
        errorMessage = nil

        Task {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "registry", "login", registryURL]
            process.standardOutput = pipe
            process.standardError = pipe

            // Pass credentials via stdin
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            let credentials = "\(username)\n\(password)\n"
            guard let credentialData = credentials.data(using: .utf8) else {
                errorMessage = "Failed to encode credentials"
                isLoggingIn = false
                return
            }
            inputPipe.fileHandleForWriting.write(credentialData)
            try? inputPipe.fileHandleForWriting.close()

            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                onLogin(registryURL)
                dismiss()
            } else {
                errorMessage = String(data: data, encoding: .utf8) ?? "Login failed"
            }
            isLoggingIn = false
        }
    }
}
