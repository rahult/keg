// GatewayController owns the gateway's loopback services — the DNS
// responder and the Host-routing proxy — and the state the Settings tab
// renders. Hostnames only resolve once /etc/resolver/keg points at the
// responder; Keg surfaces that one-time command rather than running it
// (Keg never elevates: show the command, let the user run it).

import Foundation
import Observation

/// Loopback endpoints and naming for the gateway. Nonisolated so the DNS
/// and proxy services can use them as defaults and the route table can
/// check the zone off the main actor.
enum GatewayConfig {
    static let zone = "keg"
    static let dnsPort: UInt16 = 15353
    static let proxyPort = 8080
    static let tlsPort = 8443
    static var resolverPath: String { "/etc/resolver/\(zone)" }

    /// The one-time root step that routes `*.keg` queries to Keg's
    /// responder. Keg surfaces this rather than running it — the app never
    /// elevates.
    static var resolverCommand: String {
        "printf 'nameserver 127.0.0.1\\nport \(dnsPort)\\n' | sudo tee \(resolverPath) >/dev/null"
    }
    static var resolverRemoveCommand: String {
        "sudo rm \(resolverPath)"
    }
}

@MainActor
@Observable
final class GatewayController {
    static let defaultsEnabledKey = "gateway.enabled"

    // MARK: State (rendered by the Settings tab)

    private(set) var isDNSRunning = false
    private(set) var isProxyRunning = false
    private(set) var lastError: String?
    private(set) var customRoutes: [GatewayRoute] = []
    /// Standard-install hostnames the apps store currently exposes.
    private(set) var appRoutes: [GatewayRoute] = []

    /// Set by AppState so app routes follow the Apps store without a
    /// reference cycle.
    var routeProvider: (@MainActor () -> [GatewayRoute])?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.defaultsEnabledKey)
            if isEnabled {
                start()
                if isHTTPSPermitted { Task { await configureTLS() } }
            } else {
                stop()
            }
        }
    }

    /// HTTPS opt-in: terminating TLS on 8443 with a locally-issued
    /// per-hostname certificate. Off until the user turns it on.
    var isHTTPSPermitted = false {
        didSet {
            defaults.set(isHTTPSPermitted, forKey: Self.defaultsHTTPSKey)
            guard isEnabled else { return }
            if isHTTPSPermitted {
                Task { await configureTLS() }
            } else {
                stopTLS()
            }
        }
    }
    private static let defaultsHTTPSKey = "gateway.https"

    // MARK: TLS state

    private(set) var isTLSRunning = false
    private(set) var tlsError: String?
    private(set) var caPEM: String?
    @ObservationIgnored private var tlsProxy: GatewayProxy?
    @ObservationIgnored private var tlsBox: GatewayTLSContextBox?
    @ObservationIgnored private var issuedHostnames: Set<String> = []
    @ObservationIgnored private let keyStore: GatewayKeyStore
    @ObservationIgnored private let tlsPort: Int

    @ObservationIgnored private var dns: GatewayDNS?
    @ObservationIgnored private var proxy: GatewayProxy?
    @ObservationIgnored private let routeTable = GatewayRouteTable()
    @ObservationIgnored private let routeStore: GatewayRouteStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dnsPort: UInt16
    @ObservationIgnored private let proxyPort: Int
    @ObservationIgnored private var startGeneration = 0

    /// Ports and stores are injectable so tests run hermetically on
    /// ephemeral ports with a scratch routes file.
    init(
        dnsPort: UInt16 = GatewayConfig.dnsPort,
        proxyPort: Int = GatewayConfig.proxyPort,
        tlsPort: Int = GatewayConfig.tlsPort,
        routeStore: GatewayRouteStore = GatewayRouteStore(),
        keyStore: GatewayKeyStore = GatewayKeychainKeyStore(),
        defaults: UserDefaults = .standard
    ) {
        self.dnsPort = dnsPort
        self.proxyPort = proxyPort
        self.tlsPort = tlsPort
        self.routeStore = routeStore
        self.keyStore = keyStore
        self.defaults = defaults
        defaults.register(defaults: [
            Self.defaultsEnabledKey: false,
            Self.defaultsHTTPSKey: false,
        ])
        isEnabled = defaults.bool(forKey: Self.defaultsEnabledKey)
        isHTTPSPermitted = defaults.bool(forKey: Self.defaultsHTTPSKey)
        customRoutes = routeStore.load()
        rebuildRouteTable()
    }

    // MARK: Lifecycle

    func start() {
        guard isEnabled else { return }
        startGeneration += 1
        let generation = startGeneration
        lastError = nil
        rebuildRouteTable()

        Task { @MainActor in
            // Bind the proxy first: if it fails there is little point in
            // answering DNS for names that 404 anyway.
            let proxy = GatewayProxy(port: proxyPort, table: routeTable)
            do {
                try await proxy.start()
                guard generation == startGeneration, isEnabled else {
                    await proxy.stop()
                    return
                }
                self.proxy = proxy
                isProxyRunning = true
            } catch {
                guard generation == startGeneration else { return }
                self.proxy = nil
                isProxyRunning = false
                lastError = error.localizedDescription
            }

            let dns = GatewayDNS(port: dnsPort, zone: GatewayConfig.zone)
            do {
                try dns.start()
                guard generation == startGeneration, isEnabled else {
                    dns.stop()
                    return
                }
                self.dns = dns
                isDNSRunning = true
            } catch {
                guard generation == startGeneration else { return }
                self.dns = nil
                isDNSRunning = false
                if self.isProxyRunning == false {
                    lastError = error.localizedDescription
                }
            }

            if isHTTPSPermitted {
                await configureTLS()
            }
        }
    }

    func stop() {
        startGeneration += 1
        let proxy = proxy
        dns?.stop()
        self.dns = nil
        self.proxy = nil
        isDNSRunning = false
        isProxyRunning = false
        stopTLS()
        // Group shutdown is async; let it finish in the background. The
        // flags above are already the truth the UI renders.
        if let proxy {
            Task { await proxy.stop() }
        }
    }

    // MARK: TLS (HTTPS opt-in)

    /// Creates/loads the CA, issues a leaf covering the current hostnames,
    /// and keeps the TLS listener on 8443 serving it. Re-run whenever the
    /// hostname set changes: the new context swaps into the box so new
    /// connections get the fresh certificate immediately.
    private func configureTLS() async {
        guard isEnabled, isHTTPSPermitted else { return }
        let hostnames = (appRoutes + validCustomRoutes).map(\.hostname)
        guard !hostnames.isEmpty else {
            stopTLS()
            return
        }
        do {
            let keyStore = keyStore
            let ca = try await Task.detached {
                try GatewayPKI.loadOrCreateCA(store: keyStore)
            }.value
            caPEM = ca.pem
            let leaf = try GatewayPKI.issueLeaf(ca: ca, hostnames: hostnames)
            let context = try GatewayPKI.serverContext(leaf: leaf)

            if tlsBox == nil {
                tlsBox = GatewayTLSContextBox()
            }
            tlsBox?.set(context)
            issuedHostnames = Set(hostnames)

            if let tlsProxy {
                // Listener already bound — the swap above is all that's needed.
                _ = tlsProxy
            } else {
                let newProxy = GatewayProxy(port: tlsPort, table: routeTable, tlsContextBox: tlsBox)
                try await newProxy.start()
                tlsProxy = newProxy
            }
            isTLSRunning = true
            tlsError = nil
        } catch {
            isTLSRunning = false
            tlsError = error.localizedDescription
        }
    }

    private func stopTLS() {
        let proxy = tlsProxy
        tlsProxy = nil
        tlsBox?.set(nil)
        issuedHostnames = []
        isTLSRunning = false
        if let proxy {
            Task { await proxy.stop() }
        }
    }

    /// Adds the CA to the user's SSL trust — the system pops its mandatory
    /// confirmation dialog; returning false means the user declined.
    @discardableResult
    func installCertificateTrust() async throws -> Bool {
        guard let caPEM else {
            throw GatewayError.notRunning
        }
        return try await GatewayTrust.install(pem: caPEM)
    }

    /// Probes the TLS listener through CFNetwork (Safari's trust path).
    func verifyHTTPS() async -> Bool {
        guard let port = tlsProxy?.boundPort else { return false }
        let hostname = appRoutes.first?.hostname ?? validCustomRoutes.first?.hostname ?? "127.0.0.1"
        return await GatewayTrust.verify(port: port, hostname: hostname)
    }

    // MARK: Status

    /// True when /etc/resolver/keg exists and points at our responder port.
    var isResolverConfigured: Bool {
        guard let contents = try? String(contentsOfFile: GatewayConfig.resolverPath, encoding: .utf8) else {
            return false
        }
        return contents.contains("nameserver") && contents.contains(String(dnsPort))
    }

    /// Loopback port the hostname currently forwards to (proxy must be up).
    func resolvedPort(for hostname: String) -> Int? {
        routeTable.upstream(for: hostname)
    }

    /// Port the proxy is actually bound to, when running.
    var proxyPortInUse: Int? {
        proxy?.boundPort
    }

    /// Port the TLS listener is actually bound to, when running.
    var tlsProxyPortInUse: Int? {
        tlsProxy?.boundPort
    }

    /// Number of hostnames the current leaf certificate covers.
    var issuedHostnameCount: Int {
        issuedHostnames.count
    }

    var statusSummary: String {
        switch (isDNSRunning, isProxyRunning) {
        case (true, true): "Running"
        case (false, false): "Stopped"
        default: "Partially running"
        }
    }

    // MARK: Routes

    func setCustomRoutes(_ routes: [GatewayRoute]) {
        customRoutes = routes
        try? routeStore.save(routes)
        rebuildRouteTable()
    }

    /// Pulls app routes from the Apps store and publishes the merged table
    /// to the proxy's threads. While HTTPS is live, a hostname-set change
    /// also reissues the leaf certificate.
    func rebuildRouteTable() {
        appRoutes = routeProvider?() ?? []
        routeTable.replace(apps: appRoutes, custom: validCustomRoutes)

        guard isTLSRunning else { return }
        let hostnames = Set((appRoutes + validCustomRoutes).map(\.hostname))
        if hostnames != issuedHostnames {
            Task { await configureTLS() }
        }
    }

    /// The URL an installed app is reachable at while the gateway is up —
    /// `https://memos.keg:8443/` when HTTPS is on, `http://…:8080` otherwise.
    /// Falls back to nil when the app has no web UI or its hostname doesn't
    /// resolve in the route table.
    func url(forAppID appID: String, webUIPath: String) -> URL? {
        guard isEnabled, isProxyRunning,
              let hostname = GatewayRouteTable.appHostname(forAppID: appID),
              routeTable.upstream(for: hostname) != nil else { return nil }
        if isTLSRunning, let tlsPort = tlsProxy?.boundPort {
            return URL(string: "https://\(hostname):\(tlsPort)\(webUIPath)")
        }
        let port = proxy?.boundPort ?? proxyPort
        return URL(string: "http://\(hostname):\(port)\(webUIPath)")
    }

    var validCustomRoutes: [GatewayRoute] {
        customRoutes.filter { route in
            route.port > 1024 && route.port <= 65535
                && route.hostname.hasSuffix(".\(GatewayConfig.zone)")
                && route.hostname.count > GatewayConfig.zone.count + 1
        }
    }
}
