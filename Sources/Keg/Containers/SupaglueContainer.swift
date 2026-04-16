import Foundation

/// Actor managing the lifecycle of the Supaglue Apple Container.
///
/// Supaglue runs as a Keg-managed Apple Container — not bare Docker.
/// Keg handles image pull, container start/stop, and networking.
/// The agent talks to Supaglue over internal `localhost:3000` once running.
///
/// Lifecycle:
///   1. pull()        — fetch `supaglue/supaglue` image via `container pull`
///   2. run()         — start container via `container run` (background, -d)
///   3. waitReady()   — poll health endpoint until /healthz returns 200
///   4. stop()        — stop container via `container stop`
///   5. remove()      — remove container via `container rm`
///   6. status()      — inspect container state
actor SupaglueContainer {
    static let containerName = "keg-supaglue"
    static let imageName     = "supaglue/supaglue:latest"
    static let apiPort      = 3000
    static let apiBaseURL  = "http://127.0.0.1:\(apiPort)"

    /// Health-check timeout for `waitReady`
    static let startupTimeoutSeconds = 120

    // MARK: - Lifecycle

    /// Pull the Supaglue Docker image using `container pull`.
    func pull() async throws -> (code: Int32, stdout: String, stderr: String) {
        try await runCLI(["container", "pull", Self.imageName])
    }

    /// Start the Supaglue container in detached mode using `container run`.
    /// Maps port 3000 inside the container to 127.0.0.1:3000 on the host.
    /// Mounts ~/.keg/supaglue for persistent config/state.
    func run() async throws -> (code: Int32, stdout: String, stderr: String) {
        // Remove any stale container first
        try? await runCLI(["container", "rm", "-f", Self.containerName])

        let stateDir = NSHomeDirectory() + "/.keg/supaglue"
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

        return try await runCLI([
            "container", "run", "-d",
            "--name", Self.containerName,
            "-m", "2G",
            "-c", "2",
            "-p", "127.0.0.1:\(Self.apiPort):\(Self.apiPort)",
            "-v", "\(stateDir):/home/supaglue/data",
            Self.imageName
        ])
    }

    /// Wait for the /healthz endpoint to return 200.
    /// Retries every 2 seconds for up to `startupTimeoutSeconds`.
    func waitReady() async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(Self.startupTimeoutSeconds))
        var attempt = 0

        while Date() < deadline {
            attempt += 1
            if try await isReady() {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw SupaglueContainerError.startupTimeout
    }

    /// Stop the Supaglue container.
    func stop() async throws {
        _ = try await runCLI(["container", "stop", Self.containerName])
    }

    /// Remove the Supaglue container.
    func remove() async throws {
        _ = try await runCLI(["container", "rm", "-f", Self.containerName])
    }

    // MARK: - Status

    /// Current container status: running, stopped, or absent.
    func status() async -> ContainerStatus {
        let (inspectCode, out, _) = (try? await runCLI([
            "container", "inspect", Self.containerName
        ])) ?? (code: Int32(1), stdout: "", stderr: "")

        guard inspectCode == 0 else { return .absent }

        // Parse JSON output — container inspect returns a JSON array
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let state = first["State"] as? [String: Any] else {
            return .absent
        }

        if let running = state["Running"] as? Bool, running {
            return .running
        } else {
            return .stopped
        }
    }

    /// Returns true if the /healthz endpoint responds 200.
    func isReady() async throws -> Bool {
        guard let url = URL(string: "\(Self.apiBaseURL)/healthz") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.httpMethod = "GET"

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - CLI Helper

    /// Run an arbitrary CLI command and return exit code + combined output.
    private func runCLI(_ args: [String]) async throws -> (code: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output, ""))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Types

enum ContainerStatus: Sendable {
    case running
    case stopped
    case absent
}

enum SupaglueContainerError: Error, LocalizedError {
    case startupTimeout
    case pullFailed(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .startupTimeout:
            return "Supaglue container did not become ready within \(SupaglueContainer.startupTimeoutSeconds)s"
        case .pullFailed(let msg):
            return "Image pull failed: \(msg)"
        case .startFailed(let msg):
            return "Container start failed: \(msg)"
        }
    }
}
