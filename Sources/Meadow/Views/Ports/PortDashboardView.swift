import SwiftUI

struct PortDashboardView: View {
    @State private var vm = PortDashboardVM()
    @State private var searchText = ""
    @State private var selectedEntryID: UUID?

    private var filteredEntries: [PortDashboardVM.PortEntry] {
        guard !searchText.isEmpty else { return vm.entries }
        return vm.entries.filter {
            $0.containerName.localizedCaseInsensitiveContains(searchText) ||
            "\($0.hostPort)".contains(searchText) ||
            "\($0.containerPort)".contains(searchText) ||
            ($0.url?.absoluteString.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.entries.isEmpty {
                ProgressView("Loading ports...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.entries.isEmpty {
                ContentUnavailableView(
                    "No Ports Published",
                    systemImage: "network",
                    description: Text("Running containers with published ports will appear here")
                )
            } else {
                Table(filteredEntries, selection: $selectedEntryID) {
                    TableColumn("Container") { entry in
                        Text(entry.containerName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .width(min: 120)

                    TableColumn("Host Port") { entry in
                        HStack(spacing: 4) {
                            Text("\(entry.hostPort)")
                                .font(.system(.body, design: .monospaced))
                            if entry.isConflicted {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                        }
                    }
                    .width(min: 80, max: 120)

                    TableColumn("Container Port") { entry in
                        Text("\(entry.containerPort)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, max: 120)

                    TableColumn("URL") { entry in
                        if let url = entry.url {
                            Link(url.absoluteString, destination: url)
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 150)

                    TableColumn("Open") { entry in
                        if let url = entry.url {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Open in browser")
                            .help("Open in browser")
                        }
                    }
                    .width(40)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let entry = filteredEntries.first(where: { $0.id == id }) {
                        PortEntryContextMenu(entry: entry)
                    }
                }
            }
        }
        .navigationTitle("Ports")
        .searchable(text: $searchText, prompt: "Search by container, port, or URL")
        .toolbar(id: "ports-toolbar") {
            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .toolbarRole(.editor)
        .task {
            await vm.refresh()
        }
    }
}

struct PortEntryContextMenu: View {
    let entry: PortDashboardVM.PortEntry

    var body: some View {
        if let url = entry.url {
            Button("Open in Browser") {
                NSWorkspace.shared.open(url)
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Divider()
        }
        Button("Copy Host Port") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(entry.hostPort)", forType: .string)
        }
        if entry.isConflicted {
            Divider()
            Text("⚠️ Port \(entry.hostPort) is used by multiple containers")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
