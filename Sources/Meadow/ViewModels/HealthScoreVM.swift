import Foundation
import ContainerAPIClient
import ContainerResource

struct ContainerHealth: Identifiable {
    let id: String
    let name: String
    let image: String
    let status: RuntimeStatus
    let score: Int
    let memPercent: Double
    let cpuPercent: Double

    var scoreColor: String {
        switch score {
        case 80...100: return "green"
        case 50...79: return "yellow"
        default: return "red"
        }
    }
}

@Observable
@MainActor
final class HealthScoreVM {
    var containerHealths: [ContainerHealth] = []
    var isLoading = false
    var errorMessage: String?

    var overallScore: Int {
        guard !containerHealths.isEmpty else { return 0 }
        let total = containerHealths.reduce(0) { $0 + $1.score }
        return total / containerHealths.count
    }

    var overallScoreColor: String {
        let score = overallScore
        switch score {
        case 80...100: return "green"
        case 50...79: return "yellow"
        default: return "red"
        }
    }

    private let client = ContainerClient()

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let containers = try await client.list(filters: .all)
            var healths: [ContainerHealth] = []

            for container in containers {
                let stats = try? await client.stats(id: container.id)

                let memPercent: Double
                if let used = stats?.memoryUsageBytes, let limit = stats?.memoryLimitBytes, limit > 0 {
                    memPercent = Double(used) / Double(limit) * 100
                } else {
                    memPercent = 0
                }

                let cpuPercent: Double
                if let cpuUsec = stats?.cpuUsageUsec {
                    // Cumulative CPU time, normalize as rough percentage
                    cpuPercent = min(Double(cpuUsec) / 1_000_000, 100)
                } else {
                    cpuPercent = 0
                }

                let name = container.configuration.labels["name"] ?? String(container.id.prefix(12))
                let image = container.configuration.image.reference

                let score = computeScore(
                    status: container.status,
                    memPercent: memPercent,
                    cpuPercent: cpuPercent
                )

                healths.append(ContainerHealth(
                    id: container.id,
                    name: name,
                    image: image,
                    status: container.status,
                    score: score,
                    memPercent: memPercent,
                    cpuPercent: cpuPercent
                ))
            }

            containerHealths = healths
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func computeScore(status: RuntimeStatus, memPercent: Double, cpuPercent: Double) -> Int {
        // Stopped containers get 0
        guard status == .running else { return 0 }

        var score = 100

        // Memory pressure penalties
        if memPercent > 90 {
            score -= 40
        } else if memPercent > 80 {
            score -= 25
        } else if memPercent > 60 {
            score -= 10
        }

        // CPU pressure penalties
        if cpuPercent > 90 {
            score -= 30
        } else if cpuPercent > 70 {
            score -= 15
        }

        return max(score, 0)
    }
}
