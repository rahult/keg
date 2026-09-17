import SwiftUI
import ContainerAPIClient

struct ImageListView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = ImagesVM()
    @State private var selectedImageRefs: Set<String> = []
    @State private var showPullSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var runImageReference: String?
    @State private var tagSourceReference: String?
    @State private var showingPruneConfirmation = false
    @State private var pullingReference: String?
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
                if vm.images.isEmpty {
                    imagesQuickStart
                } else {
                    ContentUnavailableView(
                        "No Images",
                        systemImage: "photo.stack",
                        description: Text("Pull an image to get started")
                    )
                    .accessibilityLabel("No images")
                    .accessibilityHint("Pull an image to populate the list")
                }
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
                        let digest = item.image.digest
                        let bare = digest.hasPrefix("sha256:") ? digest.dropFirst(7) : digest[...]
                        Text(String(bare.prefix(12)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .width(min: 120)

                    TableColumn("Size") { item in
                        Text(vm.imageSizes[item.image.reference] ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 80, max: 120)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
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
                        ImageContextMenu(
                            ref: ref,
                            onRun: {
                                runImageReference = ref
                            },
                            onTag: {
                                tagSourceReference = ref
                            },
                            onDelete: {
                                selectedImageRefs = [ref]
                                showingDeleteConfirmation = true
                            }
                        )
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
        .toolbar {
            ToolbarItem(id: "pull", placement: .primaryAction) {
                Button {
                    showPullSheet = true
                } label: {
                    Label("Pull…", systemImage: "arrow.down.circle")
                }
                .labelStyle(.titleAndIcon)
                .help("Download an image from Docker Hub or a registry")
                .accessibilityHint("Open the pull image sheet")
            }

            ToolbarItem(id: "help", placement: .automatic) {
                SectionHelpButton(section: .images)
            }

            ToolbarItem(id: "run", placement: .automatic) {
                Button {
                    if let ref = selectedImageRefs.first {
                        runImageReference = ref
                    }
                } label: {
                    Label("Run", systemImage: "play")
                }
                .labelStyle(.titleAndIcon)
                .disabled(selectedImageRefs.count != 1)
                .help("Start a new container from the selected image")
                .accessibilityHint("Run the selected image as a new container")
            }

            ToolbarItem(id: "prune", placement: .automatic) {
                Button {
                    showingPruneConfirmation = true
                } label: {
                    Label("Prune…", systemImage: "scissors")
                }
                .labelStyle(.titleAndIcon)
                .help("Remove images no container is using, to free disk space")
                .accessibilityHint("Remove unused images")
            }

            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload the images list (⌘R)")
                .accessibilityHint("Reload the images list")
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
        .sheet(isPresented: Binding(
            get: { runImageReference != nil },
            set: { if !$0 { runImageReference = nil } }
        )) {
            if let ref = runImageReference {
                RunContainerView(initialImage: ref)
            }
        }
        .sheet(isPresented: Binding(
            get: { tagSourceReference != nil },
            set: { if !$0 { tagSourceReference = nil } }
        )) {
            if let ref = tagSourceReference {
                TagImageView(vm: vm, sourceReference: ref)
            }
        }
        .alert("Prune Images?", isPresented: $showingPruneConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Prune Unused") {
                Task { try? await vm.prune(all: false) }
            }
            Button("Prune All", role: .destructive) {
                Task { try? await vm.prune(all: true) }
            }
        } message: {
            Text("Prune Unused removes images not referenced by any container. Prune All removes every image. This cannot be undone.")
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

    /// Popular first images a newcomer can pull with one click.
    private let quickStartImages: [(reference: String, blurb: String)] = [
        ("nginx", "Web server — open http://localhost:8080 once running"),
        ("busybox", "Tiny toolbox — the classic sandbox to learn with"),
        ("hello-world", "The 5-second does-everything-work test"),
        ("postgres", "A real database, ready for your app"),
    ]

    private var imagesQuickStart: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "No Images Yet",
                systemImage: "photo.stack",
                description: Text("An image is the template a container runs from. Pull a popular one to get going.")
            )

            if let pulling = pullingReference {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Pulling \(pulling)… first downloads can take a minute.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(quickStartImages, id: \.reference) { item in
                        Button {
                            quickPull(item.reference)
                        } label: {
                            VStack(spacing: 4) {
                                Text(item.reference)
                                    .font(.subheadline.weight(.medium))
                                Text(item.blurb)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .frame(width: 130)
                            .padding(.vertical, 8)
                        }
                        .help("Pull \(item.reference) from Docker Hub")
                    }
                }
                Button("Pull a different image…") {
                    showPullSheet = true
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("No images")
        .accessibilityHint("Pull a popular image to get started")
    }

    private func quickPull(_ reference: String) {
        pullingReference = reference
        Task {
            defer { pullingReference = nil }
            try? await vm.pull(reference: reference)
        }
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
    let onRun: () -> Void
    let onTag: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("Run…", action: onRun)
        Button("Tag…", action: onTag)
        Divider()
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

/// Adds an additional name:tag reference to an existing image.
struct TagImageView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: ImagesVM
    let sourceReference: String

    @State private var targetReference = ""
    @State private var isTagging = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tag Image")
                .font(.headline)

            LabeledContent("Source") {
                Text(sourceReference)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            TextField("New reference", text: $targetReference, prompt: Text("registry.example.com/name:tag"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New image reference")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Tag") {
                    tag()
                }
                .disabled(targetReference.isEmpty || isTagging)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func tag() {
        isTagging = true
        errorMessage = nil
        Task {
            do {
                try await vm.tag(source: sourceReference, target: targetReference.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isTagging = false
            }
        }
    }
}

struct PullImageView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: ImagesVM
    @State private var reference = ""
    @State private var architecture = "arm64"
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

            Picker("Architecture", selection: $architecture) {
                Text("arm64 · native").tag("arm64")
                Text("amd64 · Rosetta").tag("amd64")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Image architecture")
            if architecture == "amd64" {
                Text("x86 images run translated through Rosetta — slower than native arm64.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                try await vm.pull(reference: reference, architecture: architecture)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPulling = false
        }
    }
}
