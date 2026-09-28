import Foundation

/// A recursive JSON value that is `Sendable` and `Codable` — used for tool
/// JSON schemas and request-body building, where `JSONSerialization`'s
/// `Any` trees would fight Swift 6 strict concurrency.
enum CooperJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CooperJSONValue])
    case object([String: CooperJSONValue])
    case null

    init(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .int(value)
        case let value as Double where value.isFinite: self = .double(value)
        case let value as [Any]: self = .array(value.map(Self.init(any:)))
        case let value as [String: Any]:
            self = .object(Dictionary(uniqueKeysWithValues: value.map { ($0, Self.init(any: $1)) }))
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        case .null: try container.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CooperJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CooperJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    static func schema(_ description: String, type: String, enumValues: [String]? = nil, arrayItems: CooperJSONValue? = nil) -> CooperJSONValue {
        var object: [String: CooperJSONValue] = [
            "description": .string(description),
            "type": .string(type),
        ]
        if let enumValues {
            object["enum"] = .array(enumValues.map(CooperJSONValue.string))
        }
        if let arrayItems {
            object["items"] = arrayItems
        }
        return .object(object)
    }

    static func objectSchema(_ properties: [String: CooperJSONValue], required: [String] = []) -> CooperJSONValue {
        var object: [String: CooperJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map(CooperJSONValue.string))
        }
        return .object(object)
    }
}

/// Thrown by argument decoding when the model emitted malformed tool
/// arguments; the caller stringifies it back into the tool result so the
/// model can correct course.
struct CooperToolArgumentError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
