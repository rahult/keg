import SwiftUI
import ContainerResource

struct ContainerListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ContainersVM()
    @State private var selectedContainerIDs: Set<String> = []
    @State private var showRunSheet = false
    @State private var runImage: String?
    @State private var showingDeleteConfirmation = false
    @State private var searchText = ""
    @State private var recreateContainer: IdentifiableContainer?
    @FocusState private var isSearchFocused: Bool

    private var wrappedContainers: [IdentifiableContainer] {
        vm.filteredContainers.map { IdentifiableContainer($0) }
    }

    /// How each container is reachable from the Mac: an installed app's
    /// Gateway hostname (when the Gateway is on) or its first published port.
    private var accessByContainer: [String: ContainerAccess] {
        var out: [String: ContainerAccess] = [:]
        for container in vm.containers {
            if let access = ContainerAccessResolver.resolve(
                container,
                installations: appState.apps.installations,
                gatewayEnabled: appState.gateway.isEnabled
            ) {
                out[container.id] = access
            }
        }
        return out
    }

    /// Tells the truth about how much of the dataset is on screen — a
    /// running-only filter over 65 containers must never read as data loss.
    private var subtitle: String {
        let total = vm.containers.count
        let shown = vm.filteredContainers.count
        guard !vm.isLoading else { return "" }
        if vm.showOnlyRunning, total > 0 {
            return "Showing \(shown) running of \(total) containers"
        }
        if shown != total {
            return "Showing \(shown) of \(total) containers"
        }
        return total == 1 ? "1 container" : "\(total) containers"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = vm.errorMessage {
                // A failed refresh (runtime booting, wedged, XPC hiccup) must
                // never read as "no containers" — say what happened and offer
                // a retry. Cleared automatically on the next successful pull.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .font(.callout)
                        .lineLimit(2)
                        .help(errorMessage)
                    Spacer()
                    Button("Retry") {
                        Task { await vm.refresh() }
                    }
                    .controlSize(.small)
                    Button {
                        vm.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.08))
                Divider()
            }
            Group {
            if vm.isLoading && vm.containers.isEmpty {
                ProgressView("Loading containers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if wrappedContainers.isEmpty {
                if vm.containers.isEmpty && !vm.showOnlyRunning {
                    containersQuickStart
                } else {
                    ContentUnavailableView(
                        vm.showOnlyRunning ? "No Running Containers" : "No Containers",
                        systemImage: "cube.box",
                        description: Text(vm.showOnlyRunning ? "Run a container to get started" : "Containers will appear here")
                    )
                    .accessibilityLabel(vm.showOnlyRunning ? "No running containers" : "No containers")
                    .accessibilityHint(vm.showOnlyRunning ? "Turn off the running-only filter or run a container" : "Run a container to populate the list")
                }
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

                    TableColumn("URL") { item in
                        if let access = accessByContainer[item.snapshot.id] {
                            Button {
                                NSWorkspace.shared.open(access.url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: access.isGateway ? "globe" : "network")
                                        .font(.caption2)
                                        .foregroundStyle(access.isGateway ? Color.teal : .secondary)
                                    Text(access.display)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .buttonStyle(.borderless)
                            .help("Open \(access.url.absoluteString)")
                            .accessibilityLabel("Open \(access.display)")
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 110, max: 170)

                    TableColumn("Ports") { item in
                        Text(item.snapshot.configuration.publishedPorts.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 80)

                    TableColumn("CPU") { item in
                        HStack(spacing: 6) {
                            InlineSparkline(values: vm.cpuHistory[item.snapshot.id] ?? [], color: .blue)
                                .frame(width: 40, height: 14)
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
                    }
                    .width(min: 100, max: 130)

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
                            Text(date, format: .relative(presentation: .named))
                                .foregroundStyle(.secondary)
                                .help(date.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
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
                            access: accessByContainer[id],
                            onRecreate: {
                                recreateContainer = IdentifiableContainer(container)
                            },
                            onDelete: {
                                selectedContainerIDs = [id]
                                showingDeleteConfirmation = true
                            },
                            onAskCooper: {
                                appState.askCooper(
                                    "Tell me about the container \"\(id)\" " +
                                    "(\(container.configuration.image.reference), \(container.status.rawValue)) — " +
                                    "anything unusual? Check its details and recent logs."
                                )
                            },
                            vm: vm
                        )
                    }
                }
            }
            }
        }
        .navigationTitle("Containers")
        .searchable(text: $searchText, prompt: "Search containers")
        .searchFocused($isSearchFocused)
        .onChange(of: searchText) { vm.searchText = searchText }
        .onChange(of: selectedContainerIDs) { appState.selectedContainerID = selectedContainerIDs.first }
        .onChange(of: appState.isSystemRunning) { _, running in
            // The first refresh can fire while the runtime is still booting
            // and fail silently into "No Containers Yet" — retry on the
            // running-transition so the list heals without a relaunch.
            if running { Task { await vm.refresh() } }
        }
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
                    openRunSheet(with: nil)
                } label: {
                    Label("Run…", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .help("Run a new container from an image")
                .accessibilityHint("Open the run container sheet")
            }

            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .containers)
            }

            ToolbarItem(id: "filter", placement: .automatic) {
                // Segmented so the active state is always visible — a lone
                // toggle button read as a static label and hid 64 containers.
                // Counts preview what each side of the filter holds.
                Picker("Filter", selection: $vm.showOnlyRunning) {
                    Text("All (\(vm.containers.count))").tag(false)
                    Text("Running (\(vm.runningCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("Limit the list to running containers")
                .accessibilityHint("Limit the list to running containers")
            }

            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload the containers list (⌘R)")
                .accessibilityHint("Reload the containers list")
            }
        }
        .navigationSubtitle(subtitle)
        .toolbarRole(.editor)
        .task {
            if let pending = appState.pendingRunImage {
                appState.pendingRunImage = nil
                openRunSheet(with: pending)
            }
            await vm.refresh()
            vm.startLiveStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRunContainer)) { _ in
            openRunSheet(with: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRunImage)) { note in
            guard appState.currentArea == .keg,
                  appState.selectedKegSection == .containers,
                  let image = note.object as? String else { return }
            openRunSheet(with: image)
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
        .sheet(isPresented: $showRunSheet, onDismiss: { runImage = nil }) {
            RunContainerView(initialImage: runImage)
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
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        }
    }

    private var containersQuickStart: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "No Containers Yet",
                systemImage: "cube.box",
                description: Text("A container is one isolated app. Pick a quick start below — it's safe, nothing touches your Mac.")
            )

            HStack(spacing: 10) {
                Button {
                    openRunSheet(with: "hello-world")
                } label: {
                    Label("Try a 5-second demo", systemImage: "play.circle")
                }
                .help("Download hello-world and run it once to prove everything works")

                Button {
                    openRunSheet(with: "nginx")
                } label: {
                    Label("Run a web server", systemImage: "globe")
                }
                .help("Run nginx with port 8080 already forwarded — open http://localhost:8080 once it's up")

                Button {
                    openRunSheet(with: nil)
                } label: {
                    Label("Run something else…", systemImage: "ellipsis")
                }
                .help("Choose any image from Docker Hub or your registries")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No containers")
        .accessibilityHint("Try a quick start to run your first container")
    }

    private func openRunSheet(with image: String?) {
        runImage = image
        showRunSheet = true
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
    var access: ContainerAccess?
    let onRecreate: () -> Void
    let onDelete: () -> Void
    let onAskCooper: () -> Void
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

        if let access {
            Button("Open \(access.display)") {
                NSWorkspace.shared.open(access.url)
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(access.url.absoluteString, forType: .string)
            }
            Divider()
        }

        Divider()

        Button("Ask Cooper About This Container…") {
            onAskCooper()
        }

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
