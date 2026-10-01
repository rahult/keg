import Foundation
import KegCLICore

// MARK: - New session draft (pure logic behind NewAgentSessionSheet)

enum AgentSessionRepoMode: String, CaseIterable, Identifiable, Sendable {
    case localFolder = "Local folder"
    case gitURL = "Git URL"

    var id: String { rawValue }
}

enum AgentSessionBrainChoice: String, CaseIterable, Identifiable, Sendable {
    case auto = "Automatic"
    case cooper = "Cooper"
    case pi = "pi"

    var id: String { rawValue }

    /// `AgentService` only models concrete brains; Automatic picks the
    /// production default (Cooper's remote backend behind the shared
    /// permission gate).
    var resolved: AgentService.BrainKind {
        switch self {
        case .auto, .cooper: return .cooper
        case .pi: return .pi
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Cooper, or the best available brain."
        case .cooper: return "Cooper's remote backend (any OpenAI-compatible server), behind Keg's permission gate."
        case .pi: return "The pi coding agent, run over its RPC protocol."
        }
    }
}

struct AgentSessionEnvEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var key: String = ""
    var value: String = ""
}

/// The form state behind "New Session…": repo source, non-secret env,
/// keg.yaml text, brain choice, and the optional first instruction. All
/// validation lives here (not in the view) so it is unit-testable; the
/// sheet only renders it.
struct AgentSessionDraft: Equatable, Sendable {
    enum DraftError: Error, Equatable, LocalizedError {
        case folderMissing(String)
        case envKey(String, String)

        var errorDescription: String? {
            switch self {
            case .folderMissing(let path):
                return "The folder “\(path)” doesn't exist. Choose a local folder or switch to a Git URL."
            case .envKey(let key, let problem):
                return "Environment variable “\(key)”: \(problem)"
            }
        }
    }

    static let defaultPrompt = "Get oriented: inspect the workspace and summarize what you find."

    var repoMode: AgentSessionRepoMode = .localFolder
    var localPath = ""
    var gitURL = ""
    var branch = "main"
    var env: [AgentSessionEnvEntry] = []
    var kegYAML = AgentSessionDraft.strippingPorts(from: KegProjectScaffold.template(for: .generic, projectName: "keg-project"))
    var brain: AgentSessionBrainChoice = .auto
    var instruction = ""

    var repoURL: String {
        let raw = repoMode == .localFolder ? localPath : gitURL
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedBranch: String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    var canStart: Bool { !repoURL.isEmpty }

    /// nil when the key is acceptable; empty keys are allowed (the row is
    /// ignored). Reuses the recipe's secret heuristic so the UI and the
    /// validator can never disagree.
    static func envKeyProblem(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return "use letters, numbers, and underscores, starting with a letter."
        }
        if WorldRecipe.isSecretLike(trimmed) {
            return "this looks like a secret — world recipes never carry credentials."
        }
        return nil
    }

    /// Build the validated world recipe, or throw a user-facing error.
    func makeRecipe() throws -> WorldRecipe {
        if repoMode == .localFolder {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: repoURL, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DraftError.folderMissing(repoURL)
            }
        }

        var envDict: [String: String] = [:]
        for entry in env {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if let problem = Self.envKeyProblem(key) {
                throw DraftError.envKey(key, problem)
            }
            envDict[key] = entry.value
        }

        let recipe = WorldRecipe(
            repo: RepoRef(url: repoURL, branch: trimmedBranch, commit: ""),
            kegYAML: kegYAML,
            env: envDict
        )
        try recipe.validate()
        return recipe
    }

    /// The first turn's prompt: the user's instruction, or a neutral
    /// orientation prompt when they left the field empty.
    func makePrompt() -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPrompt : trimmed
    }

    /// Scaffold keg.yaml from a stack hint, named after the repo when known.
    /// Session worlds publish no ports: the shared templates suggest fixed
    /// ports (3000/8080/…) that collide with whatever already holds them
    /// (the Gateway proxy, another session's world), and the runtime fails
    /// the whole provision on the bind error — so strip them here rather
    /// than fail every session on a busy Mac.
    func scaffoldedYAML(_ stack: KegProjectScaffold.Stack) -> String {
        Self.strippingPorts(from: KegProjectScaffold.template(for: stack, projectName: Self.projectName(for: repoURL)))
    }

    /// Remove every `ports:` mapping (block or inline style, with its list
    /// items) from a scaffold template. Templates are simple and known, so
    /// line-based filtering is enough; users can still add ports by hand
    /// in the sheet's editor (and accept the collision risk).
    static func strippingPorts(from yaml: String) -> String {
        func indent(of line: Substring) -> Int {
            line.prefix(while: { $0 == " " }).count
        }
        var result: [Substring] = []
        var skippingBeyond: Int?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let beyond = skippingBeyond {
                if !trimmed.isEmpty && indent(of: line) <= beyond {
                    skippingBeyond = nil
                    result.append(line)
                }
                // blank or deeper-indented line inside the ports block: drop
            } else if trimmed.hasPrefix("ports:") {
                skippingBeyond = indent(of: line)
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    static func projectName(for repoURL: String) -> String {
        let last = repoURL
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".git", with: "") ?? ""
        let sanitized = KegProjectLoader.sanitizeName(last)
        return sanitized.isEmpty ? "keg-project" : sanitized
    }
}
