// Settings → Gateway: the loopback DNS + Host-routing proxy that gives
// installed apps memorable `http://<name>.keg:8080` addresses. The only
// root touchpoint is the one-time /etc/resolver/keg command, which Keg
// surfaces (copy / open in Terminal) rather than runs — Keg never elevates.

import SwiftUI

struct GatewaySettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var newHostname = ""
    @State private var newPort = ""
    /// Filesystem state isn't observable — re-checked on appear, when the
    /// services toggle, and via an explicit button.
    @State private var resolverConfigured = false
    /// nil = unknown / not checked yet; set by Trust and Verify actions.
    @State private var trustVerified: Bool?
    @State private var isWorkingTLS = false

    private var gateway: GatewayController { appState.gateway }

    private func recheckResolver() {
        resolverConfigured = gateway.isResolverConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            gatewayStatusCard

            if let error = gateway.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            SettingsCaption("Entirely local (loopback): the DNS responder and the routing proxy run inside Keg and only this Mac can reach them. Apps keep their direct 127.0.0.1 ports as a fallback.")

            resolverSection

            httpsSection

            addressSection

            customRoutesSection

            dangerGroup
        }
        .padding(.vertical, 4)
    }

    // MARK: Status

    @ViewBuilder
    private var gatewayStatusCard: some View {
        @Bindable var gateway = appState.gateway
        let healthy = gateway.isProxyRunning && gateway.isDNSRunning
        SettingsStatusCard(
            gateway.isEnabled ? (healthy ? .ok : .warning) : .inactive,
            title: gateway.isEnabled ? gateway.statusSummary : "Off"
        ) {
            SettingsCaption("Installed apps answer at memorable hostnames — http://memos.keg:\(GatewayConfig.proxyPort) instead of 127.0.0.1:5230")
        } headerAction: {
            Toggle("Enable", isOn: $gateway.isEnabled)
                .toggleStyle(.switch)
        }
    }

    // MARK: HTTPS (opt-in)

    private var httpsSection: some View {
        SettingsGroup("HTTPS", caption: "Serves https://<name>.keg:\(GatewayConfig.tlsPort) per app. Opt-in — HTTP on :\(GatewayConfig.proxyPort) keeps working with or without it.") {
            SettingsCard {
                SettingsValueRow("Enable HTTPS", description: "Issue a local certificate per app name.", isLast: true) {
                    Toggle("Enable HTTPS", isOn: Binding(
                        get: { gateway.isHTTPSPermitted },
                        set: { gateway.isHTTPSPermitted = $0 }
                    ))
                    .labelsHidden()
                }
            }

            if gateway.isHTTPSPermitted {
                statusRow(
                    title: gateway.caPEM != nil ? "Local CA created (key in login keychain)" : "Creating local CA…",
                    isGood: gateway.caPEM != nil
                )
                statusRow(
                    title: gateway.isTLSRunning
                        ? "TLS listener on 127.0.0.1:\(gateway.tlsProxyPortInUse ?? GatewayConfig.tlsPort) serving \(gateway.issuedHostnameCount) names"
                        : "TLS listener stopped",
                    isGood: gateway.isTLSRunning
                )

                if let error = gateway.tlsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if trustVerified == true {
                    Label("Certificate trusted — Safari and Chrome show a valid padlock", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if trustVerified == false {
                    Label("Not trusted yet — accept the dialog once, then Verify", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Trust in Keychain…") { trustCertificate() }
                        .controlSize(.small)
                        .disabled(gateway.caPEM == nil || isWorkingTLS)
                    Button("Verify") { verifyHTTPS() }
                        .controlSize(.small)
                        .disabled(!gateway.isTLSRunning || isWorkingTLS)
                    if isWorkingTLS {
                        ProgressView().controlSize(.small)
                    }
                }

                SettingsCaption("Trust is per-user and needs one system dialog — Keg can't install it silently, and the CA key never leaves your login keychain. Firefox keeps its own store: import \(GatewayTrust.caCertificatePath) manually if you use it. Certificates are issued per app name and re-issued when you install or remove apps.")
            }
        }
    }

    private func statusRow(title: String, isGood: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isGood ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(isGood ? Color.green : Color.secondary)
        }
        .font(.caption)
    }

    private func trustCertificate() {
        isWorkingTLS = true
        Task {
            defer { isWorkingTLS = false }
            // Green only when the independent CFNetwork probe agrees —
            // exit-code success alone can lie (the trust dialog can be
            // approved while the cert never lands in the keychain).
            guard (try? await gateway.installCertificateTrust()) == true else {
                trustVerified = false
                return
            }
            trustVerified = await gateway.verifyHTTPS()
        }
    }

    private func verifyHTTPS() {
        isWorkingTLS = true
        Task {
            trustVerified = await gateway.verifyHTTPS()
            isWorkingTLS = false
        }
    }

    // MARK: One-time resolver setup

    private var resolverSection: some View {
        SettingsGroup("One-time setup") {
            if resolverConfigured {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("macOS resolves *.keg to Keg")
                        Text(GatewayConfig.resolverPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }

                Button("Remove the resolver file…") {
                    openInTerminal(GatewayConfig.resolverRemoveCommand)
                }
                .controlSize(.small)
            } else {
                SettingsCaption("Run this once in Terminal so macOS sends *.keg names to Keg's responder:")
                HStack {
                    Text(GatewayConfig.resolverCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    SettingsCopyLine(value: GatewayConfig.resolverCommand, accessibilityLabel: "Copy command")
                    Button("Open in Terminal") {
                        openInTerminal(GatewayConfig.resolverCommand)
                    }
                    .controlSize(.small)
                }
                SettingsCaption("Keg never runs commands with sudo itself — you see and approve exactly what runs. Undo anytime: \(GatewayConfig.resolverRemoveCommand)")
            }

            Button("Re-check") { recheckResolver() }
                .controlSize(.small)
        }
        .task { recheckResolver() }
        .onChange(of: gateway.isDNSRunning) { _, _ in recheckResolver() }
    }

    // MARK: App addresses

    private var addressSection: some View {
        SettingsGroup("App addresses") {
            let routes = gateway.appRoutes.sorted { $0.hostname < $1.hostname }
            if routes.isEmpty {
                SettingsCaption("No installed apps with a web interface yet.")
            } else {
                ForEach(routes) { route in
                    LabeledContent {
                        Text("→ 127.0.0.1:\(route.port)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } label: {
                        appLink(hostname: route.hostname)
                    }
                }
                Button("Refresh list") {
                    gateway.rebuildRouteTable()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Custom routes (development)

    private var customRoutesSection: some View {
        SettingsGroup("Custom routes", caption: "Point extra names at any local port for development — e.g. dev.keg → your app on port 3000. Custom names must end in .keg and lose to an app with the same name. Removing a route lives in the Danger group below.") {
            HStack {
                TextField("name.keg", text: $newHostname)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                TextField("Port", text: $newPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Button("Add") { addRoute() }
                    .disabled(!addRouteFormIsValid)
            }
        }
    }

    // MARK: Danger zone

    @ViewBuilder
    private var dangerGroup: some View {
        if !gateway.customRoutes.isEmpty {
            SettingsGroup("Danger", caption: "Removing a custom route takes effect immediately; apps are unaffected.", isDanger: true) {
                SettingsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(gateway.customRoutes.enumerated()), id: \.element.id) { index, route in
                            SettingsValueRow(
                                route.hostname,
                                description: "→ 127.0.0.1:\(route.port)",
                                isLast: index == gateway.customRoutes.count - 1
                            ) {
                                Button("Remove", role: .destructive) {
                                    var routes = gateway.customRoutes
                                    routes.removeAll { $0.id == route.id }
                                    gateway.setCustomRoutes(routes)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var addRouteFormIsValid: Bool {
        guard let port = Int(newPort), port > 1024, port <= 65535 else { return false }
        let normalized = GatewayRouteTable.normalizeHostname(newHostname)
        return normalized.hasSuffix(".\(GatewayConfig.zone)")
            && normalized.count > GatewayConfig.zone.count + 1
    }

    private func addRoute() {
        let hostname = GatewayRouteTable.normalizeHostname(newHostname)
        guard let port = Int(newPort) else { return }
        var routes = gateway.customRoutes.filter { $0.hostname != hostname }
        routes.append(GatewayRoute(hostname: hostname, port: port, label: hostname))
        gateway.setCustomRoutes(routes)
        newHostname = ""
        newPort = ""
    }

    /// A hostname shown as a link that opens the app in the browser. HTTP on
    /// the proxy port always works; HTTPS is opt-in, so it's not the default.
    private func appLink(hostname: String) -> some View {
        let address = "http://\(hostname):\(GatewayConfig.proxyPort)"
        return Button {
            if let url = URL(string: address) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(hostname)
                .font(.system(.callout, design: .monospaced))
        }
        .buttonStyle(.link)
        .help("Open \(address)")
    }

    /// Open Terminal.app and prefill the command. Keg doesn't run sudo'd
    /// commands itself — the user sees and approves exactly what runs.
    private func openInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
