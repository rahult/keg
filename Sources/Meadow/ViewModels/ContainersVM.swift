import Foundation
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class ContainersVM {
    var containers: [ContainerSnapshot] = []
    var isLoading = false
    var errorMessage: String?
    var showOnlyRunning = false
    var searchText = ""

    private let client = ContainerClient()

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
}
