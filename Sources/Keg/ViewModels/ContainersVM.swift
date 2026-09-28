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

    /// Recent CPU-percent samples per container (oldest first), for the
    /// inline sparkline in the list's CPU column.
    var cpuHistory: [String: [Double]] = [:]

    /// Fresh client per access: a stored client keeps one xpc_connection_t,
    /// which goes permanently invalid ("Connection invalid") when the
    /// apiserver stops/restarts or wasn't registered yet at creation.
    private var client: ContainerClient { ContainerClient() }
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
            ContainerActivityLog.shared.observe(containers)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `ContainerClient.stop(id:)` fails against container CLI ≥1.3
    /// (request encoding mismatch: "Expected value of type Path; signal"),
    /// so stop via the CLI like start does.
    func stop(id: String) async {
        do {
            let (code, out) = try await ContainerCLI.run(["container", "stop", id])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to stop container" : out
            }
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
            try await client.kill(id: id, signal: "SIGKILL")
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
    /// (`ContainerClient` has no `start`, and its `stop` fails against CLI ≥1.3).
    func restart(id: String) async {
        do {
            let (stopCode, stopOut) = try await ContainerCLI.run(["container", "stop", id])
            if stopCode != 0 {
                errorMessage = stopOut.isEmpty ? "Failed to stop container" : stopOut
                await refresh()
                return
            }
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
                // Counters reset when a container restarts; subtracting
                // would underflow the UInt64 and trap the app (crash seen
                // 2026-09-25 during app-install churn). Treat a backwards
                // counter as one fresh sample.
                let deltaUsec = Double(usage >= prev.usec ? usage - prev.usec : 0)
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
            var history = cpuHistory[container.id] ?? []
            history.append(percent)
            if history.count > 30 {
                history.removeFirst(history.count - 30)
            }
            cpuHistory[container.id] = history
        }
        // Drop stale entries for containers that stopped or disappeared
        let valid = Set(containers.filter { $0.status == .running }.map(\.id))
        liveMetrics = liveMetrics.filter { valid.contains($0.key) }
        previousCPU = previousCPU.filter { valid.contains($0.key) }
        cpuHistory = cpuHistory.filter { valid.contains($0.key) }
    }
}
