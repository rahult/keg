import Foundation

// MARK: - OAuth Token Types

/// OAuth 2.0 token response
public struct OAuthTokenResponse: Codable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?
    public let refreshToken: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

/// OAuth token storage in Keychain
public struct OAuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let tokenType: String
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case tokenType = "token_type"
        case scope
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    public var isNearExpiry: Bool {
        guard let expiresAt else { return false }
        // Consider expired if less than 5 minutes remaining
        return Date().addingTimeInterval(300) >= expiresAt
    }
}

// MARK: - OAuth Configuration

/// OAuth provider configuration
public struct OAuthProviderConfig: Codable, Sendable {
    public let clientId: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL?
    public let scopes: [String]
    public let redirectUri: URL

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case scopes
        case redirectUri = "redirect_uri"
    }
}

// MARK: - OAuth Manager

/// Manages OAuth 2.0 authentication flows with automatic token refresh
/// Thread-safe actor for concurrent access
public actor OAuthManager {
    private let config: OAuthProviderConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    // Token storage keychain service
    private static let keychainService = "com.keg.oauth"
    private static let tokenKey = "oauth-tokens"

    /// Callback for OAuth redirect handling
    private var authCallback: ((Result<OAuthTokens, Error>) -> Void)?
    private var codeVerifier: String?

    // MARK: - Initialization

    public init(config: OAuthProviderConfig) {
        self.config = config

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - PKCE Helpers

    /// Generate PKCE code verifier (43-128 random characters)
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(64)
            .description
    }

    /// Generate PKCE code challenge from verifier (S256 method)
    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Authorization URL

    /// Generate the authorization URL for user to visit
    /// - Returns: URL string to open in browser
    public func authorizationURL() -> URL? {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri.absoluteString),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: UUID().uuidString),
        ]

        return components.url
    }

    // MARK: - Token Exchange

    /// Exchange authorization code for tokens
    /// - Parameters:
    ///   - code: Authorization code from OAuth callback
    ///   - expectedVerifier: PKCE code verifier for validation
    /// - Returns: OAuth tokens
    public func exchangeCode(
        _ code: String,
        verifier: String? = nil
    ) async throws -> OAuthTokens {
        guard let verifier = verifier ?? codeVerifier else {
            throw OAuthError.missingCodeVerifier
        }

        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectUri.absoluteString,
            "client_id": config.clientId,
            "code_verifier": verifier,
        ]

        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        let tokenResponse = try decoder.decode(OAuthTokenResponse.self, from: data)
        return tokensFromResponse(tokenResponse)
    }

    /// Refresh the access token using refresh token
    public func refreshTokens(_ refreshToken: String) async throws -> OAuthTokens {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientId,
        ]

        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)

        let tokenResponse = try decoder.decode(OAuthTokenResponse.self, from: data)
        return tokensFromResponse(tokenResponse)
    }

    // MARK: - Token Storage

    /// Save tokens to Keychain
    public func saveTokens(_ tokens: OAuthTokens) throws {
        let data = try encoder.encode(tokens)

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenKey,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OAuthError.keychainError(status)
        }
    }

    /// Load tokens from Keychain
    public func loadTokens() throws -> OAuthTokens {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw OAuthError.tokensNotFound
            }
            throw OAuthError.keychainError(status)
        }

        guard let data = result as? Data else {
            throw OAuthError.invalidTokenData
        }

        return try decoder.decode(OAuthTokens.self, from: data)
    }

    /// Delete tokens from Keychain (logout)
    public func deleteTokens() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenKey,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthError.keychainError(status)
        }
    }

    /// Check if tokens exist
    public func hasTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.tokenKey,
            kSecReturnData as String: false,
        ]

        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Token Management with Auto-Refresh

    /// Get a valid access token, refreshing if necessary
    public func getValidAccessToken() async throws -> String {
        guard hasTokens() else {
            throw OAuthError.notAuthenticated
        }

        let tokens = try loadTokens()

        // Check if refresh needed
        if tokens.isNearExpiry, let refresh = tokens.refreshToken {
            let newTokens = try await refreshTokens(refresh)
            try saveTokens(newTokens)
            return newTokens.accessToken
        }

        // Check if expired (no refresh token)
        if tokens.isExpired && tokens.refreshToken == nil {
            throw OAuthError.tokenExpired
        }

        return tokens.accessToken
    }

    // MARK: - Revocation

    /// Revoke the current tokens
    public func revokeTokens() async throws {
        guard let tokens = try? loadTokens() else { return }

        if let refreshToken = tokens.refreshToken {
            await revokeToken(refreshToken)
        }
        await revokeToken(tokens.accessToken)
        try? deleteTokens()
    }

    private func revokeToken(_ token: String) async {
        guard let revocationEndpoint = config.revocationEndpoint else { return }

        var request = URLRequest(url: revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = "token=\(token)&client_id=\(config.clientId)".data(using: .utf8)

        _ = try? await session.data(for: request)
    }

    // MARK: - Helpers

    private func tokensFromResponse(_ response: OAuthTokenResponse) -> OAuthTokens {
        let expiresAt: Date?
        if let expiresIn = response.expiresIn {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            expiresAt = nil
        }

        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: expiresAt,
            tokenType: response.tokenType,
            scope: response.scope
        )
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 400:
            throw OAuthError.invalidRequest("Invalid request parameters")
        case 401:
            throw OAuthError.unauthorized
        case 403:
            throw OAuthError.forbidden
        default:
            throw OAuthError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - OAuth Errors

public enum OAuthError: Error, LocalizedError, Sendable {
    case notAuthenticated
    case missingCodeVerifier
    case invalidResponse
    case invalidRequest(String)
    case unauthorized
    case forbidden
    case httpError(Int)
    case tokenExpired
    case tokensNotFound
    case invalidTokenData
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please complete OAuth flow."
        case .missingCodeVerifier:
            return "Missing PKCE code verifier"
        case .invalidResponse:
            return "Invalid response from OAuth provider"
        case .invalidRequest(let detail):
            return "Invalid request: \(detail)"
        case .unauthorized:
            return "Unauthorized - invalid credentials"
        case .forbidden:
            return "Forbidden - insufficient permissions"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .tokenExpired:
            return "Token expired and cannot be refreshed"
        case .tokensNotFound:
            return "OAuth tokens not found"
        case .invalidTokenData:
            return "Invalid token data"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}

// MARK: - Common Crypto Import

import CommonCrypto
