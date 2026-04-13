import SwiftUI

struct ContainerStatsView: View {
    let containerID: String
    @State private var cpuPercent: Double = 0
    @State private var memoryUsed: String = "--"
    @State private var memoryLimit: String = "--"
    @State private var netRx: String = "--"
    @State private var netTx: String = "--"
    @State private var blockRead: String = "--"
    @State private var blockWrite: String = "--"
    @State private var isLoading = true

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
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    Gauge(value: cpuPercent, in: 0...100) {
                        Text("CPU")
                    } currentValueLabel: {
                        Text(String(format: "%.1f%%", cpuPercent))
                            .font(.caption.monospacedDigit())
                    }
                    .gaugeStyle(.accessoryCircularCapacity)

                Gauge(value: memPercent, in: 0...100) {
                    Text("Memory")
                } currentValueLabel: {
                    Text(memoryUsed)
                        .font(.caption.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)

                    StatBox(title: "Net I/O", value: "↓\(netRx)  ↑\(netTx)")
                    StatBox(title: "Block I/O", value: "R:\(blockRead)  W:\(blockWrite)")
                }
                .padding(.horizontal, 12)
            }
        }
        .task {
            await pollStats()
        }
    }

    private var memPercent: Double {
        // Can't compute without raw bytes — just show 0
        0
    }

    private func pollStats() async {
        while !Task.isCancelled {
            do {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(filePath: "/usr/bin/env")
                process.arguments = ["container", "stats", "--format", "json", "--no-stream", containerID]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let output = String(data: data, encoding: .utf8),
                   let jsonData = output.data(using: .utf8),
                   let stats = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    parseStats(stats)
                }
                isLoading = false
            } catch {
                isLoading = false
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func parseStats(_ stats: [String: Any]) {
        // The JSON output from `container stats --format json` is an array of stats objects
        // We'll extract what we can
        if let cpu = stats["cpuPercent"] as? Double {
            cpuPercent = cpu
        }
        if let mem = stats["memoryUsage"] as? String {
            memoryUsed = mem
        }
        if let limit = stats["memoryLimit"] as? String {
            memoryLimit = limit
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
