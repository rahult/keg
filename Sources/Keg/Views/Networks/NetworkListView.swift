import SwiftUI
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class NetworksVM {
    var networks: [NetworkState] = []
    var isLoading = false
    var errorMessage: String?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            networks = try await ClientNetwork.list()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String) async {
        do {
            try await ClientNetwork.delete(id: id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct IdentifiableNetwork: Identifiable {
    let id: String
    let network: NetworkState
    let isBuiltin: Bool

    init(_ network: NetworkState) {
        self.id = network.id
        self.network = network
        self.isBuiltin = network.isBuiltin
    }
}

struct NetworkListView: View {
    @State private var vm = NetworksVM()
    @State private var selectedNetworkID: String?

    private var wrappedNetworks: [IdentifiableNetwork] {
        vm.networks.map { IdentifiableNetwork($0) }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.networks.isEmpty {
                ProgressView("Loading networks...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.networks.isEmpty {
                ContentUnavailableView("No Networks", systemImage: "network")
            } else {
                Table(wrappedNetworks, selection: $selectedNetworkID) {
                    TableColumn("ID") { item in
                        Text(item.network.id)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 150)

                    TableColumn("State") { item in
                        StatusBadge(status: item.network.state)
                    }
                    .width(min: 80, max: 120)

                    TableColumn("Type") { item in
                        Text(item.isBuiltin ? "Built-in" : "Custom")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, max: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        let isBuiltin = vm.networks.first(where: { $0.id == id })?.isBuiltin ?? true
                        NetworkContextMenu(id: id, vm: vm, isBuiltin: isBuiltin)
                    }
                }
            }
        }
        .navigationTitle("Networks")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .overlay {
            if let error = vm.errorMessage {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Dismiss") { vm.errorMessage = nil }
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(8)
                    .background(.bar, in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
                }
            }
        }
        .task {
            await vm.refresh()
        }
    }
}

struct NetworkContextMenu: View {
    let id: String
    let vm: NetworksVM
    let isBuiltin: Bool

    var body: some View {
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        }
        if !isBuiltin {
            Divider()
            Button("Delete", role: .destructive) {
                Task { await vm.delete(id: id) }
            }
        }
    }
}
