import Foundation

/// Orchestrates the agent loop: creates sessions, sends messages, executes tools, and manages conversation flow
public actor AgentRuntime {
    private let client: ManagedAgentsClient
    private let toolExecutor: ToolExecutor
    private let workingDirectory: URL

    public struct Config: Sendable {
        public var maxIterations: Int
        public var maxToolCallsPerIteration: Int
        public var verbose: Bool

        public init(
            maxIterations: Int = 50,
            maxToolCallsPerIteration: Int = 10,
            verbose: Bool = false
        ) {
            self.maxIterations = maxIterations
            self.maxToolCallsPerIteration = maxToolCallsPerIteration
            self.verbose = verbose
        }
    }

    public enum RuntimeError: Error, LocalizedError {
        case agentNotFound(String)
        case environmentNotFound(String)
        case sessionCreationFailed(String)
        case sessionEndedUnexpectedly(SessionStatus)
        case maxIterationsReached
        case toolExecutionFailed(String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .agentNotFound(let id):
                return "Agent not found: \(id)"
            case .environmentNotFound(let id):
                return "Environment not found: \(id)"
            case .sessionCreationFailed(let msg):
                return "Failed to create session: \(msg)"
            case .sessionEndedUnexpectedly(let status):
                return "Session ended unexpectedly: \(status)"
            case .maxIterationsReached:
                return "Maximum iterations reached"
            case .toolExecutionFailed(let msg):
                return "Tool execution failed: \(msg)"
            case .invalidResponse:
                return "Invalid response from API"
            }
        }
    }

    public init(client: ManagedAgentsClient, workingDirectory: URL = URL(fileURLWithPath: ".")) {
        self.client = client
        self.toolExecutor = ToolExecutor(workingDirectory: workingDirectory)
        self.workingDirectory = workingDirectory
    }

    // MARK: - Run Session

    public struct RunResult: Sendable {
        public let sessionId: String
        public let finalMessage: String
        public let toolCalls: Int
        public let iterations: Int

        public init(sessionId: String, finalMessage: String, toolCalls: Int, iterations: Int) {
            self.sessionId = sessionId
            self.finalMessage = finalMessage
            self.toolCalls = toolCalls
            self.iterations = iterations
        }
    }

    /// Run a complete agent session with a user message
    public func run(
        agentId: String,
        environmentId: String,
        message: String,
        config: Config = Config()
    ) async throws -> RunResult {
        // Create session
        let session = try await createSession(agentId: agentId, environmentId: environmentId)

        if config.verbose {
            print("[AgentRuntime] Created session: \(session.id)")
        }

        // Build initial message
        let userMessage = SessionEvent.userMessage(message)

        // Send initial message and process response
        var events = try await client.sendEvent(sessionId: session.id, event: userMessage)

        var totalToolCalls = 0
        var iterations = 0
        var finalMessage = ""

        // Process response events
        while iterations < config.maxIterations {
            iterations += 1

            // Look for assistant messages and tool calls
            for event in events {
                switch event.type {
                case .assistantMessage:
                    if let content = event.content {
                        finalMessage = content
                        if config.verbose {
                            print("[AgentRuntime] Assistant: \(content.prefix(200))...")
                        }
                    }

                case .toolUse:
                    if let toolUse = event.toolUse {
                        totalToolCalls += 1

                        if config.verbose {
                            print("[AgentRuntime] Tool call: \(toolUse.tool)")
                        }

                        // Execute tool
                        let result = try await executeTool(toolUse, config: config)
                        events = try await client.sendEvent(sessionId: session.id, event: result)

                        // Check for more events from tool result
                        for additionalEvent in events {
                            if additionalEvent.type == .assistantMessage,
                               let content = additionalEvent.content {
                                finalMessage = content
                            }
                        }
                    }

                case .statusUpdate:
                    if let status = event.status {
                        switch status {
                        case .completed, .failed, .cancelled:
                            return RunResult(
                                sessionId: session.id,
                                finalMessage: finalMessage,
                                toolCalls: totalToolCalls,
                                iterations: iterations
                            )
                        default:
                            break
                        }
                    }

                default:
                    break
                }
            }

            // Check session status
            let currentSession = try await client.getSession(id: session.id)
            switch currentSession.status {
            case .completed, .failed, .cancelled:
                return RunResult(
                    sessionId: session.id,
                    finalMessage: finalMessage,
                    toolCalls: totalToolCalls,
                    iterations: iterations
                )
            default:
                break
            }

            // If no tool calls were processed this iteration and we have a final message,
            // poll the session status to determine if we should stop.
            if !finalMessage.isEmpty {
                let polledSession = try await client.getSession(id: session.id)
                switch polledSession.status {
                case .completed, .failed, .cancelled:
                    return RunResult(
                        sessionId: session.id,
                        finalMessage: finalMessage,
                        toolCalls: totalToolCalls,
                        iterations: iterations
                    )
                default:
                    // Session still active; wait briefly before next poll
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        if iterations >= config.maxIterations {
            throw RuntimeError.maxIterationsReached
        }

        return RunResult(
            sessionId: session.id,
            finalMessage: finalMessage,
            toolCalls: totalToolCalls,
            iterations: iterations
        )
    }

    /// Run a streaming session (for real-time UI updates)
    public func runStreaming(
        agentId: String,
        environmentId: String,
        message: String,
        config: Config = Config(),
        onEvent: @escaping @Sendable (SessionEvent) async -> Void
    ) async throws -> RunResult {
        let session = try await createSession(agentId: agentId, environmentId: environmentId)

        let userMessage = SessionEvent.userMessage(message)
        _ = try await client.sendEvent(sessionId: session.id, event: userMessage)

        var totalToolCalls = 0
        var iterations = 0
        var finalMessage = ""

        let stream = try await client.streamEvents(sessionId: session.id)

        for try await event in stream {
            await onEvent(event)

            switch event.type {
            case .assistantMessage:
                if let content = event.content {
                    finalMessage = content
                }

            case .toolUse:
                totalToolCalls += 1
                let result = try await executeTool(event.toolUse!, config: config)
                _ = try await client.sendEvent(sessionId: session.id, event: result)

            case .statusUpdate:
                if let status = event.status,
                   [.completed, .failed, .cancelled].contains(status) {
                    return RunResult(
                        sessionId: session.id,
                        finalMessage: finalMessage,
                        toolCalls: totalToolCalls,
                        iterations: iterations
                    )
                }

            default:
                break
            }

            iterations += 1
            if iterations >= config.maxIterations {
                throw RuntimeError.maxIterationsReached
            }
        }

        return RunResult(
            sessionId: session.id,
            finalMessage: finalMessage,
            toolCalls: totalToolCalls,
            iterations: iterations
        )
    }

    // MARK: - Tool Execution

    private func executeTool(_ toolUse: ToolUseEvent, config: Config) async throws -> SessionEvent {
        let toolName = toolUse.tool
        let toolInput = toolUse.toolInput.mapValues { $0.value }

        do {
            let result = try await toolExecutor.execute(
                ToolExecutor.ToolInput(name: toolName, arguments: toolInput)
            )

            let toolResult = ToolResultEvent(
                toolUseId: toolUse.toolUseId ?? UUID().uuidString,
                toolOutput: AnyCodable(result.content),
                isError: result.isError
            )

            return SessionEvent(type: .toolResult, toolResult: toolResult)

        } catch {
            let errorResult = ToolResultEvent(
                toolUseId: toolUse.toolUseId ?? UUID().uuidString,
                toolOutput: AnyCodable(error.localizedDescription),
                isError: true
            )

            return SessionEvent(type: .toolResult, toolResult: errorResult)
        }
    }

    // MARK: - Session Management

    private func createSession(agentId: String, environmentId: String) async throws -> Session {
        do {
            let params = CreateSessionParams(
                agentId: agentId,
                agentVersion: nil,
                environmentId: environmentId
            )
            return try await client.createSession(params)
        } catch {
            throw RuntimeError.sessionCreationFailed(error.localizedDescription)
        }
    }

    /// List available sessions
    public func listSessions(agentId: String? = nil) async throws -> [Session] {
        let response = try await client.listSessions(agentId: agentId)
        return response.data
    }

    /// Get session history
    public func getSessionHistory(sessionId: String) async throws -> [SessionEvent] {
        return try await client.getEvents(sessionId: sessionId)
    }

    /// Cancel a running session
    public func cancelSession(sessionId: String) async throws {
        try await client.deleteSession(id: sessionId)
    }

    // MARK: - Agent & Environment Helpers

    /// Get agent details
    public func getAgent(id: String) async throws -> Agent {
        return try await client.getAgent(id: id)
    }

    /// List available agents
    public func listAgents() async throws -> [Agent] {
        let response = try await client.listAgents()
        return response.data
    }

    /// Get environment details
    public func getEnvironment(id: String) async throws -> AgentEnvironment {
        return try await client.getEnvironment(id: id)
    }

    /// List available environments
    public func listEnvironments() async throws -> [AgentEnvironment] {
        let response = try await client.listEnvironments()
        return response.data
    }

    /// Create a default environment for a session
    public func createDefaultEnvironment(name: String) async throws -> AgentEnvironment {
        let params = CreateEnvironmentParams(
            name: name,
            description: "Default environment for \(name)"
        )
        return try await client.createEnvironment(params)
    }
}

// MARK: - Stream Result

public struct StreamResult: Sendable {
    public let sessionId: String
    public let finalMessage: String
    public let toolCalls: Int
    public let iterations: Int
}
