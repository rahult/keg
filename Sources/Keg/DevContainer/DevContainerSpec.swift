import Foundation

// MARK: - devcontainer.json spec model

struct DevContainerSpec: Codable {
    let name: String?
    let image: String?
    let dockerFile: String?
    let context: String?
    let build: DevContainerBuild?
    let forwardPorts: [DevContainerPort]?
    let containerEnv: [String: String]?
    let remoteEnv: [String: String]?
    let mounts: [String]?
    let workspaceFolder: String?
    let workspaceMount: String?
    let runArgs: [String]?
    let postCreateCommand: String?
    let postStartCommand: String?
    let features: [String: AnyCodable]?
    let customizations: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case name, image, dockerFile, context, build
        case forwardPorts, containerEnv, remoteEnv
        case mounts, workspaceFolder, workspaceMount
        case runArgs, postCreateCommand, postStartCommand
        case features, customizations
    }

    /// Resolved image reference: explicit image, or built from dockerFile
    var resolvedImage: String? {
        image ?? build?.tag
    }

    /// Whether this spec uses a Dockerfile instead of a pre-built image
    var usesDockerfile: Bool {
        dockerFile != nil || build?.dockerfile != nil
    }
}

struct DevContainerBuild: Codable {
    let dockerfile: String?
    let context: String?
    let tag: String?
    let args: [String: String]?
    let target: String?
}

enum DevContainerPort: Codable {
    case int(Int)
    case string(String)

    var displayValue: String {
        switch self {
        case .int(let value): return "\(value)"
        case .string(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(DevContainerPort.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Int or String"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

// AnyCodable is defined in DockerTypes.swift — shared across the target
