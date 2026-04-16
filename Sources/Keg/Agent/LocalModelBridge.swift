import Foundation

/// Lifecycle state of the local model server
public enum LocalModelState: Sendable {
    case stopped
    case starting
    case running(port: Int)
    case stopping
    case error(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }
}

/// Streaming chunk from the model
public struct ModelStreamChunk: Sendable {
    public let content: String
    public let done: Bool
    public let tokenCount: Int?

    public init(content: String, done: Bool = false, tokenCount: Int? = nil) {
        self.content = content
        self.done = done
        self.tokenCount = tokenCount
    }
}

/// Chat completion message
public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }

    public static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content)
    }

    public static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: content)
    }
}

/// Completion request options
public struct CompletionOptions: Sendable {
    public var temperature: Double
    public var maxTokens: Int
    public var stream: Bool
    public var stopTokens: [String]
    public var repeatPenalty: Double

    public init(
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        stream: Bool = false,
        stopTokens: [String] = [],
        repeatPenalty: Double = 1.1
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.stopTokens = stopTokens
        self.repeatPenalty = repeatPenalty
    }
}

/// Actor managing the llama.cpp HTTP server lifecycle
/// Provides: start, stop, health check, and streaming chat completions
public actor LocalModelBridge {
    // MARK: - Properties

    private var process: Process?
    private var state: LocalModelState = .stopped
    private var config: LocalModelConfig?
    private var healthCheckTask: Task<Void, Never>?
    private var lastHealthCheck: Date?
    private var consecutiveFailures: Int = 0

    /// Current server state
    public var currentState: LocalModelState {
        state
    }

    /// Current configuration
    public var currentConfig: LocalModelConfig? {
        config
    }

    /// Server URL when running
    public var serverURL: URL? {
        if case .running(let port) = state {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Start the llama.cpp server with given configuration
    public func start(with config: LocalModelConfig) async throws {
        guard !state.isRunning else {
            throw LocalModelError.alreadyRunning
        }

        guard config.isValid else {
            throw LocalModelError.invalidConfig(config.validationErrors.joined(separator: "; "))
        }

        self.config = config
        state = .starting

        // Find llama-cli or llama-server binary
        let serverBinary = try findServerBinary()

        // Build arguments for llama.cpp server
        var args = [
            "-m", config.modelPath,
            "-c", String(config.contextSize),
            "-tb", String(config.batchSize),
            "-ngl", String(config.gpuLayers),
            "--port", String(config.port),
            "--host", "127.0.0.1"
        ]

        if config.flashAttention {
            args.append("--flash-attn")
        }

        if config.threads > 0 {
            args.append(contentsOf: ["-t", String(config.threads)])
        }

        // Launch the server process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBinary)
        process.arguments = args + ["-fa"] // -fa for async output

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Log output for debugging
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Task { await self.logOutput(text) }
            }
        }

        self.process = process

        do {
            try process.run()
        } catch {
            state = .error("Failed to start server: \(error.localizedDescription)")
            throw LocalModelError.processStartFailed(error)
        }

        // Wait for server to be ready
        try await waitForServerReady(port: config.port, timeout: .seconds(30))

        state = .running(port: config.port)

        // Start health monitoring
        startHealthMonitoring()
    }

    /// Stop the llama.cpp server
    public func stop() async {
        guard state.isRunning || state.isStarting else { return }

        state = .stopping
        healthCheckTask?.cancel()
        healthCheckTask = nil

        // Terminate the process gracefully first
        if let process = process, process.isRunning {
            process.terminate()
        }

        // Wait for graceful shutdown
        try? await Task.sleep(for: .milliseconds(500))

        // Force kill if still running
        if let process = process, process.isRunning {
            process.interrupt()
        }

        self.process = nil
        state = .stopped
    }

    /// Restart the server with current or new config
    public func restart(with config: LocalModelConfig? = nil) async throws {
        await stop()
        try await Task.sleep(for: .milliseconds(500))

        if let newConfig = config {
            try await start(with: newConfig)
        } else if let currentConfig = self.config {
            try await start(with: currentConfig)
        } else {
            throw LocalModelError.noConfig
        }
    }

    // MARK: - Health Check

    /// Perform a health check on the running server
    public func healthCheck() async -> Bool {
        guard let url = serverURL else { return false }

        do {
            let healthURL = url.appendingPathComponent("health")
            let (data, response) = try await URLSession.shared.data(from: healthURL)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                lastHealthCheck = Date()
                consecutiveFailures = 0

                // Parse health response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return json["status"] as? String == "ok"
                }
                return true
            }
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                state = .error("Server health check failed")
            }
        }
        return false
    }

    /// Get server status with details
    public func getStatus() async -> ServerStatus {
        let isHealthy = await healthCheck()

        return ServerStatus(
            state: state,
            isHealthy: isHealthy,
            lastHealthCheck: lastHealthCheck,
            config: config,
            uptimeSeconds: nil
        )
    }

    // MARK: - Chat Completions

    /// Send a chat completion request
    public func chatCompletion(
        messages: [ChatMessage],
        options: CompletionOptions = CompletionOptions()
    ) async throws -> String {
        guard let url = serverURL?.appendingPathComponent("v1/chat/completions") else {
            throw LocalModelError.notRunning
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": options.temperature,
            "max_tokens": options.maxTokens,
            "stream": false,
            "stop": options.stopTokens,
            "repeat_penalty": options.repeatPenalty
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalModelError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LocalModelError.serverError(httpResponse.statusCode, errorText)
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LocalModelError.parseError
        }

        return content
    }

    /// Stream a chat completion request
    public func streamChatCompletion(
        messages: [ChatMessage],
        options: CompletionOptions = CompletionOptions()
    ) -> AsyncThrowingStream<ModelStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let url = serverURL?.appendingPathComponent("v1/chat/completions") else {
                    continuation.finish(throwing: LocalModelError.notRunning)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                let body: [String: Any] = [
                    "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    "temperature": options.temperature,
                    "max_tokens": options.maxTokens,
                    "stream": true,
                    "stop": options.stopTokens,
                    "repeat_penalty": options.repeatPenalty
                ]

                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: LocalModelError.invalidResponse)
                        return
                    }

                    var accumulatedContent = ""
                    var totalTokens = 0

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let data = String(line.dropFirst(6))

                            if data == "[DONE]" {
                                continuation.yield(ModelStreamChunk(
                                    content: "",
                                    done: true,
                                    tokenCount: totalTokens
                                ))
                                continuation.finish()
                                return
                            }

                            if let responseData = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                                if let choices = responseData["choices"] as? [[String: Any]],
                                   let delta = choices.first?["delta"] as? [String: Any],
                                   let content = delta["content"] as? String {
                                    accumulatedContent += content
                                    continuation.yield(ModelStreamChunk(content: content, done: false))
                                }

                                if let usage = responseData["usage"] as? [String: Any],
                                   let tokens = usage["completion_tokens"] as? Int {
                                    totalTokens = tokens
                                }
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func findServerBinary() throws -> String {
        let possiblePaths = [
            "/usr/local/bin/llama-server",
            "/opt/homebrew/bin/llama-server",
            "/usr/bin/llama-server",
            "llama-server"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Check if it's in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/which")
        process.arguments = ["llama-server"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return path
            }
        }

        throw LocalModelError.serverNotFound
    }

    private func waitForServerReady(port: Int, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)

        while Date() < deadline {
            do {
                let url = URL(string: "http://127.0.0.1:\(port)/health")!
                let (_, response) = try await URLSession.shared.data(from: url)

                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    return
                }
            } catch {
                // Not ready yet
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        throw LocalModelError.startupTimeout
    }

    private func startHealthMonitoring() {
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                _ = await self?.healthCheck()
            }
        }
    }

    private func logOutput(_ text: String) {
        // In production, route to logging system
        #if DEBUG
        print("[llama-server] \(text)")
        #endif
    }
}

// MARK: - Supporting Types

public struct ServerStatus: Sendable {
    public let state: LocalModelState
    public let isHealthy: Bool
    public let lastHealthCheck: Date?
    public let config: LocalModelConfig?
    public let uptimeSeconds: Int?

    public init(
        state: LocalModelState,
        isHealthy: Bool,
        lastHealthCheck: Date?,
        config: LocalModelConfig?,
        uptimeSeconds: Int?
    ) {
        self.state = state
        self.isHealthy = isHealthy
        self.lastHealthCheck = lastHealthCheck
        self.config = config
        self.uptimeSeconds = uptimeSeconds
    }
}

public enum LocalModelError: Error, CustomStringConvertible {
    case alreadyRunning
    case invalidConfig(String)
    case processStartFailed(Error)
    case notRunning
    case serverNotFound
    case startupTimeout
    case invalidResponse
    case serverError(Int, String)
    case parseError
    case noConfig

    public var description: String {
        switch self {
        case .alreadyRunning: return "Server is already running"
        case .invalidConfig(let msg): return "Invalid configuration: \(msg)"
        case .processStartFailed(let err): return "Failed to start process: \(err.localizedDescription)"
        case .notRunning: return "Server is not running"
        case .serverNotFound: return "llama-server binary not found"
        case .startupTimeout: return "Server failed to start within timeout"
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let code, let msg): return "Server error (\(code)): \(msg)"
        case .parseError: return "Failed to parse server response"
        case .noConfig: return "No configuration available"
        }
    }
}

// MARK: - Duration Extension

extension Duration {
    var timeInterval: TimeInterval {
        Double(self.components.seconds) + Double(self.components.attoseconds) / 1e18
    }
}
