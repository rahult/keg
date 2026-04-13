import Foundation
import ContainerAPIClient
import ContainerResource

enum SystemStatus: Sendable {
    case running(SystemHealth)
    case stopped
    case error(String)
}

@Observable
@MainActor
final class AppState {
    var systemStatus: SystemStatus = .stopped
    var selectedSection: NavigationSection = .containers
    var selectedContainerID: String?
    var selectedImageReference: String?
    var isRefreshing = false

    private var refreshTimer: Timer?

    var isSystemRunning: Bool {
        if case .running = systemStatus { return true }
        return false
    }

    func checkSystemStatus() async {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(5))
            systemStatus = .running(health)
        } catch {
            systemStatus = .stopped
        }
    }

    func startSystem() async {
        systemStatus = .stopped
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "system", "start"]
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                systemStatus = .error(errorMessage)
                return
            }

            for _ in 0..<30 {
                do {
                    let health = try await ClientHealthCheck.ping(timeout: .seconds(2))
                    systemStatus = .running(health)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            systemStatus = .error("API server did not start within timeout")
        } catch {
            systemStatus = .error(error.localizedDescription)
        }
    }

    func stopSystem() async {
        do {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["container", "system", "stop"]
            try process.run()
            process.waitUntilExit()
            systemStatus = .stopped
        } catch {
            systemStatus = .error(error.localizedDescription)
        }
    }

    func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await checkSystemStatus()
    }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case images = "Images"
    case builds = "Builds"
    case networks = "Networks"
    case volumes = "Volumes"
    case registries = "Registries"
    case settings = "Settings"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .containers: return "cube.box"
        case .images: return "photo.stack"
        case .builds: return "hammer"
        case .networks: return "network"
        case .volumes: return "externaldrive"
        case .registries: return "globe"
        case .settings: return "gearshape"
        }
    }
}
