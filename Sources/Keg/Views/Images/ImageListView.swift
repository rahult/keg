import SwiftUI
import ContainerAPIClient

struct ImageListView: View {
    @State private var vm = ImagesVM()
    @State private var selectedImageRef: String?
    @State private var showPullSheet = false
    @State private var searchText = ""

    private var wrappedImages: [IdentifiableImage] {
        vm.filteredImages.map { IdentifiableImage($0) }
    }

    var body: some View {
        Group {
            if vm.isLoading && vm.images.isEmpty {
                ProgressView("Loading images...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if wrappedImages.isEmpty {
                ContentUnavailableView(
                    "No Images",
                    systemImage: "photo.stack",
                    description: Text("Pull an image to get started")
                )
            } else {
                Table(wrappedImages, selection: $selectedImageRef) {
                    TableColumn("Reference") { item in
                        Text(item.image.reference)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 200)

                    TableColumn("Digest") { item in
                        Text(String(item.image.digest.prefix(19)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .width(min: 120)

                    TableColumn("Size") { item in
                        Text(vm.imageSizes[item.image.reference] ?? "Calculating...")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, max: 120)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { refs in
                    if let ref = refs.first {
                        ImageContextMenu(ref: ref, vm: vm)
                    }
                }
            }
        }
        .navigationTitle("Images")
        .searchable(text: $searchText, prompt: "Search images")
        .onChange(of: searchText) { vm.searchText = searchText }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPullSheet = true
                } label: {
                    Label("Pull...", systemImage: "arrow.down.circle")
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
        .onReceive(NotificationCenter.default.publisher(for: .kegPullImage)) { _ in
            showPullSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRefresh)) { _ in
            Task { await vm.refresh() }
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageView(vm: vm)
        }
    }
}

struct ImageContextMenu: View {
    let ref: String
    let vm: ImagesVM

    var body: some View {
        Button("Copy Reference") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task {
                try? await vm.delete(reference: ref)
            }
        }
    }
}

struct PullImageView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: ImagesVM
    @State private var reference = ""
    @State private var isPulling = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pull Image")
                .font(.headline)

            TextField("Image reference", text: $reference, prompt: Text("nginx:latest"))
                .textFieldStyle(.roundedBorder)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if isPulling {
                ProgressView("Pulling \(reference)...")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pull") {
                    pullImage()
                }
                .disabled(reference.isEmpty || isPulling)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func pullImage() {
        isPulling = true
        errorMessage = nil
        Task {
            do {
                try await vm.pull(reference: reference)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPulling = false
        }
    }
}
