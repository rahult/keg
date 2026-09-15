import AppKit
import SwiftUI

// MARK: - File Entry

struct ContainerFileEntry: Identifiable {
    let id: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let permissions: String

    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "arrow.triangle.branch" }
        return "doc"
    }
}

// MARK: - View Model

@Observable
@MainActor
final class ContainerFilesVM {
    let containerID: String

    var path: String
    var entries: [ContainerFileEntry] = []
    var isLoading = false
    var errorMessage: String?
    var pathHistory: [String] = []

    init(containerID: String) {
        self.containerID = containerID
        self.path = "/"
    }

    var canGoBack: Bool { !pathHistory.isEmpty }

    var parentPath: String {
        let trimmed = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        guard trimmed != "/" else { return "/" }
        let parent = (trimmed as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let (_, output) = try await ContainerCLI.run(["container", "exec", containerID, "ls", "-la", "--", path])
            entries = Self.parseListings(output).sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func open(_ entry: ContainerFileEntry) {
        guard entry.isDirectory else { return }
        pathHistory.append(path)
        path = joinPath(path, entry.name)
        Task { await load() }
    }

    func goBack() {
        guard let previous = pathHistory.popLast() else { return }
        path = previous
        Task { await load() }
    }

    func goUp() {
        guard path != "/" else { return }
        pathHistory.append(path)
        path = parentPath
        Task { await load() }
    }

    func navigate(to newPath: String) {
        var cleaned = newPath.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return }
        if !cleaned.hasPrefix("/") { cleaned = "/" + cleaned }
        while cleaned.count > 1 && cleaned.hasSuffix("/") { cleaned = String(cleaned.dropLast()) }
        pathHistory.append(path)
        path = cleaned
        Task { await load() }
    }

    /// Download a container file to a local path chosen by the user.
    func download(_ entry: ContainerFileEntry) -> Bool {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = entry.name
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return false }

        let remote = joinPath(path, entry.name)
        let result = runSync(["container", "copy", "\(containerID):\(remote)", destination.path])
        if result.0 != 0 {
            errorMessage = result.1.isEmpty ? "Download failed" : result.1
            return false
        }
        return true
    }

    /// Upload a local file into the current container directory.
    func upload() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK, let source = openPanel.url else { return }

        let destination = joinPath(path, source.lastPathComponent)
        let result = runSync(["container", "copy", source.path, "\(containerID):\(destination)"])
        if result.0 != 0 {
            errorMessage = result.1.isEmpty ? "Upload failed" : result.1
            return
        }
        Task { await load() }
    }

    func delete(_ entry: ContainerFileEntry) {
        let remote = joinPath(path, entry.name)
        let result = runSync(["container", "exec", containerID, "rm", "-rf", "--", remote])
        if result.0 != 0 {
            errorMessage = result.1.isEmpty ? "Delete failed" : result.1
            return
        }
        Task { await load() }
    }

    // MARK: - Helpers

    private func joinPath(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// Runs the CLI off the main thread (panel callbacks come back on main).
    private nonisolated func runSync(_ args: [String]) -> (Int32, String) {
        guard let process = try? ContainerCLI.makeProcess(args) else {
            return (1, "Container CLI is not installed")
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (1, error.localizedDescription)
        }
    }

    /// Parses `ls -la` output. Names may contain spaces, so the name is
    /// everything after the eight fixed leading fields; symlink targets
    /// (`name -> target`) are split off.
    nonisolated static func parseListings(_ output: String) -> [ContainerFileEntry] {
        var result: [ContainerFileEntry] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 9 else { continue }
            let perms = String(fields[0])
            guard perms != "total" else { continue } // summary line, not an entry
            let kind = perms.first ?? "-"
            if kind == "d" && (fields[8] == "." || fields[8] == "..") { continue }

            let size = Int64(fields[4]) ?? 0
            let headerCount = 8
            var name = fields.dropFirst(headerCount).joined(separator: " ")
            var isLink = false
            if let arrow = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrow.lowerBound])
                isLink = true
            }
            guard !name.isEmpty else { continue }

            result.append(ContainerFileEntry(
                id: name,
                name: name,
                isDirectory: kind == "d",
                isSymlink: kind == "l" || isLink,
                size: size,
                permissions: perms
            ))
        }
        return result
    }
}

// MARK: - File Browser View

struct ContainerFilesView: View {
    @State private var vm: ContainerFilesVM
    @State private var selectedIDs: Set<String> = []
    @State private var pathInput = "/"
    @State private var showDeleteConfirmation = false
    @State private var downloadSucceeded: String?

    init(containerID: String) {
        _vm = State(wrappedValue: ContainerFilesVM(containerID: containerID))
    }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            listArea
            downloadBanner
        }
        .overlay {
            if vm.isLoading && vm.entries.isEmpty {
                ProgressView("Loading…")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.upload()
                } label: {
                    Label("Upload…", systemImage: "arrow.up.doc")
                }
                .accessibilityHint("Upload a file into this directory")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await vm.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = selectedIDs.first, let entry = vm.entries.first(where: { $0.id == id }) {
                    vm.delete(entry)
                }
            }
        } message: {
            Text("This deletes the selected item from the container. This cannot be undone.")
        }
        .task {
            await vm.load()
            pathInput = vm.path
        }
        .onChange(of: vm.path) {
            pathInput = vm.path
        }
        .onChange(of: vm.errorMessage) {
            if vm.errorMessage != nil {
                // Surface transient copy errors without a permanent banner
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    vm.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Subviews

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                vm.goBack()
                pathInput = vm.path
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!vm.canGoBack)
            .accessibilityLabel("Back")

            Button {
                vm.goUp()
                pathInput = vm.path
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .disabled(vm.path == "/")
            .accessibilityLabel("Parent directory")

            TextField("Path", text: $pathInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit {
                    vm.navigate(to: pathInput)
                    pathInput = vm.path
                }
                .accessibilityLabel("Container path")

            Button {
                vm.navigate(to: pathInput)
                pathInput = vm.path
            } label: {
                Image(systemName: "return")
            }
            .accessibilityLabel("Go to path")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var listArea: some View {
        if vm.entries.isEmpty && !vm.isLoading {
            ContentUnavailableView(
                vm.errorMessage != nil ? "Cannot Read Directory" : "Empty Directory",
                systemImage: vm.errorMessage != nil ? "exclamationmark.triangle" : "folder",
                description: Text(vm.errorMessage ?? "This directory has no visible entries.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            fileTable
        }
    }

    private var fileTable: some View {
        Table(vm.entries, selection: $selectedIDs) {
            TableColumn("Name") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.iconName)
                        .foregroundStyle(entry.isDirectory ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.isDirectory { vm.open(entry) }
                }
            }
            .width(min: 180)

            TableColumn("Size") { entry in
                if entry.isDirectory {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, max: 120)

            TableColumn("Permissions") { entry in
                Text(entry.permissions)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, max: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let entry = vm.entries.first(where: { $0.id == id }) {
                if entry.isDirectory {
                    Button("Open") { vm.open(entry) }
                } else {
                    Button("Download…") {
                        if vm.download(entry) {
                            downloadSucceeded = entry.name
                        }
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
    }

    @ViewBuilder
    private var downloadBanner: some View {
        if let name = downloadSucceeded {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Downloaded \(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(.opacity)
        }
    }
}
