import Foundation
import ContainerResource

/// How a container is reachable from the host Mac: an installed app's
/// Gateway hostname when the Gateway is on, otherwise its first published
/// port on localhost.
struct ContainerAccess: Equatable {
    let display: String
    let url: URL
    let isGateway: Bool
}

enum ContainerAccessResolver {
    /// Apps-section installs run under compose project `apps-<id>` with
    /// containers named `kegapp-<id>-<service>` (the naming contract).
    /// Project label is authoritative; the name prefix disambiguates ids
    /// that contain dashes.
    static func resolve(
        _ snapshot: ContainerSnapshot,
        installations: [AppInstallation],
        gatewayEnabled: Bool
    ) -> ContainerAccess? {
        let project = snapshot.configuration.labels["com.docker.compose.project"]
        let name = snapshot.configuration.labels["name"]
        let installation = installations.first { inst in
            if let project, project.hasPrefix("apps-"), String(project.dropFirst("apps-".count)) == inst.appID {
                return true
            }
            return name.map({ $0.hasPrefix("kegapp-\(inst.appID)-") }) ?? false
        }

        if let installation, let webPort = installation.webPort {
            if gatewayEnabled, let host = GatewayRouteTable.appHostname(forAppID: installation.appID),
               let url = URL(string: "http://\(host):\(GatewayConfig.proxyPort)") {
                return ContainerAccess(
                    display: "\(host):\(GatewayConfig.proxyPort)",
                    url: url,
                    isGateway: true
                )
            }
            if let url = URL(string: "http://localhost:\(webPort)") {
                return ContainerAccess(display: "localhost:\(webPort)", url: url, isGateway: false)
            }
        }

        // Plain containers fall back to their first published port.
        if let port = snapshot.configuration.publishedPorts.first,
           let url = URL(string: "http://localhost:\(port.hostPort)") {
            return ContainerAccess(display: "localhost:\(port.hostPort)", url: url, isGateway: false)
        }
        return nil
    }
}
