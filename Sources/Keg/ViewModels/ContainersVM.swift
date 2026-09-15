import Foundation
import ContainerAPIClient
import ContainerResource

/// Derived, display-ready metrics for one container. CPU percent is computed
/// from the delta between consecutive cumulative-usage samples.
struct LiveContainerMetrics: Sendable {
    var cpuPercent: Double
    var memoryUsedBytes: UInt64
    var memoryLimitBytes: UInt64

    var memoryPercent: Double {
        guard memoryLimitBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryLimitBytes) * 100
    }
}

@Observable
@MainActor
final class ContainersVM {
    var containers: [ContainerSnapshot] = []
    var isLoading = false
    var errorMessage: String?
    var showOnlyRunning = false
    var searchText = ""

    /// Live per-container metrics, keyed by container ID. Only running
    /// containers get entries; computed by `startLiveStats` polling.
    var liveMetrics: [String: LiveContainerMetrics] = [:]

    private let client = ContainerClient()
    private var statsTask: Task<Void, Never>?
    private var previousCPU: [String: (usec: UInt64, at: Date)] = [:]

    var filteredContainers: [ContainerSnapshot] {
        let list = showOnlyRunning
            ? containers.filter { $0.status == .running }
            : containers

        guard !searchText.isEmpty else { return list }
        return list.filter {
            $0.id.localizedCaseInsensitiveContains(searchText) ||
            $0.configuration.image.reference.localizedCaseInsensitiveContains(searchText)
        }
    }

    var runningCount: Int {
        containers.filter { $0.status == .running }.count
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Always fetch all containers, filter in filteredContainers
            containers = try await client.list(filters: .all)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop(id: String) async {
        do {
            try await client.stop(id: id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String) async {
        do {
            try await client.delete(id: id, force: true)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func kill(id: String) async {
        do {
            try await client.kill(id: id, signal: SIGKILL)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func start(id: String) async {
        do {
            let (code, out) = try await ContainerCLI.run(["container", "start", id])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to start container" : out
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Apple containers are immutable; "restart" is stop + start via the CLI
    /// (`ContainerClient` has no `start`).
    func restart(id: String) async {
        do {
            try await client.stop(id: id)
            let (code, out) = try await ContainerCLI.run(["container", "start", id])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to restart container" : out
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Live stats polling

    func startLiveStats() {
        guard statsTask == nil else { return }
        statsTask = Task {
            while !Task.isCancelled {
                await pollStatsOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopLiveStats() {
        statsTask?.cancel()
        statsTask = nil
    }

    private func pollStatsOnce() async {
        for container in containers where container.status == .running {
            guard let stats = try? await client.stats(id: container.id) else { continue }
            let usage = stats.cpuUsageUsec ?? 0
            let now = Date()
            var percent: Double = 0
            if let prev = previousCPU[container.id], now.timeIntervalSince(prev.at) > 0 {
                let deltaUsec = Double(usage - prev.usec)
                let elapsed = now.timeIntervalSince(prev.at)
                let cores = max(Double(container.configuration.resources.cpus), 1)
                percent = max(0, min(deltaUsec / (elapsed * 1_000_000 * cores) * 100, 100 * cores))
            }
            previousCPU[container.id] = (usage, now)
            liveMetrics[container.id] = LiveContainerMetrics(
                cpuPercent: percent,
                memoryUsedBytes: stats.memoryUsageBytes ?? 0,
                memoryLimitBytes: stats.memoryLimitBytes ?? 0
            )
        }
        // Drop stale entries for containers that stopped or disappeared
        let valid = Set(containers.filter { $0.status == .running }.map(\.id))
        liveMetrics = liveMetrics.filter { valid.contains($0.key) }
        previousCPU = previousCPU.filter { valid.contains($0.key) }
    }
}
