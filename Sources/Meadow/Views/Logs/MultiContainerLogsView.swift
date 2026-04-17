import AppKit
import SwiftUI
import ContainerAPIClient
import ContainerResource

/// Stream-friendly log entry emitted by the coordinator. Stored in a plain
/// array on `MultiContainerLogsVM` — for multi-container streaming the volume
/// is low enough that a cap + trim is cheaper than a ring buffer.
struct MergedLogLine: Identifiable {
    let id = UUID()
    let containerID: String
    let containerName: String
    let color: Color
    let text: String
    let timestamp: Date
}

/// Coordinates `container logs -f` for the selected set of containers. Each
/// selected container gets its own Process + readability handler; deselecting
/// a container terminates its process. Lines are tagged and published back to
/// the view on the main actor.
@Observable
@MainActor
final class MultiContainerLogsVM {
    var available: [ContainerSnapshot] = []
    var selectedIDs: Set<String> = []
    var lines: [MergedLogLine] = []
    var isLoading = false
    var isPaused = false
    var errorMessage: String?

    private let client = ContainerClient()
    private var subscriptions: [String: Process] = [:]
    private var buffers: [String: String] = [:]

    /// 8-color palette cycled through as containers are added. Using the
    /// system tints keeps us light/dark-mode correct.
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint
    ]

    private var colorAssignments: [String: Color] = [:]

    func colorFor(_ id: String) -> Color {
        if let c = colorAssignments[id] { return c }
        let next = Self.palette[colorAssignments.count % Self.palette.count]
        colorAssignments[id] = next
        return next
    }

    /// Only keep the last N lines to bound memory for long-lived streams.
    private let maxLines = 5_000

    func refreshContainers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snaps = try await client.list(filters: .all)
            available = snaps.filter { $0.status == .running }
            // Stop subscriptions for containers that disappeared.
            for id in Array(subscriptions.keys) where !available.contains(where: { $0.id == id }) {
                await unsubscribe(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ container: ContainerSnapshot) {
        if selectedIDs.contains(container.id) {
            selectedIDs.remove(container.id)
            Task { await unsubscribe(container.id) }
        } else {
            selectedIDs.insert(container.id)
            Task { await subscribe(container) }
        }
    }

    func clear() {
        lines.removeAll()
    }

    private func name(for container: ContainerSnapshot) -> String {
        container.configuration.labels["name"] ?? String(container.id.prefix(12))
    }

    private func subscribe(_ container: ContainerSnapshot) async {
        guard subscriptions[container.id] == nil else { return }
        do {
            let process = try ContainerCLI.makeProcess(["container", "logs", "-f", container.id])
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let containerID = container.id
            let displayName = name(for: container)
            let color = colorFor(containerID)

            // Detach the handler when the child emits EOF. Otherwise
            // availableData returns empty Data in a tight loop and pegs
            // the fd_monitoring dispatch queue at ~50% CPU per dead stream.
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                guard let str = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    self?.append(text: str, containerID: containerID, name: displayName, color: color)
                }
            }

            try process.run()
            subscriptions[containerID] = process
        } catch {
            errorMessage = "Failed to stream \(container.id): \(error.localizedDescription)"
            selectedIDs.remove(container.id)
        }
    }

    private func unsubscribe(_ id: String) async {
        guard let process = subscriptions.removeValue(forKey: id) else { return }
        // Clear the handler BEFORE terminate — terminate is async and the
        // handler can fire during teardown if we don't detach it first.
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        process.terminate()
        buffers[id] = nil
    }

    /// Accumulates partial UTF-8 chunks from the handler and emits complete
    /// lines only. A dangling last fragment stays in `buffers` until the next
    /// chunk closes it — otherwise we'd render half-sentences.
    private func append(text: String, containerID: String, name: String, color: Color) {
        guard !isPaused else { return }
        var buf = (buffers[containerID] ?? "") + text
        var lineTexts = buf.components(separatedBy: "\n")
        if buf.hasSuffix("\n") {
            buf = ""
        } else {
            buf = lineTexts.removeLast()
        }
        buffers[containerID] = buf

        for lineText in lineTexts where !lineText.isEmpty {
            lines.append(MergedLogLine(
                containerID: containerID,
                containerName: name,
                color: color,
                text: lineText,
                timestamp: Date()
            ))
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func stopAll() async {
        for id in Array(subscriptions.keys) {
            await unsubscribe(id)
        }
        selectedIDs.removeAll()
    }
}

// MARK: - View

struct MultiContainerLogsView: View {
    @State private var vm = MultiContainerLogsVM()
    @State private var search = ""

    private var filteredLines: [MergedLogLine] {
        guard !search.isEmpty else { return vm.lines }
        return vm.lines.filter {
            $0.text.localizedCaseInsensitiveContains(search) ||
            $0.containerName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HSplitView {
            containerRail
                .frame(minWidth: 220, idealWidth: 240)

            logPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Logs")
        .errorBanner($vm.errorMessage)
        .task { await vm.refreshContainers() }
        .onDisappear { Task { await vm.stopAll() } }
        .toolbar(id: "logs-toolbar") {
            ToolbarItem(id: "pause", placement: .automatic) {
                Button {
                    vm.isPaused.toggle()
                } label: {
                    Label(vm.isPaused ? "Resume" : "Pause",
                          systemImage: vm.isPaused ? "play.fill" : "pause.fill")
                }
                .accessibilityHint("Pause or resume incoming log lines")
            }
            ToolbarItem(id: "clear", placement: .automatic) {
                Button {
                    vm.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .accessibilityHint("Clear the merged log buffer")
            }
            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refreshContainers() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .toolbarRole(.editor)
        .searchable(text: $search, prompt: "Filter logs")
    }

    private var containerRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Containers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if vm.available.isEmpty {
                EmptyState(
                    "No Running Containers",
                    description: "Start a container to stream its logs here.",
                    systemImage: "cube.box"
                )
            } else {
                List {
                    ForEach(vm.available, id: \.id) { container in
                        containerRow(container)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func containerRow(_ container: ContainerSnapshot) -> some View {
        let isOn = vm.selectedIDs.contains(container.id)
        let name = container.configuration.labels["name"] ?? String(container.id.prefix(12))
        let color = vm.colorFor(container.id)
        return HStack(spacing: 10) {
            Circle()
                .fill(isOn ? color : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(isOn ? .semibold : .regular))
                    .lineLimit(1)
                Text(container.configuration.image.reference)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.toggle(container) }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel("\(name), \(isOn ? "streaming" : "not streaming")")
    }

    private var logPane: some View {
        Group {
            if vm.selectedIDs.isEmpty {
                EmptyState(
                    "No Streams Selected",
                    description: "Pick one or more containers on the left to merge their logs here.",
                    systemImage: "terminal"
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredLines) { line in
                                logRow(line)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: vm.lines.count) {
                        if let last = vm.lines.last, !vm.isPaused {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ line: MergedLogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.containerName)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(line.color)
                .frame(minWidth: 80, alignment: .trailing)
            Text(line.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 12)
    }
}
