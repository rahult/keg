import SwiftUI
import ContainerResource

struct ContainerListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ContainersVM()
    @State private var selectedContainerID: String?
    @State private var showRunSheet = false
    @State private var searchText = ""

    private var wrappedContainers: [IdentifiableContainer] {
        vm.filteredContainers.map { IdentifiableContainer($0) }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.containers.isEmpty {
                ProgressView("Loading containers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if wrappedContainers.isEmpty {
                ContentUnavailableView(
                    vm.showOnlyRunning ? "No Running Containers" : "No Containers",
                    systemImage: "cube.box",
                    description: Text(vm.showOnlyRunning ? "Run a container to get started" : "Containers will appear here")
                )
            } else {
                Table(wrappedContainers, selection: $selectedContainerID) {
                    TableColumn("Name") { item in
                        Text(containerName(item.snapshot))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .width(min: 120)

                    TableColumn("Image") { item in
                        Text(item.snapshot.configuration.image.reference)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 150)

                    TableColumn("Status") { item in
                        StatusBadge(status: item.snapshot.status.rawValue)
                    }
                    .width(min: 80, max: 120)

                    TableColumn("ID") { item in
                        Text(String(item.snapshot.id.prefix(12)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .width(min: 90, max: 120)

                    TableColumn("IP") { item in
                        let ip = item.snapshot.networks.map(\.ipv4Address.description).joined(separator: ", ")
                        Text(ip)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(ip.isEmpty ? .tertiary : .primary)
                    }
                    .width(min: 100, max: 150)

                    TableColumn("Ports") { item in
                        Text(item.snapshot.configuration.publishedPorts.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 80)

                    TableColumn("CPU / Mem") { item in
                        Text("\(item.snapshot.configuration.resources.cpus) × \(ByteCountFormatter.string(fromByteCount: Int64(item.snapshot.configuration.resources.memoryInBytes), countStyle: .memory))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, max: 120)

                    TableColumn("Started") { item in
                        if let date = item.snapshot.startedDate {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        ContainerContextMenu(id: id, container: vm.containers.first(where: { $0.id == id }), vm: vm)
                    }
                }
            }
        }
        .navigationTitle("Containers")
        .searchable(text: $searchText, prompt: "Search containers")
        .onChange(of: searchText) { vm.searchText = searchText }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRunSheet = true
                } label: {
                    Label("Run...", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    vm.showOnlyRunning.toggle()
                    Task { await vm.refresh() }
                } label: {
                    Label(
                        vm.showOnlyRunning ? "Show All" : "Running Only",
                        systemImage: vm.showOnlyRunning ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await vm.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRunContainer)) { _ in
            showRunSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRefresh)) { _ in
            Task { await vm.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegStopContainer)) { _ in
            guard let selectedContainerID else { return }
            Task { await vm.stop(id: selectedContainerID) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegDeleteContainer)) { _ in
            guard let selectedContainerID else { return }
            Task { await vm.delete(id: selectedContainerID) }
        }
        .sheet(isPresented: $showRunSheet) {
            RunContainerView()
        }
        .inspector(isPresented: .init(
            get: { selectedContainerID != nil },
            set: { if !$0 { selectedContainerID = nil } }
        )) {
            if let id = selectedContainerID {
                ContainerDetailView(containerID: id)
            }
        }
    }

    private func containerName(_ snapshot: ContainerSnapshot) -> String {
        // Check labels for a name
        if let name = snapshot.configuration.labels["name"], !name.isEmpty {
            return name
        }
        // Fallback to short ID
        return String(snapshot.id.prefix(12))
    }
}

struct ContainerContextMenu: View {
    let id: String
    let container: ContainerSnapshot?
    let vm: ContainersVM

    private var isRunning: Bool {
        container?.status == .running
    }

    var body: some View {
        if isRunning {
            Button("Stop") { Task { await vm.stop(id: id) } }
        } else {
            Button("Start") { /* TODO: implement start */ }
        }
        Button("Restart") { /* TODO: implement restart */ }
        Divider()
        Button("View Logs") { /* TODO: open logs in inspector/tab */ }
        Button("Exec Shell") { /* TODO: open terminal */ }
        Divider()
        Button("Copy ID") {
            let short = id.prefix(12)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(short), forType: .string)
        }
        if let ref = container?.configuration.image.reference {
            Button("Copy Image Reference") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref, forType: .string)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await vm.delete(id: id) } }
    }
}
