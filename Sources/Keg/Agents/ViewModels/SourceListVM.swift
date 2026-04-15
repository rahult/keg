import Foundation

/// ViewModel for Source List
@Observable
@MainActor
final class SourceListVM {
    var sources: [AgentSource] = []
    var isLoading = false
    var error: String?
    var searchText = ""

    var filteredSources: [AgentSource] {
        if searchText.isEmpty { return sources }
        return sources.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func load() async {
        // TODO: Load from local storage
    }
}

struct AgentSource: Identifiable, Codable {
    let id: String
    var name: String
    var type: SourceType
    var isEnabled: Bool
    var status: ConnectionStatus

    enum SourceType: String, Codable {
        case mcp
        case rest
        case files
    }

    enum ConnectionStatus: String, Codable {
        case connected
        case disconnected
        case error
        case unknown
    }
}
