import SwiftUI
import ContainerAPIClient

struct ImageListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ImagesVM()
    @State private var selectedImageRef: String?
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
                .accessibilityLabel("Images list")
                .accessibilityHint("Use arrow keys to change selection. Press Command Delete to remove the selected image. Press Escape to clear selection.")
                .contextMenu(forSelectionType: String.self) { refs in
                    if let ref = refs.first {
                        ImageContextMenu(ref: ref) {
                            selectedImageRef = ref
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
        .onChange(of: selectedImageRef) { appState.selectedImageReference = selectedImageRef }
        .onDeleteCommand {
            if selectedImageRef != nil {
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
            }

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
        .onReceive(NotificationCenter.default.publisher(for: .kegPullImage)) { _ in
            showPullSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegRefresh)) { _ in
            Task { await vm.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .keg,
                  appState.selectedKegSection == .images else { return }
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
                Task { await deleteSelectedImage() }
            }
            .disabled(selectedImageRef == nil)
        } message: {
            Text("Delete the selected image. This action cannot be undone.")
        }
    }

    private var deleteConfirmationTitle: String {
        if let selectedImageRef {
            return "Delete \(selectedImageRef)?"
        }
        return "Delete Image"
    }

    private func handleEscape() {
        if selectedImageRef != nil {
            selectedImageRef = nil
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
    private func deleteSelectedImage() async {
        guard let selectedImageRef else { return }
        do {
            try await vm.delete(reference: selectedImageRef)
            self.selectedImageRef = nil
        } catch {
            vm.errorMessage = error.localizedDescription
        }
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
