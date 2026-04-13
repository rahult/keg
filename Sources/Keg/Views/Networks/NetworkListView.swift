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

struct NetworkListView: View {
    @State private var vm = NetworksVM()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if vm.isLoading && vm.networks.isEmpty {
                ProgressView("Loading networks...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.networks.isEmpty {
                ContentUnavailableView("No Networks", systemImage: "network")
            } else {
                List(vm.networks, id: \.id) { network in
                    HStack {
                        StatusBadge(status: network.state)
                        Text(network.id)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if !network.isBuiltin {
                            Button("Delete") {
                                Task { await vm.delete(id: network.id) }
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Networks")
        .task {
            await vm.refresh()
        }
    }

    private var toolbar: some View {
        HStack {
            if let errorMessage = vm.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            Spacer()
            Button {
                Task { await vm.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
