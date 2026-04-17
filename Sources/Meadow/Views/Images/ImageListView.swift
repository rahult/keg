import SwiftUI
import ContainerAPIClient

struct ImageListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ImagesVM()
    @State private var selectedImageRefs: Set<String> = []
    @State private var showPullSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

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
                .accessibilityLabel("No images")
                .accessibilityHint("Pull an image to populate the list")
            } else {
                Table(wrappedImages, selection: $selectedImageRefs) {
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
                .accessibilityLabel("Images list")
                .accessibilityValue("\(wrappedImages.count) images")
                .accessibilityHint("Use arrow keys to change selection. Press Command Delete to remove the selected image. Press Escape to clear selection.")
                .contextMenu(forSelectionType: String.self) { refs in
                    if refs.count > 1 {
                        Button("Delete \(refs.count) Images", role: .destructive) {
                            selectedImageRefs = refs
                            showingDeleteConfirmation = true
                        }
                    } else if let ref = refs.first {
                        ImageContextMenu(ref: ref) {
                            selectedImageRefs = [ref]
                            showingDeleteConfirmation = true
                        }
                    }
                }
            }
        }
        .navigationTitle("Images")
        .searchable(text: $searchText, prompt: "Search images")
        .searchFocused($isSearchFocused)
        .onChange(of: searchText) { vm.searchText = searchText }
        .onChange(of: selectedImageRefs) { appState.selectedImageReference = selectedImageRefs.first }
        .onDeleteCommand {
            if !selectedImageRefs.isEmpty {
                showingDeleteConfirmation = true
            }
        }
        .onExitCommand {
            handleEscape()
        }
        .toolbar(id: "images-toolbar") {
            ToolbarItem(id: "pull", placement: .primaryAction) {
                Button {
                    showPullSheet = true
                } label: {
                    Label("Pull...", systemImage: "arrow.down.circle")
                }
                .accessibilityHint("Open the pull image sheet")
            }

            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityHint("Reload the images list")
            }
        }
        .toolbarRole(.editor)
        .task {
            await vm.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meadowPullImage)) { _ in
            showPullSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .meadowRefresh)) { _ in
            Task { await vm.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meadowFocusSearch)) { _ in
            guard appState.selectedMeadowSection == .images else { return }
            isSearchFocused = true
        }
        .onDisappear {
            appState.selectedImageReference = nil
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageView(vm: vm)
        }
        .alert(deleteConfirmationTitle, isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedImages() }
            }
            .disabled(selectedImageRefs.isEmpty)
        } message: {
            Text(selectedImageRefs.count > 1
                 ? "Delete \(selectedImageRefs.count) images. This action cannot be undone."
                 : "Delete the selected image. This action cannot be undone.")
        }
    }

    private var deleteConfirmationTitle: String {
        if selectedImageRefs.count > 1 {
            return "Delete \(selectedImageRefs.count) Images?"
        }
        if let ref = selectedImageRefs.first {
            return "Delete \(ref)?"
        }
        return "Delete Image"
    }

    private func handleEscape() {
        if !selectedImageRefs.isEmpty {
            selectedImageRefs = []
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
    private func deleteSelectedImages() async {
        for ref in selectedImageRefs {
            do {
                try await vm.delete(reference: ref)
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
        selectedImageRefs = []
    }
}

struct ImageContextMenu: View {
    let ref: String
    let onDelete: () -> Void

    var body: some View {
        Button("Copy Reference") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ref, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) {
            onDelete()
        }
        .accessibilityHint("Delete the selected image")
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
                .accessibilityLabel("Image reference")
                .accessibilityHint("Enter the image name and optional tag to pull")

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
                .accessibilityHint("Pull the requested image")
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
