import AppKit
import SwiftUI

// MARK: - Integration Settings View

/// Settings sub-view for managing Supaglue OAuth connections per provider.
/// Accessed from Settings > Integrations (Supaglue).
struct IntegrationSettingsView: View {
    @State private var vm = IntegrationSettingsVM()

    var body: some View {
        Form {
            supaglueSection
            connectionsSection
            providersSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Integrations")
        .task {
            await vm.load()
        }
    }

    // MARK: - Supaglue Service

    @ViewBuilder
    private var supaglueSection: some View {
        Section("Supaglue Service") {
            HStack {
                Circle()
                    .fill(vm.supaglueStatusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading) {
                    Text(vm.supaglueStatusLabel)
                        .font(.headline)
                    Text("Self-hosted SaaS integrations via Supaglue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch vm.containerStatus {
                case .absent, .stopped:
                    Button("Start") { Task { await vm.startSupaglue() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isLoading)
                case .running:
                    Button("Stop") { Task { await vm.stopSupaglue() } }
                        .controlSize(.small)
                        .disabled(vm.isLoading)
                }
            }

            if vm.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(vm.loadingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LabeledContent("API Base", value: "http://127.0.0.1:3000")
            LabeledContent("Container", value: "keg-supaglue")
        }
    }

    // MARK: - Connections

    @ViewBuilder
    private var connectionsSection: some View {
        Section("Connections") {
            if vm.connections.isEmpty {
                HStack {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(.secondary)
                    Text("No connections yet")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(vm.connections) { conn in
                    connectionRow(conn)
                }
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ conn: SupaglueConnection) -> some View {
        HStack {
            ProviderIcon(provider: conn.provider)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(conn.provider.capitalized)
                    .font(.subheadline)
                Text(conn.customerId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ConnectionStatusBadge(status: conn.status)

            Button(role: .destructive) {
                Task { await vm.deleteConnection(conn) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(vm.isLoading)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Provider Grid

    @ViewBuilder
    private var providersSection: some View {
        Section("Add Connection") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                ForEach(SupportedProvider.allCases) { provider in
                    ProviderCard(provider: provider, isConnecting: vm.connectingProvider == provider) {
                        Task { await vm.connectProvider(provider) }
                    }
                    .disabled(vm.containerStatus != .running || vm.isLoading)
                }
            }
            .padding(.vertical, 4)

            Text("Click a provider to initiate OAuth. You may be redirected to the provider's login page.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    let provider: SupportedProvider
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            VStack(spacing: 8) {
                ProviderIcon(provider: provider.rawValue)
                    .frame(width: 32, height: 32)
                Text(provider.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.primary)
                if isConnecting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("Connect")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Connect \(provider.rawValue) via Supaglue OAuth")
    }
}

// MARK: - Provider Icon

struct ProviderIcon: View {
    let provider: String

    var body: some View {
        let (icon, color) = iconForProvider(provider)
        Image(systemName: icon)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
    }

    private func iconForProvider(_ p: String) -> (String, Color) {
        switch p.lowercased() {
        case "gmail", "google":    return ("envelope.fill",      .blue)
        case "googlecalendar", "google_calendar": return ("calendar",         .green)
        case "hubspot":            return ("rectangle.portrait.badge.person.crop", .orange)
        case "salesforce":         return ("cloud.fill",          .blue)
        case "slack":              return ("number",              .purple)
        case "notion":             return ("doc.text.fill",       .primary)
        case "linear":             return ("line.horizontal.3",  .primary)
        default:                   return ("globe",              .secondary)
        }
    }
}

// MARK: - Connection Status Badge

struct ConnectionStatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(status.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.1), in: Capsule())
    }

    private var statusColor: Color {
        switch status.lowercased() {
        case "available", "connected": return .green
        case "pending":                 return .orange
        case "error", "failed":        return .red
        default:                       return .gray
        }
    }
}

// MARK: - Supported Providers

enum SupportedProvider: String, CaseIterable, Identifiable {
    case gmail           = "gmail"
    case googleCalendar  = "google_calendar"
    case hubspot         = "hubspot"
    case salesforce      = "salesforce"
    case slack           = "slack"
    case notion          = "notion"
    case linear          = "linear"

    var id: String { rawValue }
}



// MARK: - ViewModel

@Observable
@MainActor
final class IntegrationSettingsVM {
    var containerStatus: ContainerStatus = .absent
    var connections: [SupaglueConnection] = []
    var isLoading = false
    var loadingMessage = ""
    var errorMessage: String?
    var connectingProvider: SupportedProvider?

    private let supaglueContainer = SupaglueContainer()
    private let supaglueClient = SupaglueClient()

    var supaglueStatusColor: Color {
        switch containerStatus {
        case .running:  return .green
        case .stopped:  return .orange
        case .absent:   return .red
        }
    }

    var supaglueStatusLabel: String {
        switch containerStatus {
        case .running:  return "Running"
        case .stopped:  return "Stopped"
        case .absent:   return "Not Created"
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        containerStatus = await supaglueContainer.status()
        if case .running = containerStatus {
            await loadConnections()
        }
    }

    func startSupaglue() async {
        isLoading = true
        loadingMessage = "Pulling image…"
        errorMessage = nil

        do {
            let (_, pullOut, _) = try await supaglueContainer.pull()
            if !pullOut.isEmpty {
                loadingMessage = "Starting container…"
            }

            let (_, startOut, _) = try await supaglueContainer.run()
            if (try? await supaglueContainer.status()) != .running {
                errorMessage = "Container failed to start: \(startOut)"
                isLoading = false
                return
            }

            loadingMessage = "Waiting for Supaglue API…"
            try await supaglueContainer.waitReady()

            containerStatus = await supaglueContainer.status()
            await loadConnections()
        } catch {
            errorMessage = error.localizedDescription
            containerStatus = await supaglueContainer.status()
        }

        isLoading = false
    }

    func stopSupaglue() async {
        isLoading = true
        loadingMessage = "Stopping container…"
        errorMessage = nil

        do {
            try await supaglueContainer.stop()
            containerStatus = await supaglueContainer.status()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func loadConnections() async {
        do {
            connections = try await supaglueClient.listConnections()
        } catch {
            // Silently ignore connection-list errors — Supaglue may not be ready yet
            connections = []
        }
    }

    func connectProvider(_ provider: SupportedProvider) async {
        connectingProvider = provider
        errorMessage = nil

        // For now, open the Supaglue management UI in the browser.
        // A full OAuth flow would require a redirect URI and callback handling.
        let url = URL(string: "http://127.0.0.1:3000/connections/new?provider=\(provider.rawValue)")
        if let u = url {
            NSWorkspace.shared.open(u)
        }

        // Brief delay then reload connections
        try? await Task.sleep(for: .seconds(1))
        await loadConnections()
        connectingProvider = nil
    }

    func deleteConnection(_ conn: SupaglueConnection) async {
        isLoading = true
        errorMessage = nil

        do {
            try await supaglueClient.deleteConnection(id: conn.id)
            connections.removeAll { $0.id == conn.id }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
