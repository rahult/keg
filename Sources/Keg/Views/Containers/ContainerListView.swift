import SwiftUI
import ContainerResource

struct ContainerListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ContainersVM()
    @State private var selectedContainerID: String?
    @State private var showRunSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var searchText = ""
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
                .accessibilityLabel("Containers list")
                .accessibilityValue("\(wrappedContainers.count) containers")
                .accessibilityHint("Use arrow keys to change selection. Press Command Delete to remove the selected container. Press Escape to clear selection.")
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let container = vm.containers.first(where: { $0.id == id }) {
                        ContainerContextMenu(
                            id: id,
                            container: container,
                            onDelete: {
                                selectedContainerID = id
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
        .onChange(of: selectedContainerID) { appState.selectedContainerID = selectedContainerID }
        .onDeleteCommand {
            if selectedContainerID != nil {
                showingDeleteConfirmation = true
            }
        }
        .onExitCommand {
            handleEscape()
        }
        .toolbar(id: "containers-toolbar") {
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
            guard selectedContainerID != nil else { return }
            showingDeleteConfirmation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .keg,
                  appState.selectedKegSection == .containers else { return }
            isSearchFocused = true
        }
        .onDisappear {
            appState.selectedContainerID = nil
        }
        .sheet(isPresented: $showRunSheet) {
            RunContainerView()
        }
        .alert(deleteConfirmationTitle, isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedContainer() }
            }
            .disabled(selectedContainerID == nil)
        } message: {
            Text(deleteConfirmationMessage)
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
        if let name = snapshot.configuration.labels["name"], !name.isEmpty {
            return name
        }
        return String(snapshot.id.prefix(12))
    }

    private var deleteConfirmationTitle: String {
        guard let selectedContainerID,
              let container = vm.containers.first(where: { $0.id == selectedContainerID }) else {
            return "Delete Container"
        }
        return "Delete \(containerName(container))?"
    }

    private var deleteConfirmationMessage: String {
        "Delete the selected container. This action cannot be undone."
    }

    private func handleEscape() {
        if selectedContainerID != nil {
            selectedContainerID = nil
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
    private func deleteSelectedContainer() async {
        guard let selectedContainerID else { return }
        await vm.delete(id: selectedContainerID)
        self.selectedContainerID = nil
    }
}

struct ContainerContextMenu: View {
    let id: String
    let container: ContainerSnapshot
    let onDelete: () -> Void
    let vm: ContainersVM

    private var isRunning: Bool {
        container.status == .running
    }

    var body: some View {
        if isRunning {
            Button("Stop") { Task { await vm.stop(id: id) } }
        }

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
