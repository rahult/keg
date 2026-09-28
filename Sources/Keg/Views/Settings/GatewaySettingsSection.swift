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
        @Bindable var gateway = appState.gateway

        Form {
            Section("Gateway") {
                HStack {
                    Circle()
                        .fill(gateway.isEnabled ? (gateway.isProxyRunning && gateway.isDNSRunning ? Color.green : Color.orange) : Color.gray)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gateway.isEnabled ? gateway.statusSummary : "Off")
                            .font(.headline)
                        Text("Installed apps answer at memorable hostnames — http://memos.keg:\(GatewayConfig.proxyPort) instead of 127.0.0.1:5230")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enable", isOn: $gateway.isEnabled)
                        .toggleStyle(.switch)
                }

                if let error = gateway.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Entirely local (loopback): the DNS responder and the routing proxy run inside Keg and only this Mac can reach them. Apps keep their direct 127.0.0.1 ports as a fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            resolverSection

            httpsSection

            addressSection

            customRoutesSection
        }
    }

    // MARK: HTTPS (opt-in)

    private var httpsSection: some View {
        Section {
            Toggle("HTTPS (https://name.keg:8443)", isOn: Binding(
                get: { gateway.isHTTPSPermitted },
                set: { gateway.isHTTPSPermitted = $0 }
            ))

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

                Text("Trust is per-user and needs one system dialog — Keg can't install it silently, and the CA key never leaves your login keychain. Firefox keeps its own store: import \(GatewayTrust.caCertificatePath) manually if you use it. Certificates are issued per app name and re-issued when you install or remove apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("HTTPS")
        } footer: {
            Text("Opt-in. HTTP on :8080 keeps working with or without it.")
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
            let result = try? await gateway.installCertificateTrust()
            trustVerified = (result == true)
            isWorkingTLS = false
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
        Section("One-time setup") {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run this once in Terminal so macOS sends *.keg names to Keg's responder:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(GatewayConfig.resolverCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(GatewayConfig.resolverCommand, forType: .string)
                        }
                        .controlSize(.small)
                        Button("Open in Terminal") {
                            openInTerminal(GatewayConfig.resolverCommand)
                        }
                        .controlSize(.small)
                    }
                    Text("Keg never runs commands with sudo itself — you see and approve exactly what runs. Undo anytime: \(GatewayConfig.resolverRemoveCommand)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Button("Re-check") { recheckResolver() }
                .controlSize(.small)
        }
        .task { recheckResolver() }
        .onChange(of: gateway.isDNSRunning) { _, _ in recheckResolver() }
    }

    // MARK: App addresses

    private var addressSection: some View {
        Section("App addresses") {
            let routes = gateway.appRoutes.sorted { $0.hostname < $1.hostname }
            if routes.isEmpty {
                Text("No installed apps with a web interface yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(routes) { route in
                    LabeledContent {
                        Text("→ 127.0.0.1:\(route.port)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(route.hostname)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
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
        Section {
            ForEach(gateway.customRoutes) { route in
                LabeledContent {
                    Text("→ 127.0.0.1:\(route.port)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } label: {
                    Text(route.hostname)
                        .font(.system(.callout, design: .monospaced))
                }
            }
            .onDelete { offsets in
                var routes = gateway.customRoutes
                routes.remove(atOffsets: offsets)
                gateway.setCustomRoutes(routes)
            }

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

            Text("Point extra names at any local port for development — e.g. dev.keg → your app on port 3000. Custom names must end in .keg and lose to an app with the same name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Custom routes")
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
