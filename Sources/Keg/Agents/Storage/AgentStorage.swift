import Foundation
import Network

// MARK: - Types

struct AgentSource: Identifiable, Codable {
    let id: String
    var name: String
    var type: SourceType
    var isEnabled: Bool
    var status: ConnectionStatus
    var config: [String: String]

    init(id: String, name: String, type: SourceType, isEnabled: Bool, status: ConnectionStatus, config: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.type = type
        self.isEnabled = isEnabled
        self.status = status
        self.config = config
    }

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

struct AgentSkillItem: Identifiable, Codable {
    let id: String
    var name: String
    var description: String
    var instructions: String
    var examples: String?
    var createdAt: Date
    var updatedAt: Date
}

struct SkillExportFile: Codable {
    let version: String
    let name: String
    let description: String
    let instructions: String
    let examples: String?
}

// MARK: - Storage Service

/// Local JSON file storage for agent data (sources, skills)
/// Stored in ~/Library/Application Support/Keg/Agents/
actor AgentStorage {
    static let shared = AgentStorage()
    
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    private var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Keg/Agents", isDirectory: true)
    }
    
    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }
    
    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: storageDirectory.path) {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Sources
    
    private var sourcesURL: URL { storageDirectory.appendingPathComponent("sources.json") }
    
    func loadSources() throws -> [AgentSource] {
        guard fileManager.fileExists(atPath: sourcesURL.path) else {
            return []
        }
        let data = try Data(contentsOf: sourcesURL)
        return try decoder.decode([AgentSource].self, from: data)
    }
    
    func saveSources(_ sources: [AgentSource]) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(sources)
        try data.write(to: sourcesURL, options: .atomic)
    }
    
    // MARK: - Skills
    
    private var skillsURL: URL { storageDirectory.appendingPathComponent("skills.json") }
    
    func loadSkills() throws -> [AgentSkillItem] {
        guard fileManager.fileExists(atPath: skillsURL.path) else {
            return []
        }
        let data = try Data(contentsOf: skillsURL)
        return try decoder.decode([AgentSkillItem].self, from: data)
    }
    
    func saveSkills(_ skills: [AgentSkillItem]) throws {
        try ensureDirectoryExists()
        let data = try encoder.encode(skills)
        try data.write(to: skillsURL, options: .atomic)
    }
    
    func exportSkill(_ skill: AgentSkillItem) throws -> Data {
        let skillFile = SkillExportFile(
            version: "1.0",
            name: skill.name,
            description: skill.description,
            instructions: skill.instructions,
            examples: skill.examples
        )
        return try encoder.encode(skillFile)
    }
    
    func importSkill(from data: Data) throws -> AgentSkillItem {
        let skillFile = try decoder.decode(SkillExportFile.self, from: data)
        let now = Date()
        return AgentSkillItem(
            id: UUID().uuidString,
            name: skillFile.name,
            description: skillFile.description,
            instructions: skillFile.instructions,
            examples: skillFile.examples,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - Connection Tester

actor SourceConnectionTester {
    static let shared = SourceConnectionTester()
    
    enum TestResult: Sendable {
        case success
        case failure(String)
        case timeout
    }
    
    func testMCPConnection(url: URL, authToken: String?) async -> TestResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 403 {
                    return .success
                }
                return .failure("Server returned status \(httpResponse.statusCode)")
            }
            return .failure("Invalid response")
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                return .timeout
            }
            return .failure(error.localizedDescription)
        }
    }
    
    func testRESTConnection(endpoint: URL, method: String, authToken: String?) async -> TestResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if (200..<300).contains(httpResponse.statusCode) {
                    return .success
                }
                return .failure("Request failed with status \(httpResponse.statusCode)")
            }
            return .failure("Invalid response")
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                return .timeout
            }
            return .failure(error.localizedDescription)
        }
    }
    
    func testFilesConnection(pathPatterns: [String]) async -> TestResult {
        let fileManager = FileManager.default
        
        for pattern in pathPatterns {
            let expandedPath = NSString(string: pattern).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
                return .failure("Path does not exist: \(pattern)")
            }
            guard fileManager.isReadableFile(atPath: expandedPath) else {
                return .failure("No read permission for: \(pattern)")
            }
        }
        return .success
    }
    
    func testSource(_ source: AgentSource) async -> TestResult {
        switch source.type {
        case .mcp:
            guard let urlString = source.config["url"],
                  let url = URL(string: urlString) else {
                return .failure("Invalid MCP server URL")
            }
            return await testMCPConnection(url: url, authToken: source.config["authToken"])
            
        case .rest:
            guard let endpointString = source.config["endpoint"],
                  let endpoint = URL(string: endpointString) else {
                return .failure("Invalid REST endpoint")
            }
            let method = source.config["method"] ?? "GET"
            return await testRESTConnection(endpoint: endpoint, method: method, authToken: source.config["authToken"])
            
        case .files:
            let patternsString = source.config["patterns"] ?? ""
            let patterns = patternsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return await testFilesConnection(pathPatterns: patterns)
        }
    }
}
