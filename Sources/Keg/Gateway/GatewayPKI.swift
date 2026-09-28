// Gateway PKI: a local root CA (created once, key in the login keychain)
// and short-lived leaf certificates covering exactly the hostnames the
// gateway currently routes.
//
// Per-hostname leaves, never a wildcard: macOS Security.framework and curl
// reject `DNS:*.keg` wildcards (errSSLHostNameMismatch) even when the CA is
// fully trusted — explicit SANs pass everywhere (spike-proven). Reissuing on
// route changes is cheap, and no single leaf key unlocks every hostname.

import Crypto
import Foundation
import NIOSSL
import X509

// MARK: - Key storage

protocol GatewayKeyStore: Sendable {
    func saveKey(_ raw: Data) throws
    func loadKey() throws -> Data?
    func deleteKey() throws
}

/// CA private key in the login keychain. A trusted local CA key is real
/// loot — it must not live in a world-readable file next to the certs.
struct GatewayKeychainKeyStore: GatewayKeyStore {
    let service: String
    let account: String

    init(service: String = "dev.rahult.keg.gateway", account: String = "gateway-ca") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func saveKey(_ raw: Data) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = raw
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GatewayError.keychainFailure("add", status)
        }
    }

    func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GatewayError.keychainFailure("read", status)
        }
        return result as? Data
    }

    func deleteKey() throws {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// File-backed store for tests.
final class GatewayFileKeyStore: GatewayKeyStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func saveKey(_ raw: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try raw.write(to: url, options: .atomic)
    }

    func loadKey() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: url)
    }

    func deleteKey() throws {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - CA + leaves

struct GatewayCertificateAuthority: Sendable {
    let certificate: X509.Certificate
    let privateKey: P256.Signing.PrivateKey

    var pem: String { (try? certificate.serializeAsPEM().pemString) ?? "" }
}

struct GatewayLeaf: Sendable {
    let certificate: X509.Certificate
    let privateKey: P256.Signing.PrivateKey
}

enum GatewayPKI {
    static let caLifetime: TimeInterval = 10 * 365 * 24 * 3600
    /// Leaves live under Safari's 825-day TLS validity ceiling.
    static let leafLifetime: TimeInterval = 825 * 24 * 3600

    /// Loads the CA key from `store`, or creates and persists a new CA.
    /// The certificate itself is deterministic given the key (self-signed
    /// from fixed metadata), so it is always re-derivable.
    static func loadOrCreateCA(store: GatewayKeyStore) throws -> GatewayCertificateAuthority {
        if let raw = try store.loadKey() {
            let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
            return GatewayCertificateAuthority(certificate: try selfSignedCA(key: key), privateKey: key)
        }
        let key = P256.Signing.PrivateKey()
        let authority = GatewayCertificateAuthority(certificate: try selfSignedCA(key: key), privateKey: key)
        try store.saveKey(key.rawRepresentation)
        return authority
    }

    static func deleteCA(store: GatewayKeyStore) throws {
        try store.deleteKey()
    }

    private static func selfSignedCA(key: P256.Signing.PrivateKey) throws -> X509.Certificate {
        let name = try DistinguishedName {
            CommonName("Keg Local CA")
            OrganizationName("Keg")
        }
        // Serial derived from the key so a re-derived CA cert is
        // byte-identical — the exported keg-ca.pem never churns.
        let digest = SHA256.hash(data: key.publicKey.rawRepresentation)
        var serial = 0
        for byte in digest.prefix(8) {
            serial = (serial << 8) | Int(byte)
        }
        return try X509.Certificate(
            version: .v3,
            serialNumber: .init(serial & 0x7FFF_FFFF_FFFF_FFFF),
            publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(caLifetime),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try X509.Certificate.Extensions {
                try X509.Certificate.Extension(X509.BasicConstraints.isCertificateAuthority(maxPathLength: nil), critical: true)
            },
            issuerPrivateKey: .init(key)
        )
    }

    /// A leaf covering exactly `hostnames` as DNS SANs.
    static func issueLeaf(ca: GatewayCertificateAuthority, hostnames: [String]) throws -> GatewayLeaf {
        precondition(!hostnames.isEmpty)
        let key = P256.Signing.PrivateKey()
        let subject = try DistinguishedName {
            CommonName(hostnames.sorted().first ?? "keg")
        }
        let sans = X509.SubjectAlternativeNames(hostnames.sorted().map { X509.GeneralName.dnsName($0) })
        let certificate = try X509.Certificate(
            version: .v3,
            serialNumber: .init(Int.random(in: 1...2_000_000_000)),
            publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(leafLifetime),
            issuer: ca.certificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try X509.Certificate.Extensions {
                try X509.Certificate.Extension(X509.BasicConstraints.notCertificateAuthority, critical: true)
                try X509.Certificate.Extension(sans, critical: false)
            },
            issuerPrivateKey: .init(ca.privateKey)
        )
        return GatewayLeaf(certificate: certificate, privateKey: key)
    }

    /// NIO TLS server context from a leaf: http/1.1-only ALPN (browsers
    /// downgrade cleanly; the spike verified the whole chain over h1).
    static func serverContext(leaf: GatewayLeaf) throws -> NIOSSLContext {
        let certificate = try NIOSSLCertificate(
            bytes: Array(leaf.certificate.serializeAsPEM().pemString.utf8), format: .pem
        )
        let privateKey = try NIOSSLPrivateKey(bytes: Array(leaf.privateKey.derRepresentation), format: .der)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(privateKey)
        )
        configuration.applicationProtocols = ["http/1.1"]
        configuration.minimumTLSVersion = TLSVersion.tlsv12
        return try NIOSSLContext(configuration: configuration)
    }
}

// MARK: - Trust

enum GatewayTrust {
    static var caCertificatePath: String {
        GatewayRouteStore.defaultDirectory.appendingPathComponent("keg-ca.pem").path
    }

    /// The command the user could equivalently run themselves. Keg performs
    /// the install on request (no sudo inside it — user-domain trust pops
    /// the system confirmation dialog), but shows the same command so the
    /// user always knows what happened to their trust store.
    static var trustCommand: String {
        "security add-trusted-cert -r trustRoot -p ssl \"\(caCertificatePath)\""
    }

    /// Writes the CA cert where the user (and Firefox) can find it, then
    /// adds it to user-domain SSL trust — which pops the system's mandatory
    /// confirmation dialog. Returns false when the user declines.
    @discardableResult
    static func install(pem: String) async throws -> Bool {
        let directory = GatewayRouteStore.defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try pem.write(toFile: caCertificatePath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", caCertificatePath]
        let exitCode = try await runBounded(process, timeout: 120)
        return exitCode == 0
    }

    /// URLSession probe against the TLS listener — the same CFNetwork trust
    /// evaluation Safari performs.
    static func verify(port: Int, hostname: String) async -> Bool {
        guard let url = URL(string: "https://\(hostname):\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// security(1) with a hard timeout; the dialog can outlive us if the
    /// user walks away, and then the install simply didn't happen.
    private static func runBounded(_ process: Process, timeout: TimeInterval) async throws -> Int32 {
        try process.run()
        return try await withCheckedThrowingContinuation { continuation in
            let watcher = Task.detached {
                _ = try? await Task.sleep(for: .seconds(timeout))
                if process.isRunning {
                    process.terminate()
                }
            }
            process.terminationHandler = { process in
                watcher.cancel()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}
