import SwiftUI
import ContainerAPIClient
import ContainerResource

struct ContainerStatsView: View {
    let containerID: String
    @State private var stats: ContainerStats?
    @State private var isLoading = true
    @State private var cpuPercent: Double = 0
    @State private var memPercent: Double = 0

    private let client = ContainerClient()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Stats: \(containerID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if isLoading {
                ProgressView()
            } else if stats != nil {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    Gauge(value: cpuPercent, in: 0...100) {
                        Text("CPU")
                    } currentValueLabel: {
                        Text(String(format: "%.1f%%", cpuPercent))
                            .font(.caption.monospacedDigit())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .accessibilityLabel("CPU usage")
                    .accessibilityValue(String(format: "%.1f percent", cpuPercent))

                    Gauge(value: memPercent, in: 0...100) {
                        Text("Memory")
                    } currentValueLabel: {
                        Text(memString)
                            .font(.caption.monospacedDigit())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .accessibilityLabel("Memory usage")
                    .accessibilityValue(memString)

                    StatBox(title: "Net I/O", value: netString)
                        .accessibilityLabel("Network I/O")
                        .accessibilityValue(netString)
                    StatBox(title: "Block I/O", value: blockString)
                        .accessibilityLabel("Block I/O")
                        .accessibilityValue(blockString)
                }
                .padding(.horizontal, 12)
            }
        }
        .accessibilityLabel("Container Stats")
        .accessibilityHint("Live resource usage statistics for this container")
        .task {
            await pollStats()
        }
    }

    private var memString: String {
        guard let stats else { return "--" }
        let used = ByteCountFormatter.string(fromByteCount: Int64(stats.memoryUsageBytes ?? 0), countStyle: .memory)
        return used
    }

    private var netString: String {
        guard let stats else { return "--" }
        let rx = ByteCountFormatter.string(fromByteCount: Int64(stats.networkRxBytes ?? 0), countStyle: .file)
        let tx = ByteCountFormatter.string(fromByteCount: Int64(stats.networkTxBytes ?? 0), countStyle: .file)
        return "↓\(rx) ↑\(tx)"
    }

    private var blockString: String {
        guard let stats else { return "--" }
        let read = ByteCountFormatter.string(fromByteCount: Int64(stats.blockReadBytes ?? 0), countStyle: .file)
        let write = ByteCountFormatter.string(fromByteCount: Int64(stats.blockWriteBytes ?? 0), countStyle: .file)
        return "R:\(read) W:\(write)"
    }

    private func pollStats() async {
        var prevCpu: UInt64 = 0
        var prevTime = CFAbsoluteTimeGetCurrent()
        while !Task.isCancelled {
            do {
                let current = try await client.stats(id: containerID)
                stats = current

                // Calculate CPU % from cumulative usec delta over actual elapsed time
                let now = CFAbsoluteTimeGetCurrent()
                let elapsedUsec = (now - prevTime) * 1_000_000
                prevTime = now
                if let cpuUsec = current.cpuUsageUsec, elapsedUsec > 0 {
                    let delta = Double(cpuUsec - prevCpu)
                    cpuPercent = min(delta / elapsedUsec * 100, 100)
                    prevCpu = cpuUsec
                }

                // Memory %
                if let used = current.memoryUsageBytes, let limit = current.memoryLimitBytes, limit > 0 {
                    memPercent = Double(used) / Double(limit) * 100
                }

                isLoading = false
            } catch {
                isLoading = false
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

struct StatBox: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
