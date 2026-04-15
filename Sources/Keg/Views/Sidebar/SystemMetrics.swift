import Foundation

/// System metrics service for dashboard
actor SystemMetrics {
    struct Metrics: Sendable {
        var cpuUsagePercent: Double = 0
        var memoryUsedGB: Double = 0
        var memoryTotalGB: Double = 0
        var memoryUsagePercent: Double = 0
        var diskUsedGB: Double = 0
        var diskTotalGB: Double = 0
        var diskUsagePercent: Double = 0
        var containerCount: Int = 0
        var imageCount: Int = 0
        var latencyMs: Double = 0
        var timestamp: Date = Date()
    }

    private var cachedMetrics: Metrics?
    private var lastFetch: Date?
    private let cacheInterval: TimeInterval = 2.0 // Refresh every 2 seconds

    func getMetrics(forceRefresh: Bool = false) async -> Metrics {
        if !forceRefresh,
           let cached = cachedMetrics,
           let last = lastFetch,
           Date().timeIntervalSince(last) < cacheInterval {
            return cached
        }

        var metrics = Metrics()
        metrics.timestamp = Date()

        // CPU and Memory from host_info
        await populateCPUMemory(&metrics)

        // Disk from disk_info
        await populateDisk(&metrics)

        // Container counts
        await populateContainerCounts(&metrics)

        // Latency measurement
        metrics.latencyMs = await measureLatency()

        cachedMetrics = metrics
        lastFetch = Date()
        return metrics
    }

    private func populateCPUMemory(_ metrics: inout Metrics) async {
        // Use sysctl for CPU info
        var size = 0
        sysctlbyname("hw.ncpu", nil, &size, nil, 0)
        var cpuCount: Int32 = 0
        sysctlbyname("hw.ncpu", &cpuCount, &size, nil, 0)

        // Get CPU usage via host_processor_info
        var numCPUThreads: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpuInfoUnused: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUThreads,
            &cpuInfo,
            &numCpuInfo
        )

        if result == KERN_SUCCESS, let cpuInfo = cpuInfo {
            var totalUser: Float = 0
            var totalSystem: Float = 0
            var totalIdle: Float = 0

            for i in 0..<Int(numCPUThreads) {
                let offset = Int(CPU_STATE_MAX) * i
                totalUser += Float(cpuInfo[offset + Int(CPU_STATE_USER)])
                totalSystem += Float(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
                totalIdle += Float(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            }

            let total = totalUser + totalSystem + totalIdle
            if total > 0 {
                metrics.cpuUsagePercent = Double((totalUser + totalSystem) / total) * 100
            }

            // Calculate per-CPU average
            metrics.cpuUsagePercent = metrics.cpuUsagePercent / Double(numCPUThreads)

            // Deallocate
            let sizeOfInt = MemoryLayout<integer_t>.stride
            munmap(cpuInfo, Int(numCpuInfo) * sizeOfInt)
        }

        // Memory from host_statistics
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let hostPort = mach_host_self()
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)

            let activeMemory = Double(vmStats.active_count) * pageSize
            let wiredMemory = Double(vmStats.wire_count) * pageSize
            let compressedMemory = Double(vmStats.compressor_page_count) * pageSize

            metrics.memoryUsedGB = (activeMemory + wiredMemory + compressedMemory) / (1024 * 1024 * 1024)
            metrics.memoryTotalGB = totalMemory / (1024 * 1024 * 1024)
            metrics.memoryUsagePercent = (metrics.memoryUsedGB / metrics.memoryTotalGB) * 100
        }
    }

    private func populateDisk(_ metrics: inout Metrics) async {
        // Use FileManager for disk space
        do {
            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            let values = try homeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            if let total = values.volumeTotalCapacity,
               let available = values.volumeAvailableCapacityForImportantUsage {
                metrics.diskTotalGB = Double(total) / (1024 * 1024 * 1024)
                metrics.diskUsedGB = metrics.diskTotalGB - (Double(available) / (1024 * 1024 * 1024))
                metrics.diskUsagePercent = (metrics.diskUsedGB / metrics.diskTotalGB) * 100
            }
        } catch {
            // Use df as fallback
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/df")
            process.arguments = ["-g", homeDirectory]

            let pipe = Pipe()
            process.standardOutput = pipe

            try? process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: "\n")
                if lines.count > 1 {
                    let parts = lines[1].split(separator: " ")
                    if parts.count >= 4,
                       let total = Double(parts[1]),
                       let avail = Double(parts[3]) {
                        metrics.diskTotalGB = total
                        metrics.diskUsedGB = total - avail
                        metrics.diskUsagePercent = (metrics.diskUsedGB / metrics.diskTotalGB) * 100
                    }
                }
            }
        }
    }

    private func populateContainerCounts(_ metrics: inout Metrics) async {
        // Will be updated from AppState
        // Placeholder for now
    }

    private func measureLatency() async -> Double {
        let start = Date()
        // Simple ping-like measurement
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["ok"]

        do {
            try process.run()
            process.waitUntilExit()
            let duration = Date().timeIntervalSince(start) * 1000
            return duration
        } catch {
            return 0
        }
    }
}

// MARK: - Disk Usage Extension

private let homeDirectory: String = {
    FileManager.default.homeDirectoryForCurrentUser.path
}()
