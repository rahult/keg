import Foundation
import ContainerAPIClient
import ContainerResource

/// Keg metrics service for dashboard
actor SystemMetrics {
    static let shared = SystemMetrics()

    struct Metrics: Sendable {
        var cpuUsagePercent: Double = 0
        var memoryUsedGB: Double = 0
        var memoryTotalGB: Double = 0
        var memoryUsagePercent: Double = 0
        var diskUsedGB: Double = 0
        var diskTotalGB: Double = 0
        var diskUsagePercent: Double = 0
        var containerCount: Int = 0
        var totalContainerCount: Int = 0
        var imageCount: Int = 0
        var activeImageCount: Int = 0
        var latencyMs: Double = 0
        var timestamp: Date = Date()
    }

    private struct CPUSample: Sendable {
        let usageUsec: UInt64
        let timestamp: Date
    }

    private let bytesPerGB = 1_073_741_824.0
    private let cacheInterval: TimeInterval = 2.0
    private let containerClient = ContainerClient()

    private var cachedMetrics: Metrics?
    private var lastFetch: Date?
    private var previousCPUSamples: [String: CPUSample] = [:]

    func getMetrics(forceRefresh: Bool = false) async -> Metrics {
        if !forceRefresh,
           let cached = cachedMetrics,
           let last = lastFetch,
           Date().timeIntervalSince(last) < cacheInterval {
            return cached
        }

        var metrics = Metrics()
        metrics.timestamp = Date()
        populateHostCapacity(&metrics)
        await populateKegUsage(&metrics)
        metrics.latencyMs = await measureLatency()

        cachedMetrics = metrics
        lastFetch = Date()
        return metrics
    }

    private func populateHostCapacity(_ metrics: inout Metrics) {
        metrics.memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB

        do {
            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            let values = try homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey])
            if let total = values.volumeTotalCapacity {
                metrics.diskTotalGB = Double(total) / bytesPerGB
            }
        } catch {
            metrics.diskTotalGB = 0
        }
    }

    private func populateKegUsage(_ metrics: inout Metrics) async {
        let now = metrics.timestamp
        let hostCPUCount = max(hostLogicalCPUCount(), 1)

        do {
            let containers = try await containerClient.list(filters: .all)
            let runningContainers = containers.filter { $0.status == .running }
            let activeImageReferences = Set(containers.map(\.configuration.image.reference))

            metrics.totalContainerCount = containers.count
            metrics.containerCount = runningContainers.count

            var totalMemoryBytes: UInt64 = 0
            var totalCPUPercent: Double = 0

            for container in runningContainers {
                do {
                    let stats = try await containerClient.stats(id: container.id)

                    if let used = stats.memoryUsageBytes {
                        totalMemoryBytes += used
                    }

                    if let cpuUsageUsec = stats.cpuUsageUsec {
                        totalCPUPercent += cpuPercent(
                            containerID: container.id,
                            cpuUsageUsec: cpuUsageUsec,
                            timestamp: now,
                            hostCPUCount: hostCPUCount
                        )
                    } else {
                        previousCPUSamples.removeValue(forKey: container.id)
                    }
                } catch {
                    previousCPUSamples.removeValue(forKey: container.id)
                }
            }

            previousCPUSamples = previousCPUSamples.filter { sample in
                runningContainers.contains { $0.id == sample.key }
            }

            metrics.cpuUsagePercent = min(max(totalCPUPercent, 0), 100)
            metrics.memoryUsedGB = Double(totalMemoryBytes) / bytesPerGB
            if metrics.memoryTotalGB > 0 {
                metrics.memoryUsagePercent = (metrics.memoryUsedGB / metrics.memoryTotalGB) * 100
            }

            await populateImageUsage(&metrics, activeImageReferences: activeImageReferences)
        } catch {
            previousCPUSamples.removeAll()
            await populateImageUsage(&metrics, activeImageReferences: [])
        }
    }

    private func populateImageUsage(_ metrics: inout Metrics, activeImageReferences: Set<String>) async {
        do {
            let usage = try await ClientImage.calculateDiskUsage(activeReferences: activeImageReferences)
            metrics.imageCount = usage.totalCount
            metrics.activeImageCount = usage.activeCount
            metrics.diskUsedGB = Double(usage.totalSize) / bytesPerGB
            if metrics.diskTotalGB > 0 {
                metrics.diskUsagePercent = (metrics.diskUsedGB / metrics.diskTotalGB) * 100
            }
        } catch {
            do {
                let images = try await ClientImage.list()
                metrics.imageCount = images.count
                metrics.activeImageCount = min(activeImageReferences.count, images.count)
            } catch {
                metrics.imageCount = 0
                metrics.activeImageCount = 0
            }
        }
    }

    private func cpuPercent(
        containerID: String,
        cpuUsageUsec: UInt64,
        timestamp: Date,
        hostCPUCount: Int32
    ) -> Double {
        defer {
            previousCPUSamples[containerID] = CPUSample(usageUsec: cpuUsageUsec, timestamp: timestamp)
        }

        guard let previous = previousCPUSamples[containerID], cpuUsageUsec >= previous.usageUsec else {
            return 0
        }

        let elapsedSeconds = timestamp.timeIntervalSince(previous.timestamp)
        guard elapsedSeconds > 0 else { return 0 }

        let cpuDeltaUsec = Double(cpuUsageUsec - previous.usageUsec)
        let hostCapacityUsec = elapsedSeconds * 1_000_000 * Double(hostCPUCount)
        guard hostCapacityUsec > 0 else { return 0 }

        return (cpuDeltaUsec / hostCapacityUsec) * 100
    }

    private func hostLogicalCPUCount() -> Int32 {
        var cpuCount: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &cpuCount, &size, nil, 0)
        return cpuCount
    }

    private func measureLatency() async -> Double {
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try await ClientHealthCheck.ping(timeout: .seconds(2))
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000
        } catch {
            return 0
        }
    }
}
