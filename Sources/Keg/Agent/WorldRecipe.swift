import Foundation
import KegCLICore

/// Reference to the git repository an agent session works on.
public struct RepoRef: Codable, Sendable, Equatable {
    public var url: String
    public var branch: String
    public var commit: String

    public init(url: String, branch: String, commit: String) {
        self.url = url
        self.branch = branch
        self.commit = commit
    }
}

public enum WorldRecipeError: Error, Equatable {
    case emptyRepo
    case invalidKegYAML(String)
    case secretEnvKey(String)
}

/// The portable description of an agent's world: enough to recreate the
/// environment anywhere (locally on Keg, or later in a cloud sandbox).
/// Serializable by design — this is the payload that "Continue in Cloud" pushes.
///
/// Secrets are deliberately excluded: env values must not look like
/// credentials, because the recipe leaves the machine.
public struct WorldRecipe: Codable, Sendable, Equatable {
    public var repo: RepoRef
    public var kegYAML: String
    public var env: [String: String]
    public var databases: [String]

    public init(repo: RepoRef, kegYAML: String, env: [String: String] = [:], databases: [String] = []) {
        self.repo = repo
        self.kegYAML = kegYAML
        self.env = env
        self.databases = databases
    }

    public func validate() throws {
        guard !repo.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldRecipeError.emptyRepo
        }

        let config: KegProjectConfig
        do {
            config = try KegProjectLoader.parse(text: kegYAML, directory: NSTemporaryDirectory())
        } catch {
            throw WorldRecipeError.invalidKegYAML(String(describing: error))
        }
        guard !config.services.isEmpty else {
            throw WorldRecipeError.invalidKegYAML("keg.yaml declares no services")
        }

        for key in env.keys where Self.isSecretLike(key) {
            throw WorldRecipeError.secretEnvKey(key)
        }
    }

    /// Parse the embedded keg.yaml through the real project loader.
    public func parsedKegYAML() throws -> KegProjectConfig {
        try KegProjectLoader.parse(text: kegYAML, directory: NSTemporaryDirectory())
    }

    /// True for env keys that must never travel with a pushed recipe.
    static func isSecretLike(_ key: String) -> Bool {
        let upper = key.uppercased()
        if upper.contains("SECRET") || upper.contains("PASSWORD") { return true }
        for suffix in ["_TOKEN", "_KEY", "_PASS", "_PWD"] where upper.hasSuffix(suffix) {
            return true
        }
        return false
    }
}
