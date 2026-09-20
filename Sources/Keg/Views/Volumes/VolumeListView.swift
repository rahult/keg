import SwiftUI
import ContainerAPIClient
import ContainerResource

@Observable
@MainActor
final class VolumesVM {
    var volumes: [VolumeConfiguration] = []
    var isLoading = false
    var errorMessage: String?

    func create(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let (code, out) = try await ContainerCLI.run(["container", "volume", "create", trimmed])
            if code != 0 {
                errorMessage = out.isEmpty ? "Failed to create volume" : out
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
    @State private var showingCreate = false
    @State private var newVolumeName = ""
    @State private var selectedVolumeName: String?
    @State private var showingDeleteConfirmation = false
    @State private var volumeToDelete: String?

    var body: some View {
        Group {
            if vm.isLoading && vm.volumes.isEmpty {
                ProgressView("Loading volumes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive", description: Text("Volumes will appear here when created"))
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
                        Text(volume.creationDate, format: .dateTime.month(.abbreviated).day().year())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: String.self) { names in
                    if let name = names.first {
                        VolumeContextMenu(name: name, onDelete: {
                            volumeToDelete = name
                            showingDeleteConfirmation = true
                        })
                    }
                }
            }
        }
        .alert("Create Volume", isPresented: $showingCreate) {
            TextField("Volume name", text: $newVolumeName)
            Button("Create") {
                let name = newVolumeName
                newVolumeName = ""
                Task { await vm.create(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Named volumes persist data beyond a container's lifecycle.")
        }
        .navigationTitle("Volumes")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SectionHelpButton(section: .volumes)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showingCreate = true
                } label: {
                    Label("Create Volume…", systemImage: "plus")
                }
                .help("Create a new named volume")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload the volumes list (⌘R)")
            }
        }
        .errorBanner($vm.errorMessage)
        .alert("Delete Volume", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let name = volumeToDelete {
                    Task { await vm.delete(name: name) }
                }
            }
        } message: {
            if let name = volumeToDelete {
                Text("Are you sure you want to delete the volume \"\(name)\"? This action cannot be undone.")
            }
        }
        .task {
            await vm.refresh()
        }
    }
}

struct VolumeContextMenu: View {
    let name: String
    let onDelete: () -> Void

    var body: some View {
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) {
            onDelete()
        }
    }
}
