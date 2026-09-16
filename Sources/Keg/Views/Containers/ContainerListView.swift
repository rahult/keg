import SwiftUI
import ContainerResource

struct ContainerListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ContainersVM()
    @State private var selectedContainerIDs: Set<String> = []
    @State private var showRunSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var searchText = ""
    @State private var recreateContainer: IdentifiableContainer?
    @FocusState private var isSearchFocused: Bool

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
                .accessibilityLabel(vm.showOnlyRunning ? "No running containers" : "No containers")
                .accessibilityHint(vm.showOnlyRunning ? "Turn off the running-only filter or run a container" : "Run a container to populate the list")
            } else {
                Table(wrappedContainers, selection: $selectedContainerIDs) {
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

                    TableColumn("CPU") { item in
                        if let metrics = vm.liveMetrics[item.snapshot.id] {
                            Text(String(format: "%.0f%%", metrics.cpuPercent))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(metrics.cpuPercent >= 80 ? .red : (metrics.cpuPercent >= 50 ? .orange : .secondary))
                        } else {
                            Text(item.snapshot.status == .running ? "…" : "—")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 56, max: 80)

                    TableColumn("Memory") { item in
                        if let metrics = vm.liveMetrics[item.snapshot.id] {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(metrics.memoryUsedBytes), countStyle: .memory))
                                    .font(.system(.body, design: .monospaced))
                                Text(String(format: "%.0f%% of %@", metrics.memoryPercent, ByteCountFormatter.string(fromByteCount: Int64(metrics.memoryLimitBytes), countStyle: .memory)))
                                    .font(.caption2)
                                    .foregroundStyle(metrics.memoryPercent >= 80 ? .red : .secondary)
                            }
                        } else {
                            Text(item.snapshot.status == .running ? "…" : "—")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 110, max: 170)

                    TableColumn("Started") { item in
                        if let date = item.snapshot.startedDate {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityLabel("Containers list")
                .accessibilityValue("\(wrappedContainers.count) containers")
                .accessibilityHint("Use arrow keys to change selection. Press Command Delete to remove the selected container. Press Escape to clear selection.")
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count > 1 {
                        Button("Stop \(ids.count) Containers") {
                            Task { for id in ids { await vm.stop(id: id) } }
                        }
                        Divider()
                        Button("Delete \(ids.count) Containers", role: .destructive) {
                            selectedContainerIDs = ids
                            showingDeleteConfirmation = true
                        }
                    } else if let id = ids.first,
                              let container = vm.containers.first(where: { $0.id == id }) {
                        ContainerContextMenu(
                            id: id,
                            container: container,
                            onRecreate: {
                                recreateContainer = IdentifiableContainer(container)
                            },
                            onDelete: {
                                selectedContainerIDs = [id]
                                showingDeleteConfirmation = true
                            },
                            vm: vm
                        )
                    }
                }
            }
        }
        .navigationTitle("Containers")
        .searchable(text: $searchText, prompt: "Search containers")
        .searchFocused($isSearchFocused)
        .onChange(of: searchText) { vm.searchText = searchText }
        .onChange(of: selectedContainerIDs) { appState.selectedContainerID = selectedContainerIDs.first }
        .onDeleteCommand {
            if !selectedContainerIDs.isEmpty {
                showingDeleteConfirmation = true
            }
        }
        .onExitCommand {
            handleEscape()
        }
        .toolbar {
            ToolbarItem(id: "run", placement: .primaryAction) {
                Button {
                    showRunSheet = true
                } label: {
                    Label("Run...", systemImage: "plus")
                }
                .accessibilityHint("Open the run container sheet")
            }

            ToolbarItem(id: "filter", placement: .automatic) {
                Button {
                    vm.showOnlyRunning.toggle()
                    Task { await vm.refresh() }
                } label: {
                    Label(
                        vm.showOnlyRunning ? "Show All" : "Running Only",
                        systemImage: vm.showOnlyRunning ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                }
                .accessibilityHint(vm.showOnlyRunning ? "Show stopped containers too" : "Limit the list to running containers")
            }

            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityHint("Reload the containers list")
            }
        }
        .toolbarRole(.editor)
        .task {
            await vm.refresh()
            vm.startLiveStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRunContainer)) { _ in
            showRunSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRefresh)) { _ in
            Task { await vm.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegStopContainer)) { _ in
            guard !selectedContainerIDs.isEmpty else { return }
            Task { for id in selectedContainerIDs { await vm.stop(id: id) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegDeleteContainer)) { _ in
            guard !selectedContainerIDs.isEmpty else { return }
            showingDeleteConfirmation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .keg,
                  appState.selectedKegSection == .containers else { return }
            isSearchFocused = true
        }
        .onDisappear {
            appState.selectedContainerID = nil
            vm.stopLiveStats()
        }
        .sheet(isPresented: $showRunSheet) {
            RunContainerView()
        }
        .sheet(item: $recreateContainer) { wrapped in
            RecreateContainerView(container: wrapped.snapshot) {
                Task { await vm.refresh() }
            }
        }
        .alert(deleteConfirmationTitle, isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedContainers() }
            }
            .disabled(selectedContainerIDs.isEmpty)
        } message: {
            Text(deleteConfirmationMessage)
        }
        .inspector(isPresented: .init(
            get: { selectedContainerIDs.count == 1 },
            set: { if !$0 { selectedContainerIDs = [] } }
        )) {
            if let id = selectedContainerIDs.first {
                ContainerDetailView(containerID: id)
            }
        }
    }

    private func containerName(_ snapshot: ContainerSnapshot) -> String {
        if let name = snapshot.configuration.labels["name"], !name.isEmpty {
            return name
        }
        return String(snapshot.id.prefix(12))
    }

    private var deleteConfirmationTitle: String {
        if selectedContainerIDs.count > 1 {
            return "Delete \(selectedContainerIDs.count) Containers?"
        }
        guard let id = selectedContainerIDs.first,
              let container = vm.containers.first(where: { $0.id == id }) else {
            return "Delete Container"
        }
        return "Delete \(containerName(container))?"
    }

    private var deleteConfirmationMessage: String {
        if selectedContainerIDs.count > 1 {
            return "Delete \(selectedContainerIDs.count) containers. This action cannot be undone."
        }
        return "Delete the selected container. This action cannot be undone."
    }

    private func handleEscape() {
        if !selectedContainerIDs.isEmpty {
            selectedContainerIDs = []
            return
        }

        if !searchText.isEmpty {
            searchText = ""
            return
        }

        if isSearchFocused {
            isSearchFocused = false
        }
    }

    @MainActor
    private func deleteSelectedContainers() async {
        for id in selectedContainerIDs {
            await vm.delete(id: id)
        }
        selectedContainerIDs = []
    }
}

struct ContainerContextMenu: View {
    let id: String
    let container: ContainerSnapshot
    let onRecreate: () -> Void
    let onDelete: () -> Void
    let vm: ContainersVM

    private var isRunning: Bool {
        container.status == .running
    }

    var body: some View {
        if isRunning {
            Button("Stop") { Task { await vm.stop(id: id) } }
            Button("Restart") { Task { await vm.restart(id: id) } }
            Button("Open Terminal") {
                TerminalLauncher.openShell(containerID: id)
            }
        } else {
            Button("Start") { Task { await vm.start(id: id) } }
        }

        Divider()

        Button("Edit & Recreate…", action: onRecreate)

        Divider()

        Button("Copy ID") {
            let short = id.prefix(12)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(short), forType: .string)
        }
        Button("Copy Image Reference") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.configuration.image.reference, forType: .string)
        }

        Divider()

        Button("Delete", role: .destructive) {
            onDelete()
        }
        .accessibilityHint("Delete the selected container")
    }
}
