import Foundation
import ContainerResource

@Observable
@MainActor
final class MetricsHistoryVM {
    struct MetricPoint: Identifiable {
        let id = UUID()
        let timestamp: Date
        let value: Double
    }

    var cpuHistory: [MetricPoint] = []
    var memoryHistory: [MetricPoint] = []
    var networkRxHistory: [MetricPoint] = []
    var networkTxHistory: [MetricPoint] = []

    let maxPoints = 60

    func addSample(stats: ContainerStats) {
        // CPU
        if let usage = stats.cpuUsageUsec {
            // Store cumulative CPU time in seconds for display as delta
            let cpuSeconds = Double(usage) / 1_000_000
            append(&cpuHistory, MetricPoint(timestamp: Date(), value: cpuSeconds))
        }

        // Memory
        if let used = stats.memoryUsageBytes, let limit = stats.memoryLimitBytes, limit > 0 {
            let pct = Double(used) / Double(limit) * 100
            append(&memoryHistory, MetricPoint(timestamp: Date(), value: pct))
        }

        // Network
        if let rx = stats.networkRxBytes {
            append(&networkRxHistory, MetricPoint(timestamp: Date(), value: Double(rx)))
        }
        if let tx = stats.networkTxBytes {
            append(&networkTxHistory, MetricPoint(timestamp: Date(), value: Double(tx)))
        }
    }

    private func append(_ array: inout [MetricPoint], _ point: MetricPoint) {
        array.append(point)
        if array.count > maxPoints {
            array.removeFirst(array.count - maxPoints)
        }
    }

    var cpuDelta: Double? {
        guard cpuHistory.count >= 2 else { return nil }
        let prev = cpuHistory[cpuHistory.count - 2]
        let curr = cpuHistory[cpuHistory.count - 1]
        let elapsed = curr.timestamp.timeIntervalSince(prev.timestamp)
        guard elapsed > 0 else { return nil }
        return (curr.value - prev.value) / elapsed * 100 // percentage of 1 core
    }

    var memoryPercent: Double? {
        memoryHistory.last?.value
    }

    var networkRxRate: Double? {
        ratePerSecond(from: networkRxHistory)
    }

    var networkTxRate: Double? {
        ratePerSecond(from: networkTxHistory)
    }

    private func ratePerSecond(from points: [MetricPoint]) -> Double? {
        guard points.count >= 2 else { return nil }
        let prev = points[points.count - 2]
        let curr = points[points.count - 1]
        let elapsed = curr.timestamp.timeIntervalSince(prev.timestamp)
        guard elapsed > 0 else { return nil }
        return (curr.value - prev.value) / elapsed
    }
}
