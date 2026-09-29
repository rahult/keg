import Foundation

/// pi (earendil-works) as an agent brain, via its RPC mode: a long-lived
/// `pi --mode rpc` subprocess in the session workspace, driven over strict
/// JSONL. pi's own session file lives in the workspace, so pi's session
/// continuity (pi-durable) survives across turns.
///
/// Process plumbing is intentionally thin — the protocol-critical pieces
/// (framing, event mapping) live in `PiRPC` and are unit-tested there. A
/// real-process end-to-end test is opt-in via `KEG_RUN_PI_E2E=1` (Tranche 1
/// exit criteria), matching the project's live-test convention.
struct PiBrain: AgentBrain {
    var executablePath: String = "pi"

    enum PiBrainError: Error, LocalizedError {
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .rejected(let message): return "pi rejected the prompt: \(message)"
            }
        }
    }

    /// Mutable parse state shared with the readability handler. The handler
    /// runs on a dispatch queue, so this is an explicit @unchecked Sendable
    /// box rather than captured vars (Swift 6 forbids the latter).
    private final class ParseState: @unchecked Sendable {
        var buffer = Data()
        var settled = false
        var rejection: String?
    }

    func run(prompt: String, workspace: URL) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let process = try Self.launch(executablePath: executablePath, workspace: workspace)

                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe
                    process.standardError = Pipe() // diagnostics; ignored

                    try process.run()

                    let commandId = "prompt-\(UUID().uuidString)"
                    let state = ParseState()

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty, !state.settled else { return }
                        state.buffer.append(chunk)
                        let (records, remainder) = PiRPC.splitRecords(state.buffer)
                        state.buffer = remainder
                        for recordData in records {
                            guard let record = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any] else {
                                continue
                            }
                            // Command failure responses for our prompt are fatal.
                            if record["type"] as? String == "response",
                               record["id"] as? String == commandId,
                               record["success"] as? Bool == false {
                                state.rejection = record["error"] as? String ?? "unknown error"
                                state.settled = true
                                break
                            }
                            if record["type"] as? String == "agent_settled" {
                                state.settled = true
                                break
                            }
                            if let event = PiRPC.mapEvent(record) {
                                continuation.yield(event)
                            }
                        }
                        if state.settled {
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        }
                    }

                    stdinPipe.fileHandleForWriting.write(PiRPC.promptCommand(id: commandId, message: prompt))

                    // Wait for the settled signal (bounded so a wedged pi
                    // can't pin the session forever), then shut down orderly.
                    let deadline = Date().addingTimeInterval(.piBrainTimeout)
                    while !state.settled && Date() < deadline && process.isRunning {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    try? stdinPipe.fileHandleForWriting.close()
                    if process.isRunning {
                        process.terminate()
                    }
                    if let rejection = state.rejection {
                        continuation.finish(throwing: PiBrainError.rejected(rejection))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func launch(executablePath: String, workspace: URL) throws -> Process {
        let process = Process()
        if executablePath.contains("/") {
            process.executableURL = URL(filePath: executablePath)
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [executablePath]
        }
        var arguments = process.arguments ?? []
        arguments += ["--mode", "rpc"]
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        return process
    }
}

extension TimeInterval {
    /// One agent turn against a real provider should not run unbounded.
    static let piBrainTimeout: TimeInterval = 30 * 60
}
