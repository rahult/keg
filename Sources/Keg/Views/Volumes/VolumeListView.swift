import SwiftUI
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class VolumesVM {
    var volumes: [Volume] = []
    var isLoading = false
    var errorMessage: String?

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            volumes = try await ClientVolume.list()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(name: String) async {
        do {
            try await ClientVolume.delete(name: name)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct VolumeListView: View {
    @State private var vm = VolumesVM()
    @State private var selectedVolumeName: String?

    var body: some View {
        Group {
            if vm.isLoading && vm.volumes.isEmpty {
                ProgressView("Loading volumes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive")
            } else {
                Table(vm.volumes, selection: $selectedVolumeName) {
                    TableColumn("Name") { volume in
                        Text(volume.name)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .width(min: 150)

                    TableColumn("Driver") { volume in
                        Text(volume.driver)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80)

                    TableColumn("Created") { volume in
                        Text(volume.createdAt, format: .dateTime.month(.abbreviated).day().year())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { names in
                    if let name = names.first {
                        VolumeContextMenu(name: name, vm: vm)
                    }
                }
            }
        }
        .navigationTitle("Volumes")
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

struct VolumeContextMenu: View {
    let name: String
    let vm: VolumesVM

    var body: some View {
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await vm.delete(name: name) }
        }
    }
}
