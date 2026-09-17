import Foundation
import ContainerAPIClient

/// One `docker exec` session, from `POST /containers/{id}/exec` through
/// start, optional resize, and inspect (exit code).
struct ExecSession {
    let id: String
    let containerID: String
    let request: DockerExecCreateRequest
    /// Set when the session has been started; owns the process lifecycle.
    var running: Bool = false
    var exitCode: Int?
    var startedAt: Date?
}

/// Owns all exec sessions for the Docker API server. The XPC process
/// handles live in the bridge; this registry tracks the Docker-visible
/// state (running/exit code) that `/exec/{id}/json` reports.
actor ExecSessionRegistry {
    private var sessions: [String: ExecSession] = [:]
    private var counter = 0

    func create(containerID: String, request: DockerExecCreateRequest) -> String {
        counter += 1
        let id = "exec-\(UUID().uuidString.prefix(8).lowercased())-\(counter)"
        sessions[id] = ExecSession(id: id, containerID: containerID, request: request)
        return id
    }

    func get(id: String) -> ExecSession? {
        sessions[id]
    }

    func markStarted(id: String) {
        guard sessions[id] != nil else { return }
        sessions[id]?.running = true
        sessions[id]?.startedAt = Date()
    }

    func markFinished(id: String, exitCode: Int) {
        guard sessions[id] != nil else { return }
        sessions[id]?.running = false
        sessions[id]?.exitCode = exitCode
    }

    func remove(id: String) {
        sessions.removeValue(forKey: id)
    }

    /// Docker-encoded inspect payload for `/exec/{id}/json`.
    func inspect(id: String) -> DockerExecInspect? {
        guard let session = sessions[id] else { return nil }
        return DockerExecInspect(
            id: session.id,
            running: session.running && session.exitCode == nil,
            exitCode: session.exitCode,
            processConfig: DockerExecProcessConfig(
                tty: session.request.effectiveTTY,
                entrypoint: session.request.cmd?.first ?? "",
                arguments: session.request.cmd?.count ?? 0 > 1 ? Array(session.request.cmd!.dropFirst()) : nil,
                privileged: session.request.privileged
            )
        )
    }
}
