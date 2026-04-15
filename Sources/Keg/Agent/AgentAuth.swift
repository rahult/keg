import Foundation
import LocalAuthentication
import Security

/// Secure API key storage using macOS Keychain
public actor AgentAuth {
    private static let service = "com.keg.managed-agents"
    private static let accountKey = "api-key"
    private static let migrationVersion = "v1"

    private static var migrationDefaultsKey: String {
        "AgentAuth.apiKeyMigration.\(migrationVersion).\(Bundle.main.bundleIdentifier ?? service)"
    }

    // MARK: - Keychain Operations

    /// Store API key in Keychain
    /// - Parameter apiKey: The API key to store securely
    public static func storeAPIKey(_ apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw AgentAuthError.encodingFailed
        }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw AgentAuthError.keychainError(status)
        }

        UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
    }

    /// Retrieve API key from Keychain
    /// - Returns: The stored API key
    public static func retrieveAPIKey() throws -> String {
        try migrateAPIKeyIfNeeded()
        return try loadAPIKey()
    }

    /// Delete API key from Keychain
    public static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AgentAuthError.keychainError(status)
        }

        UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
    }

    /// Check if API key exists in Keychain without triggering auth UI
    public static func hasAPIKey() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Re-save existing API key under current app identity.
    /// This may prompt once if old item ACL requires confirmation.
    public static func migrateAPIKeyIfNeeded() throws {
        guard !UserDefaults.standard.bool(forKey: migrationDefaultsKey) else { return }
        guard hasAPIKey() else {
            UserDefaults.standard.removeObject(forKey: migrationDefaultsKey)
            return
        }

        let apiKey = try loadAPIKey()
        try storeAPIKey(apiKey)
        UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
    }

    private static func loadAPIKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw AgentAuthError.keyNotFound
            }
            throw AgentAuthError.keychainError(status)
        }

        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            throw AgentAuthError.decodingFailed
        }

        return apiKey
    }
}

// MARK: - Error Types

public enum AgentAuthError: Error, LocalizedError {
    case keyNotFound
    case keychainError(OSStatus)
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .keyNotFound:
            return "API key not found in Keychain"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode API key"
        case .decodingFailed:
            return "Failed to decode API key"
        }
    }
}
