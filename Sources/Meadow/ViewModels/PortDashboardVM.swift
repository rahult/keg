import Foundation
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class PortDashboardVM {
    struct PortEntry: Identifiable {
        let id = UUID()
        let containerID: String
        let containerName: String
        let hostPort: UInt16
        let containerPort: UInt16
        let url: URL?
        var isConflicted: Bool

        init(containerID: String, containerName: String, hostPort: UInt16, containerPort: UInt16, isConflicted: Bool = false) {
            self.containerID = containerID
            self.containerName = containerName
            self.hostPort = hostPort
            self.containerPort = containerPort
            self.isConflicted = isConflicted

            // Generate URL for HTTP ports
            let httpPorts: Set<UInt16> = [80, 443, 3000, 4000, 5000, 5500, 8000, 8080, 8443, 8888, 9000, 9090]
            if httpPorts.contains(containerPort) || httpPorts.contains(hostPort) {
                let scheme = (containerPort == 443 || containerPort == 8443) ? "https" : "http"
                self.url = URL(string: "\(scheme)://localhost:\(hostPort)")
            } else {
                self.url = nil
            }
        }
    }

    var entries: [PortEntry] = []
    var isLoading = false
    var errorMessage: String?

    private let client = ContainerClient()

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let containers = try await client.list(filters: .all)
            var allEntries: [PortEntry] = []

            for snapshot in containers {
                let name = snapshot.configuration.labels["name"]
                    ?? String(snapshot.id.prefix(12))

                for port in snapshot.configuration.publishedPorts {
                    allEntries.append(PortEntry(
                        containerID: snapshot.id,
                        containerName: name,
                        hostPort: port.hostPort,
                        containerPort: port.containerPort
                    ))
                }
            }

            // Detect conflicts (same hostPort used by different containers)
            let portCounts = Dictionary(grouping: allEntries, by: \.hostPort)
            for i in allEntries.indices {
                allEntries[i].isConflicted = (portCounts[allEntries[i].hostPort]?.count ?? 0) > 1
            }

            entries = allEntries
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
