import Foundation

/// Hybrid Agent Runner - Process or Container execution
/// 
/// Optimization: Use process for simple agents, container for dangerous operations
/// - Process: ~5ms latency, ~0MB memory overhead
/// - Container: ~15ms latency, ~10MB memory overhead
actor HybridAgentRunner {
    
    /// Execution mode based on operation risk
    enum Mode: String, Codable, Sendable {
        case process   // Fast, no isolation
        case container // Safe, full isolation
    }
    
    /// Command risk assessment
    enum RiskLevel: String, Codable, Sendable {
        case safe      // Read-only, simple commands
        case moderate  // File system writes
        case dangerous // Network, sudo, rm -rf
    }
    
    /// Execution result
    struct ExecutionResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let mode: Mode
        let durationMs: Int
    }
    
    // MARK: - Public API
    
    /// Execute a command with automatic mode selection
    func execute(command: String) async throws -> ExecutionResult {
        let startTime = Date()
        
        // Auto-select mode based on risk
        let risk = assessRisk(command)
        let mode = selectMode(for: risk)
        
        let result: ExecutionResult
        switch mode {
        case .process:
            result = try await executeInProcess(command: command)
        case .container:
            result = try await executeInContainer(command: command)
        }
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        return ExecutionResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            mode: result.mode,
            durationMs: duration
        )
    }
    
    /// Execute with forced mode
    func execute(command: String, mode: Mode) async throws -> ExecutionResult {
        let startTime = Date()
        
        let result: ExecutionResult
        switch mode {
        case .process:
            result = try await executeInProcess(command: command)
        case .container:
            result = try await executeInContainer(command: command)
        }
        
        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        return ExecutionResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            mode: result.mode,
            durationMs: duration
        )
    }
    
    // MARK: - Risk Assessment
    
    private func assessRisk(_ command: String) -> RiskLevel {
        let lowercased = command.lowercased()
        
        // Dangerous patterns
        let dangerousPatterns = [
            "rm -rf", "rm -fr", "sudo", "chmod 777",
            "dd if=", "mkfs", "fdisk",
            "curl.*|bash", "wget.*|bash", "eval ",
            "nc -e", "bash -i", "> /dev/",
        ]
        
        for pattern in dangerousPatterns {
            if lowercased.contains(pattern) {
                return .dangerous
            }
        }
        
        // Moderate risk (writes)
        let moderatePatterns = [
            ">", ">>", "|", "tee", "cp ", "mv ", "mkdir",
            "touch", "chmod", "chown", "nano", "vim", "vi",
            "echo ", "printf", "rm ", "del "
        ]
        
        for pattern in moderatePatterns {
            if lowercased.contains(pattern) {
                return .moderate
            }
        }
        
        return .safe
    }
    
    private func selectMode(for risk: RiskLevel) -> Mode {
        switch risk {
        case .safe:
            return .process
        case .moderate:
            return .process // Can use process for moderate
        case .dangerous:
            return .container // Must use container
        }
    }
    
    // MARK: - Execution
    
    private func executeInProcess(command: String) async throws -> ExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                let result = ExecutionResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus,
                    mode: .process,
                    durationMs: 0
                )
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private func executeInContainer(command: String) async throws -> ExecutionResult {
        // Use container exec via Process
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["container", "exec", "lightweight-agent", "sh", "-c", command]
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                let result = ExecutionResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus,
                    mode: .container,
                    durationMs: 0
                )
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Lightweight Container Manager

/// Manages a pre-warmed lightweight container
actor LightweightContainerManager {
    private var containerName: String?
    private var isReady = false
    
    /// Pre-warm a container
    func prewarm(name: String = "lightweight-agent", image: String = "alpine:latest") async throws {
        containerName = name
        
        // Delete existing if any
        let deleteProcess = Process()
        deleteProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        deleteProcess.arguments = ["container", "rm", "-f", name]
        try? deleteProcess.run()
        deleteProcess.waitUntilExit()
        
        // Create
        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        createProcess.arguments = ["container", "create", "--name", name, image, "sh"]
        try createProcess.run()
        createProcess.waitUntilExit()
        
        // Start
        let startProcess = Process()
        startProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        startProcess.arguments = ["container", "start", name]
        try startProcess.run()
        startProcess.waitUntilExit()
        
        isReady = true
    }
    
    /// Execute in pre-warmed container
    func exec(command: String) async throws -> String {
        guard let name = containerName, isReady else {
            throw LightweightError.notReady
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["container", "exec", name, "sh", "-c", command]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    enum LightweightError: Error {
        case notReady
    }
}
