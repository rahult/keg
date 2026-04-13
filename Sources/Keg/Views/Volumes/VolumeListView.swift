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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if vm.isLoading && vm.volumes.isEmpty {
                ProgressView("Loading volumes...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.volumes.isEmpty {
                ContentUnavailableView("No Volumes", systemImage: "externaldrive")
            } else {
                Table(vm.volumes, selection: .constant(nil)) {
                    TableColumn("Name") { volume in
                        Text(volume.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150)

                    TableColumn("Driver") { volume in
                        Text(volume.driver)
                    }
                    .width(min: 80)

                    TableColumn("Created") { volume in
                        Text(volume.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    }
                    .width(min: 100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { _ in }
            }
        }
        .navigationTitle("Volumes")
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
