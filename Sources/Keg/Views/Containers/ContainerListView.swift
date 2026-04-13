import SwiftUI
import ContainerResource

struct ContainerListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ContainersVM()
    @State private var selectedContainerID: String?
    @State private var showRunSheet = false

    private var wrappedContainers: [IdentifiableContainer] {
        vm.filteredContainers.map { IdentifiableContainer($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Toggle("Running Only", isOn: $vm.showOnlyRunning)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)

                TextField("Search containers...", text: $vm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 200)

                Spacer()

                Button {
                    showRunSheet = true
                } label: {
                    Label("Run", systemImage: "plus")
                }
                .controlSize(.small)

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

            Divider()

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
                    TableColumn("ID") { item in
                        Text(item.snapshot.id)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .width(min: 100, max: 200)

                    TableColumn("Image") { item in
                        Text(item.snapshot.configuration.image.reference)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 150)

                    TableColumn("Status") { item in
                        StatusBadge(status: item.snapshot.status.rawValue)
                    }
                    .width(min: 80, max: 120)

                    TableColumn("IP Address") { item in
                        Text(item.snapshot.networks.map(\.ipv4Address.description).joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, max: 150)

                    TableColumn("CPUs") { item in
                        Text("\(item.snapshot.configuration.resources.cpus)")
                    }
                    .width(50)

                    TableColumn("Memory") { item in
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.snapshot.configuration.resources.memoryInBytes), countStyle: .memory))
                    }
                    .width(min: 80, max: 100)

                    TableColumn("Ports") { item in
                        Text(item.snapshot.configuration.publishedPorts.map { "\($0.hostPort):\($0.containerPort)" }.joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 80)

                    TableColumn("Started") { item in
                        if let date = item.snapshot.startedDate {
                            Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        ContainerContextMenu(id: id, vm: vm)
                    }
                }
            }
        }
        .navigationTitle("Containers")
        .task {
            await vm.refresh()
        }
        .onChange(of: vm.showOnlyRunning) {
            Task { await vm.refresh() }
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
}

struct ContainerContextMenu: View {
    let id: String
    let vm: ContainersVM

    var body: some View {
        Button("Stop") { Task { await vm.stop(id: id) } }
        Button("Kill") { Task { await vm.kill(id: id) } }
        Divider()
        Button("Delete", role: .destructive) { Task { await vm.delete(id: id) } }
    }
}
