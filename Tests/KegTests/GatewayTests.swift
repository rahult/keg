// Gateway tests: DNS wire protocol (pure), DNS responder over a real UDP
// socket, route sanitizing/precedence/persistence, and the proxy's live
// relay behavior (GET, 404, 502, WebSocket upgrade) against a raw TCP
// upstream. Real sockets, like AppsStoreTests — run `swift test` unsandboxed.

import XCTest
import NIOCore
import NIOPosix
import NIOSSL
import X509
@testable import Keg

final class GatewayTests: XCTestCase {
    // MARK: - DNS protocol (pure)

    private func queryBytes(name: String, type: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes.append(0)
        bytes += [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return bytes
    }

    private func assertLoopbackAnswer(
        _ response: [UInt8]?, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let answer = try XCTUnwrap(response, "no DNS response", file: file, line: line)
        XCTAssertEqual(answer[3] & 0x0F, 0, "RCODE should be NOERROR", file: file, line: line)
        XCTAssertEqual(Int(answer[7]), 1, "one answer expected", file: file, line: line)
        XCTAssertEqual(Array(answer.suffix(4)), [127, 0, 0, 1], file: file, line: line)
    }

    func testDNSAnswersLoopbackAForZoneHostnames() throws {
        try assertLoopbackAnswer(GatewayDNS.respond(to: queryBytes(name: "memos.keg", type: 1), zone: "keg"))
    }

    func testDNSAnswersLoopbackAForApex() throws {
        try assertLoopbackAnswer(GatewayDNS.respond(to: queryBytes(name: "keg", type: 1), zone: "keg"))
    }

    func testDNSReturnsEmptyNOERRORForAAAAAndHTTPSRecordQueries() throws {
        // Resolvers ask AAAA and browsers ask HTTPS (type 65); an empty
        // NOERROR makes them fall back to the A record.
        for type: UInt16 in [28, 65] {
            let response = try XCTUnwrap(GatewayDNS.respond(to: queryBytes(name: "memos.keg", type: type), zone: "keg"))
            XCTAssertEqual(response[3] & 0x0F, 0)
            XCTAssertEqual(Int(response[7]), 0, "no answers for type \(type)")
        }
    }

    func testDNSReturnsNXDOMAINOffZone() throws {
        let response = try XCTUnwrap(GatewayDNS.respond(to: queryBytes(name: "foo.example.com", type: 1), zone: "keg"))
        XCTAssertEqual(response[3] & 0x0F, 3, "RCODE should be NXDOMAIN")
        XCTAssertEqual(Int(response[7]), 0)
    }

    func testDNSRejectsMalformedQueries() {
        XCTAssertNil(GatewayDNS.respond(to: [], zone: "keg"))
        XCTAssertNil(GatewayDNS.respond(to: [0, 1, 2], zone: "keg"))
        XCTAssertNil(GatewayDNS.respond(to: Array(queryBytes(name: "memos.keg", type: 1).prefix(15)), zone: "keg"))
    }

    // MARK: - DNS responder over a real socket

    func testDNSResponderAnswersOverUDP() async throws {
        let dns = GatewayDNS(port: 0, zone: "keg")
        try dns.start()
        defer { dns.stop() }
        XCTAssertGreaterThan(dns.boundPort, 0)

        let query = queryBytes(name: "memos.keg", type: 1)
        let port = dns.boundPort
        let response = try await Task.detached {
            try UDP.query(query, port: port)
        }.value
        try assertLoopbackAnswer(response)
    }

    // MARK: - Route table

    func testRouteTableAppsWinOverCustomRoutes() {
        let table = GatewayRouteTable()
        table.replace(
            apps: [GatewayRoute(hostname: "memos.keg", port: 1000, label: "Memos")],
            custom: [GatewayRoute(hostname: "memos.keg", port: 2000, label: "override")]
        )
        XCTAssertEqual(table.upstream(for: "memos.keg"), 1000)
    }

    func testRouteTableNormalizesHostnames() {
        let table = GatewayRouteTable()
        table.replace(
            apps: [GatewayRoute(hostname: "memos.keg", port: 1000, label: "Memos")],
            custom: []
        )
        XCTAssertEqual(table.upstream(for: "MEMOS.KEG"), 1000)
        XCTAssertEqual(table.upstream(for: "memos.keg:8080"), 1000)
        XCTAssertEqual(table.upstream(for: "memos.keg."), 1000)
        XCTAssertNil(table.upstream(for: "other.keg"))
        XCTAssertNil(table.upstream(for: "keg"))  // apex is not an app route
        XCTAssertNil(table.upstream(for: ""))
    }

    func testHostnameSanitizer() {
        XCTAssertEqual(GatewayRouteTable.appHostname(forAppID: "memos"), "memos.keg")
        XCTAssertEqual(GatewayRouteTable.appHostname(forAppID: "Uptime-Kuma"), "uptime-kuma.keg")
        XCTAssertEqual(GatewayRouteTable.appHostname(forAppID: "my_app v2!"), "my-app-v2.keg")
        // Labels cap at 63 characters (4 more for ".keg").
        XCTAssertEqual(GatewayRouteTable.appHostname(forAppID: String(repeating: "a", count: 100))!.count, 67)
        XCTAssertNil(GatewayRouteTable.appHostname(forAppID: "---"))
        XCTAssertNil(GatewayRouteTable.appHostname(forAppID: ""))
    }

    func testRouteStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GatewayRouteStore(directory: directory)

        XCTAssertEqual(store.load(), [])
        let routes = [
            GatewayRoute(hostname: "dev.keg", port: 3000, label: "Dev"),
            GatewayRoute(hostname: "api.dev.keg", port: 4000, label: "API"),
        ]
        try store.save(routes)
        // The store persists hostname-sorted for stable files.
        XCTAssertEqual(store.load(), routes.sorted { $0.hostname < $1.hostname })
    }

    // MARK: - Proxy over a real socket

    private func makeProxyRouteTable(upstreamPort: Int) -> GatewayRouteTable {
        let table = GatewayRouteTable()
        table.replace(
            apps: [GatewayRoute(hostname: "memos.keg", port: upstreamPort, label: "Memos")],
            custom: [GatewayRoute(hostname: "dev.keg", port: upstreamPort, label: "Dev")]
        )
        return table
    }

    func testProxyRelaysGETAndAddsForwardedHeaders() async throws {
        let upstream = try TestUpstream { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        }
        try upstream.start()
        defer { upstream.stop() }

        let proxy = GatewayProxy(port: 0, table: makeProxyRouteTable(upstreamPort: Int(upstream.port)))
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let proxyPort = proxy.boundPort

        let response = try await Task.detached {
            try TCP.sendAndCollect(
                payload: Data("GET /hello?x=1 HTTP/1.1\r\nHost: memos.keg\r\nConnection: close\r\n\r\n".utf8),
                port: proxyPort
            )
        }.value

        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("200 OK"), "expected 200, got: \(text.prefix(200))")
        XCTAssertTrue(text.contains("ok"), "expected upstream body, got: \(text.prefix(300))")

        let seen = String(decoding: upstream.captured, as: UTF8.self)
        XCTAssertTrue(seen.contains("GET /hello?x=1 HTTP/1.1"), "upstream saw: \(seen.prefix(300))")
        XCTAssertTrue(seen.contains("Host: memos.keg"), "original Host must reach upstream")
        XCTAssertTrue(seen.contains("X-Forwarded-Host: memos.keg"), "forwarded headers must be added")
        XCTAssertTrue(seen.contains("X-Forwarded-Proto: http"))
    }

    func testProxyReturns404ForUnknownHostname() async throws {
        let proxy = GatewayProxy(port: 0, table: makeProxyRouteTable(upstreamPort: 59999))
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let proxyPort = proxy.boundPort

        let response = try await Task.detached {
            try TCP.sendAndCollect(
                payload: Data("GET / HTTP/1.1\r\nHost: unknown.keg\r\nConnection: close\r\n\r\n".utf8),
                port: proxyPort
            )
        }.value
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("404"))
    }

    func testProxyReturns502WhenUpstreamIsDown() async throws {
        // Bind a port, then release it: connections to it are refused.
        let dead = try TestUpstream { _ in Data() }
        let deadPort = dead.port
        dead.stop()

        let proxy = GatewayProxy(port: 0, table: makeProxyRouteTable(upstreamPort: Int(deadPort)))
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let proxyPort = proxy.boundPort

        let response = try await Task.detached {
            try TCP.sendAndCollect(
                payload: Data("GET / HTTP/1.1\r\nHost: memos.keg\r\nConnection: close\r\n\r\n".utf8),
                port: proxyPort
            )
        }.value
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("502"))
    }

    func testProxyRelaysWebSocketUpgradeBothWays() async throws {
        // First chunk gets a 101 + echo; afterwards raw echo — proving the
        // upgrade response and post-handshake bytes flow both directions.
        let sent101 = SendableBox(false)
        let upstream = try TestUpstream { data in
            var out = Data()
            if !sent101.value {
                out += Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8)
                sent101.value = true
            }
            out += data
            return out
        }
        try upstream.start()
        defer { upstream.stop() }

        let proxy = GatewayProxy(port: 0, table: makeProxyRouteTable(upstreamPort: Int(upstream.port)))
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let proxyPort = proxy.boundPort

        let collected = try await Task.detached {
            try TCP.sendAndCollect(
                payload: Data("GET /ws HTTP/1.1\r\nHost: memos.keg\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".utf8),
                port: proxyPort,
                thenPayload: Data("PING-123\n".utf8),
                untilContains: Data("PING-123\n".utf8)
            )
        }.value

        let text = String(decoding: collected, as: UTF8.self)
        XCTAssertTrue(text.contains("101 Switching Protocols"), "no upgrade relayed: \(text.prefix(200))")
        XCTAssertTrue(text.contains("PING-123"), "post-upgrade bytes must relay both directions")
    }

    // MARK: - Controller

    @MainActor
    func testControllerURLRequiresEnabledRunningAndMatchingRoute() async throws {
        let suiteName = "test.keg.gateway.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let controller = makeController(defaults: suite)
        controller.routeProvider = {
            [GatewayRoute(hostname: "memos.keg", port: 59999, label: "Memos")]
        }

        // Disabled: no URL even with a route.
        XCTAssertNil(controller.url(forAppID: "memos", webUIPath: "/"))

        controller.isEnabled = true
        defer { controller.isEnabled = false }
        try await waitFor { controller.isProxyRunning }
        let proxyPort = try XCTUnwrap(controller.proxyPortInUse)

        let url = try XCTUnwrap(controller.url(forAppID: "memos", webUIPath: "/"))
        XCTAssertEqual(url.host, "memos.keg")
        XCTAssertEqual(url.port, proxyPort)
        XCTAssertEqual(url.absoluteString, "http://memos.keg:\(proxyPort)/")

        // An app with no route gets no gateway URL.
        XCTAssertNil(controller.url(forAppID: "notinstalled", webUIPath: "/"))
    }

    @MainActor
    func testControllerFiltersInvalidCustomRoutes() throws {
        let suiteName = "test.keg.gateway.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let controller = makeController(defaults: suite)
        controller.setCustomRoutes([
            GatewayRoute(hostname: "dev.keg", port: 3000, label: "ok"),
            GatewayRoute(hostname: "bad.keg", port: 80, label: "privileged port"),
            GatewayRoute(hostname: "noport.keg", port: 999_999, label: "out of range"),
            GatewayRoute(hostname: "wrongzone.com", port: 3001, label: "wrong zone"),
        ])
        XCTAssertEqual(controller.validCustomRoutes.map(\.hostname), ["dev.keg"])
        XCTAssertEqual(controller.resolvedPort(for: "dev.keg"), 3000)
        XCTAssertNil(controller.resolvedPort(for: "bad.keg"))
    }

    @MainActor
    private func makeController(defaults: UserDefaults) -> GatewayController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-tests-\(UUID().uuidString)", isDirectory: true)
        deferEnabledCleanup(directory)
        return GatewayController(
            dnsPort: 0, proxyPort: 0,
            routeStore: GatewayRouteStore(directory: directory),
            defaults: defaults
        )
    }

    /// Scratch route directories are unique per controller; sweeping them
    /// all keeps the temp dir tidy without bookkeeping.
    private func deferEnabledCleanup(_ directory: URL) {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func waitFor(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    // MARK: - PKI (HTTPS opt-in)

    private func makeFileKeyStore() -> GatewayFileKeyStore {
        GatewayFileKeyStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("keg-tests-\(UUID().uuidString).key")
        )
    }

    func testPKILoadOrCreateCARoundTripsSameKey() throws {
        let store = makeFileKeyStore()
        defer { try? store.deleteKey() }

        let first = try GatewayPKI.loadOrCreateCA(store: store)
        let second = try GatewayPKI.loadOrCreateCA(store: store)
        XCTAssertEqual(first.privateKey.rawRepresentation, second.privateKey.rawRepresentation)
        // Serial derives from the key, so identity is stable even though
        // validity timestamps follow the wall clock.
        XCTAssertEqual(first.certificate.serialNumber, second.certificate.serialNumber)
        XCTAssertEqual(first.certificate.subject, second.certificate.subject)
        XCTAssertEqual(first.certificate.subject, first.certificate.issuer, "CA is self-signed")
        XCTAssertTrue(first.pem.contains("BEGIN CERTIFICATE"))
    }

    func testPKILeafCoversExactHostnames() throws {
        let ca = try GatewayPKI.loadOrCreateCA(store: makeFileKeyStore())
        let leaf = try GatewayPKI.issueLeaf(ca: ca, hostnames: ["memos.keg", "dev.keg"])

        let sanExtension = try XCTUnwrap(
            leaf.certificate.extensions.first { $0.oid == .X509ExtensionID.subjectAlternativeName },
            "leaf must carry a SAN extension"
        )
        let sans = try X509.SubjectAlternativeNames(sanExtension)
        let dnsNames = sans.compactMap { name -> String? in
            if case .dnsName(let value) = name { return value }
            return nil
        }
        XCTAssertEqual(dnsNames, ["dev.keg", "memos.keg"])
        XCTAssertFalse(dnsNames.contains(where: { $0.hasPrefix("*") }), "wildcards are rejected by macOS — never issue them")
    }

    // MARK: - Trust install (macOS 26 regression)

    /// `security add-trusted-cert` without `-k` exits 0 on macOS 26 but
    /// silently imports nothing — the cert must be imported into the login
    /// keychain explicitly, then trusted there, then confirmed present.
    /// All verbs/flags used here must stay available on every macOS the
    /// app targets (26+) — the regression lived in the *newest* OS, so
    /// newest-API convenience is exactly what to avoid.
    func testTrustInstallPlanImportsThenTrustsInExplicitKeychain() {
        let plan = GatewayTrust.installPlan(
            caCertificatePath: "/tmp/keg-ca.pem",
            loginKeychainPath: "/Users/test/Library/Keychains/login.keychain-db"
        )
        XCTAssertEqual(
            plan.findArguments,
            ["find-certificate", "-c", "Keg Local CA", "/Users/test/Library/Keychains/login.keychain-db"]
        )
        XCTAssertEqual(
            plan.importArguments,
            ["import", "/tmp/keg-ca.pem", "-k", "/Users/test/Library/Keychains/login.keychain-db"]
        )
        XCTAssertEqual(
            plan.trustArguments,
            ["add-trusted-cert", "-k", "/Users/test/Library/Keychains/login.keychain-db",
             "-r", "trustRoot", "-p", "ssl", "/tmp/keg-ca.pem"]
        )
    }

    func testTrustInstallSucceedsOnlyWhenCertIsConfirmable() {
        // Fresh install: import ran and succeeded.
        XCTAssertTrue(
            GatewayTrust.installSucceeded(presentBeforeImport: false, importExit: 0, trustExit: 0, confirmExit: 0)
        )
        // Re-run: pre-check found the CA, import skipped (nil).
        XCTAssertTrue(
            GatewayTrust.installSucceeded(presentBeforeImport: true, importExit: nil, trustExit: 0, confirmExit: 0)
        )
        // The macOS 26 broken flow: every step "succeeds" but the cert is
        // not findable afterwards — must report failure, not green.
        XCTAssertFalse(
            GatewayTrust.installSucceeded(presentBeforeImport: false, importExit: 0, trustExit: 0, confirmExit: 1)
        )
        XCTAssertFalse(
            GatewayTrust.installSucceeded(presentBeforeImport: true, importExit: nil, trustExit: 0, confirmExit: 1)
        )
    }

    func testTrustInstallFailsOnRealImportFailure() {
        XCTAssertFalse(
            GatewayTrust.installSucceeded(
                presentBeforeImport: false,
                importExit: 1,
                trustExit: 0,
                confirmExit: 0
            )
        )
    }

    func testTrustInstallFailsWhenUserDeclines() {
        XCTAssertFalse(
            GatewayTrust.installSucceeded(presentBeforeImport: false, importExit: 0, trustExit: 128, confirmExit: 0)
        )
        XCTAssertFalse(
            GatewayTrust.installSucceeded(presentBeforeImport: true, importExit: nil, trustExit: 128, confirmExit: 0)
        )
    }

    func testKeychainPathNormalizationStripsQuotesAndWhitespace() {
        XCTAssertEqual(
            GatewayTrust.normalizedKeychainPath("  \"/Users/test/Library/Keychains/login.keychain-db\"\n"),
            "/Users/test/Library/Keychains/login.keychain-db"
        )
        XCTAssertEqual(
            GatewayTrust.normalizedKeychainPath(""),
            NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        )
    }

    func testTLSProxyCompletesVerifiedHandshakeAndRelays() async throws {
        let upstream = try TestUpstream { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        }
        try upstream.start()
        defer { upstream.stop() }

        let ca = try GatewayPKI.loadOrCreateCA(store: makeFileKeyStore())
        let leaf = try GatewayPKI.issueLeaf(ca: ca, hostnames: ["memos.keg"])
        let context = try GatewayPKI.serverContext(leaf: leaf)
        let box = GatewayTLSContextBox(context: context)

        let table = GatewayRouteTable()
        table.replace(
            apps: [GatewayRoute(hostname: "memos.keg", port: Int(upstream.port), label: "Memos")],
            custom: []
        )
        let proxy = GatewayProxy(port: 0, table: table, tlsContextBox: box)
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let port = proxy.boundPort

        // The probe validates the chain against the CA anchor and checks the
        // hostname against the SAN — a successful fetch means Safari would
        // trust this too (same verification semantics, spike-proven).
        let response = try await Task.detached {
            try TLSProbe.fetch(
                host: "memos.keg", port: port, caPEM: ca.pem,
                request: "GET /secure HTTP/1.1\r\nHost: memos.keg\r\nConnection: close\r\n\r\n"
            )
        }.value
        XCTAssertTrue(response.contains("200 OK"), "verified TLS relay failed: \(response.prefix(300))")
        XCTAssertTrue(response.contains("ok"))
        XCTAssertTrue(String(decoding: upstream.captured, as: UTF8.self).contains("GET /secure"))
    }

    func testTLSProxyRejectsUnknownHostnameDuringHandshake() async throws {
        let upstream = try TestUpstream { _ in
            Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        }
        try upstream.start()
        defer { upstream.stop() }

        let ca = try GatewayPKI.loadOrCreateCA(store: makeFileKeyStore())
        let leaf = try GatewayPKI.issueLeaf(ca: ca, hostnames: ["memos.keg"])
        let box = GatewayTLSContextBox(context: try GatewayPKI.serverContext(leaf: leaf))

        let table = GatewayRouteTable()
        table.replace(
            apps: [GatewayRoute(hostname: "memos.keg", port: Int(upstream.port), label: "Memos")],
            custom: []
        )
        let proxy = GatewayProxy(port: 0, table: table, tlsContextBox: box)
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let port = proxy.boundPort

        // SNI for a name not on the cert must fail verification — proof the
        // per-hostname leaf model is doing real work.
        let response = try await Task.detached {
            try TLSProbe.fetch(
                host: "other.keg", port: port, caPEM: ca.pem,
                request: "GET / HTTP/1.1\r\nHost: other.keg\r\nConnection: close\r\n\r\n"
            )
        }.value
        XCTAssertFalse(response.contains("200 OK"), "unrelated hostname must not verify")
    }
}

    // MARK: - Raw socket test helpers

/// Minimal UDP query client (blocking, bounded by SO_RCVTIMEO).
private enum UDP {
    static func query(_ bytes: [UInt8], port: UInt16, timeout: TimeInterval = 3) throws -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let sent = bytes.withUnsafeBufferPointer { buffer in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else { return nil }
        var response = [UInt8](repeating: 0, count: 4096)
        let received = recvfrom(fd, &response, response.count, 0, nil, nil)
        guard received > 0 else { return nil }
        return Array(response[0..<received])
    }
}

/// Minimal blocking TCP client used to exercise the proxy with hand-written
/// HTTP, including a second payload after the first exchange (upgrades).
private enum TCP {
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    static func send(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { throw POSIXError(.EIO) }
                sent += n
            }
        }
    }

    /// Sends `payload`, optionally a follow-up payload after a beat, and
    /// collects the reply until it contains `untilContains` or the timeout
    /// fires / the peer closes.
    static func sendAndCollect(
        payload: Data,
        port: Int,
        thenPayload: Data? = nil,
        untilContains: Data? = nil,
        timeout: TimeInterval = 3
    ) throws -> Data {
        let fd = try connect(port: port)
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        try send(fd: fd, data: payload)
        if let thenPayload {
            Thread.sleep(forTimeInterval: 0.3)
            try send(fd: fd, data: thenPayload)
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            collected.append(contentsOf: buffer[0..<n])
            if let untilContains, collected.range(of: untilContains) != nil { break }
        }
        return collected
    }
}

/// Raw-socket TCP server standing in for an app's web server. The `respond`
/// closure maps each received chunk to bytes sent back (empty = silence).
private final class TestUpstream: @unchecked Sendable {
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var received = Data()
    private var listenThread: Thread?
    private let respond: (Data) -> Data
    private(set) var port: UInt16 = 0

    /// Binds 127.0.0.1 on an ephemeral port and listens. Call `start()` to
    /// begin accepting; call `stop()` to release the port.
    init(respond: @escaping (Data) -> Data) throws {
        self.respond = respond
        serverFD = try Self.bindLoopback()
        port = Self.port(of: serverFD)
    }

    private static func bindLoopback() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }
        return fd
    }

    private static func port(of fd: Int32) -> UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "keg-test-upstream"
        thread.stackSize = 1 << 18
        lock.lock()
        listenThread = thread
        lock.unlock()
        thread.start()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = serverFD
            lock.unlock()
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else {
                close(client)
                return
            }
            let chunk = Data(buffer[0..<n])
            lock.lock()
            received.append(chunk)
            lock.unlock()
            let reply = respond(chunk)
            if !reply.isEmpty {
                reply.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    _ = Darwin.send(client, raw.baseAddress, raw.count, 0)
                }
            }
        }
    }

    var captured: Data {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Closes the listening socket; connections already served are theirs.
    func stop() {
        lock.lock()
        let fd = serverFD
        serverFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }
}

/// Mutable value shared across threads.
private final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: T
    init(_ value: T) { raw = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return raw }
        set { lock.lock(); defer { lock.unlock() }; raw = newValue }
    }
}

/// TLS client probe: performs a real handshake with the spike CA as the only
/// trust anchor and hostname verification on (NIOSSL does both), then sends
/// one request and collects the response. A non-empty reply therefore means
/// the certificate is valid for `host` — the same conclusion Safari reaches.
private enum TLSProbe {
    final class CollectHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let collected: SendableBox<String>
        let done: SendableBox<Bool>

        init(collected: SendableBox<String>, done: SendableBox<Bool>) {
            self.collected = collected
            self.done = done
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            collected.value += String(decoding: Self.unwrapInboundIn(data).readableBytesView, as: UTF8.self)
        }

        func channelInactive(context: ChannelHandlerContext) {
            done.value = true
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            done.value = true
            context.close(promise: nil)
        }
    }

    static func fetch(host: String, port: Int, caPEM: String, request: String) throws -> String {
        let anchor = try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates([anchor])
        let context = try NIOSSLContext(configuration: configuration)

        let collected = SendableBox("")
        let done = SendableBox(false)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let handler = CollectHandler(collected: collected, done: done)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                do {
                    let tls = try NIOSSLClientHandler(context: context, serverHostname: host)
                    return channel.pipeline.addHandlers([tls, handler])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try bootstrap.connect(host: "127.0.0.1", port: port).wait()
        var buffer = channel.allocator.buffer(string: request)
        channel.writeAndFlush(NIOAny(buffer), promise: nil)

        let deadline = Date().addingTimeInterval(5)
        while !done.value && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = try? channel.close().wait()
        return collected.value
    }
}
