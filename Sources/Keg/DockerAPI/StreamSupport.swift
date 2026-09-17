import Foundation
import NIOCore

// MARK: - Docker stream framing

/// Docker's non-TTY stream multiplexing ("stdcopy"): an 8-byte header
/// (stream type, 3 zero bytes, big-endian uint32 payload length) followed
/// by the payload. Stream 1 = stdout, 2 = stderr.
enum DockerStreamType: UInt8 {
    case stdin = 0
    case stdout = 1
    case stderr = 2
}

enum DockerStreamFraming {
    /// Wraps `payload` in a stdcopy frame for the given stream.
    static func frame(_ stream: DockerStreamType, payload: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(stream.rawValue)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt32(payload.count))
        buffer.writeBytes(payload)
        return buffer
    }

    static func frame(_ stream: DockerStreamType, payload: Data) -> ByteBuffer {
        frame(stream, payload: [UInt8](payload))
    }

    static func frame(_ stream: DockerStreamType, string: String) -> ByteBuffer {
        frame(stream, payload: Array(string.utf8))
    }
}

// MARK: - Process line streaming

/// Spawns a process and delivers its combined stdout+stderr line by line,
/// plus the exit code on completion. Lines arrive as they are written —
/// this is what makes `docker pull`-style progress visible live.
enum StreamingProcess {
    /// Thread-safe handle for a running streaming process: the line stream
    /// plus an awaitable exit code. `finish(exitCode:)` is called exactly
    /// once from the process's termination handler.
    final class Output: @unchecked Sendable {
        let lines: AsyncThrowingStream<String, Error>
        private let lock = NSLock()
        private var _exitCode: Int32?
        private var exitCodeWaiters: [CheckedContinuation<Int32, Never>] = []

        init(lines: AsyncThrowingStream<String, Error>) {
            self.lines = lines
        }

        func finish(exitCode code: Int32) {
            lock.lock()
            _exitCode = code
            let waiters = exitCodeWaiters
            exitCodeWaiters.removeAll()
            lock.unlock()
            for waiter in waiters {
                waiter.resume(returning: code)
            }
        }

        func waitForExit() async -> Int32 {
            if let code = cachedExitCode() {
                return code
            }
            return await withCheckedContinuation { continuation in
                if let code = registerWaiter(continuation) {
                    continuation.resume(returning: code)
                }
            }
        }

        private func cachedExitCode() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            return _exitCode
        }

        private func registerWaiter(_ continuation: CheckedContinuation<Int32, Never>) -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            if let code = _exitCode {
                return code
            }
            exitCodeWaiters.append(continuation)
            return nil
        }
    }

    /// Accumulates bytes and extracts complete newline-terminated lines.
    /// Shared between the readability handler's queue and setup, so locked.
    final class LineSplitter: @unchecked Sendable {
        private var buffered = Data()

        /// Splits `data` into complete lines; the tail stays buffered.
        func ingest(_ data: Data) -> [String] {
            buffered.append(data)
            var lines: [String] = []
            while let idx = buffered.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffered[buffered.startIndex..<idx]
                if let line = String(data: Data(lineData), encoding: .utf8) {
                    lines.append(line.trimmingCharacters(in: .newlines))
                }
                buffered = Data(buffered[buffered.index(after: idx)...])
            }
            return lines
        }

        /// Returns any unterminated tail (on EOF).
        func flushTail() -> String? {
            guard !buffered.isEmpty, let line = String(data: buffered, encoding: .utf8) else {
                return nil
            }
            buffered = Data()
            return line.trimmingCharacters(in: .newlines)
        }
    }

    /// Runs `executable` and streams combined stdout+stderr line by line.
    /// - Throws: if the process cannot be spawned.
    static func start(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) throws -> (process: Process, output: Output) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let workingDirectory {
            process.currentDirectoryURL = URL(filePath: workingDirectory)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let (lineStream, lineContinuation) = AsyncThrowingStream<String, Error>.makeStream()
        let output = Output(lines: lineStream)
        let splitter = LineSplitter()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if let tail = splitter.flushTail(), !tail.isEmpty {
                    lineContinuation.yield(tail)
                }
                lineContinuation.finish()
                return
            }
            for line in splitter.ingest(chunk) {
                lineContinuation.yield(line)
            }
        }

        process.terminationHandler = { terminated in
            pipe.fileHandleForReading.readabilityHandler = nil
            output.finish(exitCode: terminated.terminationStatus)
        }

        try process.run()
        return (process, output)
    }
}

// MARK: - Apple CLI progress → Docker progress JSON

/// Apple's `container image pull --progress plain` emits human-oriented
/// lines; the docker CLI needs JSON progress objects. This mapper converts
/// what Apple prints into the closest Docker message for each line.
enum PullProgressMapper {
    /// Maps one line of Apple CLI pull output to a Docker progress message.
    /// Returns nil for lines that carry no useful signal.
    static func message(forLine line: String) -> DockerImageProgressMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Extract a digest/layer id when present (sha256:...) and shorten to
        // the familiar 12-char docker id.
        var layerID: String?
        if let range = trimmed.range(of: "sha256:[0-9a-f]{6,64}", options: .regularExpression) {
            let hex = trimmed[range].replacingOccurrences(of: "sha256:", with: "")
            layerID = String(hex.prefix(12))
        }

        return DockerImageProgressMessage(
            status: trimmed, id: layerID, progressDetail: nil, progress: nil, error: nil, errorDetail: nil
        )
    }
}
