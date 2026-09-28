// Gateway hostname routing: every installed app answers at
// `<appID>.keg` (sanitized), plus optional user-defined routes
// (`dev.keg` → 127.0.0.1:3000) for local development.
//
// The table is a locked value the proxy's event-loop threads read without
// touching the main actor; GatewayController replaces its contents whenever
// installations or custom routes change.

import Foundation

/// One gateway hostname → local upstream port mapping.
struct GatewayRoute: Codable, Equatable, Identifiable, Sendable {
    /// Fully qualified hostname including the zone, e.g. `memos.keg`.
    var hostname: String
    /// Loopback port the hostname forwards to.
    var port: Int
    /// Human label (app name or custom-route title).
    var label: String

    var id: String { hostname }
}

/// Thread-safe snapshot of the routing table. Reads come from proxy
/// event-loop threads; writes come from the main actor.
final class GatewayRouteTable: @unchecked Sendable {
    private let lock = NSLock()
    private var appRoutes: [GatewayRoute] = []
    private var customRoutes: [GatewayRoute] = []

    /// Apps win on hostname collision with custom routes.
    func replace(apps: [GatewayRoute], custom: [GatewayRoute]) {
        lock.lock()
        defer { lock.unlock() }
        appRoutes = apps
        customRoutes = custom
    }

    /// Upstream loopback port for `host` (already stripped of its port
    /// suffix), or nil when no route matches.
    func upstream(for host: String) -> Int? {
        let key = Self.normalizeHostname(host)
        guard key.hasSuffix(".\(GatewayConfig.zone)"), key.count > GatewayConfig.zone.count + 1 else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let app = appRoutes.first(where: { $0.hostname == key }) { return app.port }
        return customRoutes.first(where: { $0.hostname == key })?.port
    }

    func snapshot() -> (apps: [GatewayRoute], custom: [GatewayRoute]) {
        lock.lock()
        defer { lock.unlock() }
        return (appRoutes, customRoutes)
    }

    /// Lowercase, strips a trailing `:port` and trailing dot.
    static func normalizeHostname(_ host: String) -> String {
        let noPort = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
        return noPort.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// Turns an app id (kebab-case by contract; user-catalog ids are not
    /// regex-checked) into a DNS-safe label: lowercase, invalid runs → `-`,
    /// trimmed, length-capped. Returns nil when nothing valid remains.
    static func sanitizedLabel(from id: String) -> String? {
        let lowered = id.lowercased()
        var out = ""
        var lastWasDash = true  // suppress leading dashes
        for ch in lowered {
            if ch.isLetter && ch.isASCII || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
            if out.count > 62 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    static func appHostname(forAppID id: String) -> String? {
        guard let label = sanitizedLabel(from: id) else { return nil }
        return "\(label).\(GatewayConfig.zone)"
    }
}

/// Loads/saves user-defined routes at `~/.keg/gateway/routes.json`.
struct GatewayRouteStore {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("keg/gateway", isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".keg/gateway")
    }

    init(directory: URL = GatewayRouteStore.defaultDirectory) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("routes.json") }

    func load() -> [GatewayRoute] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([GatewayRoute].self, from: data)) ?? []
    }

    func save(_ routes: [GatewayRoute]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(routes.sorted { $0.hostname < $1.hostname })
        try data.write(to: fileURL, options: .atomic)
    }
}
