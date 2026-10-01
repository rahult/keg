import SwiftUI

// MARK: - Traces View
//
// Langfuse/Braintrust-style trace list over the ClickHouse mirror of the
// agent session logs (TraceStore). Every agent turn is a trace; the detail
// sheet is the whole execution as a structured event timeline (DESIGN.md §17).
//
// Detail lives in a sheet, never `.inspector` — a root-level inspector on
// the split view trips the macOS 27 "Update Constraints in Window pass"
// abort documented on MainView (verified live in ~/.keg/exceptions.log).

struct TracesView: View {
    @State private var vm = TracesVM()
    @State private var selectedTraceID: String?
    @FocusState private var isSearchFocused: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if vm.isLoading && vm.traces.isEmpty {
                loadingView
            } else if vm.filteredTraces.isEmpty {
                emptyStateView
            } else {
                traceTable
            }
        }
        .navigationTitle("Traces")
        .searchable(text: $vm.searchText, prompt: "Search traces")
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItem(id: "clickhouse-status", placement: .status) {
                clickHouseStatusIndicator
            }
            ToolbarItem(id: "refresh", placement: .automatic) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload traces from ClickHouse (⌘R)")
            }
        }
        .task {
            await vm.load(store: appState.traceStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .agents,
                  appState.selectedAgentSection == .traces else { return }
            isSearchFocused = true
        }
        .onExitCommand {
            if selectedTraceID != nil {
                selectedTraceID = nil
            } else if !vm.searchText.isEmpty {
                vm.searchText = ""
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedTraceID != nil },
            set: { if !$0 { selectedTraceID = nil } }
        )) {
            if let id = selectedTraceID,
               let trace = vm.traces.first(where: { $0.traceId == id }),
               let store = vm.store {
                TraceDetailView(trace: trace, store: store)
            }
        }
        .overlay(alignment: .top) {
            if let error = vm.error {
                ErrorBanner(message: error) {
                    vm.error = nil
                }
            }
        }
    }

    // MARK: - ClickHouse status

    /// The probe IS the status: the outcome of the last `listTraces()` —
    /// no separate ping. Before the first query there is nothing to say.
    private var clickHouseStatusIndicator: some View {
        Group {
            if let online = vm.clickHouseOnline {
                HStack(spacing: 4) {
                    Circle()
                        .fill(online ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(online ? "ClickHouse" : "ClickHouse offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(online
                    ? "ClickHouse answered the last query — traces are current"
                    : "ClickHouse did not answer the last query — run `keg db ensure clickhouse` to start the trace database")
            }
        }
    }

    // MARK: - States

    private var loadingView: some View {
        ContentUnavailableView {
            Label("Loading Traces", systemImage: "waveform.path.ecg.rectangle")
        } description: {
            ProgressView()
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading traces")
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(
                vm.searchText.isEmpty ? "No Traces Yet" : "No Matching Traces",
                systemImage: "waveform.path.ecg.rectangle"
            )
        } description: {
            Text(vm.searchText.isEmpty
                ? "Run an agent session — every turn is recorded here."
                : "No trace matches \"\(vm.searchText)\".")
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Table

    private var traceTable: some View {
        Table(vm.filteredTraces, selection: $selectedTraceID) {
            TableColumn("Name") { trace in
                Text(trace.name.isEmpty ? "Untitled trace" : trace.name)
                    .lineLimit(1)
            }
            .width(min: 200)

            TableColumn("Status") { trace in
                TraceStatusBadge(status: trace.sessionStatus)
            }
            .width(min: 90, max: 140)

            TableColumn("Events") { trace in
                Text("\(trace.eventCount)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, max: 90)

            TableColumn("Started") { trace in
                Text(trace.startedAt, style: .time)
                    .foregroundStyle(.secondary)
            }
            .width(min: 100)

            TableColumn("Duration") { trace in
                Text(TraceFormatting.duration(from: trace.startedAt, to: trace.lastEventAt))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, max: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(id, forType: .string)
                } label: {
                    Label("Copy Trace ID", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class TracesVM {
    var traces: [TraceSummary] = []
    var isLoading = false
    var error: String?
    var searchText = ""
    /// nil = not probed yet; the last listTraces outcome IS the service
    /// indicator (a separate ping would cost the same query).
    var clickHouseOnline: Bool?
    private(set) var store: TraceStore?

    var filteredTraces: [TraceSummary] {
        guard !searchText.isEmpty else { return traces }
        return traces.filter { TraceFormatting.matches(searchText, trace: $0) }
    }

    func load(store: TraceStore?) async {
        self.store = store
        await refresh()
    }

    func refresh() async {
        guard let store else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            traces = try await store.listTraces()
            error = nil
            clickHouseOnline = true
        } catch {
            self.error = error.localizedDescription
            clickHouseOnline = false
        }
    }
}

// MARK: - Status badge

/// Session-status dot for a trace. Deliberately its own badge rather than
/// StatusBadge: a *completed* agent run is a success (green), where the
/// container vocabulary colors "stopped/exited" gray.
struct TraceStatusBadge: View {
    let status: String

    private var title: String {
        status.isEmpty ? "Unknown" : status.capitalized
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(TraceFormatting.statusColor(status))
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }
}

// MARK: - Pure formatting (unit-tested)

enum TraceFormatting {
    /// "33s" / "2m 5s" / "1h 3m"; sub-second spans render as milliseconds.
    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        }
        let whole = Int(seconds.rounded(.down))
        if whole < 60 {
            return "\(whole)s"
        }
        let minutes = whole / 60
        if minutes < 60 {
            return "\(minutes)m \(whole % 60)s"
        }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Waterfall delta since the previous event: "120ms" or "1.2s".
    static func delta(_ interval: TimeInterval) -> String {
        let clamped = max(0, interval)
        if clamped < 1 {
            return String(format: "%.0fms", clamped * 1000)
        }
        return String(format: "%.1fs", clamped)
    }

    /// Case-insensitive match on display name or full trace ID.
    static func matches(_ query: String, trace: TraceSummary) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return trace.name.localizedCaseInsensitiveContains(needle)
            || trace.traceId.localizedCaseInsensitiveContains(needle)
    }

    /// DESIGN.md §5: 12-char short IDs in tables; full ID via copy.
    static func shortID(_ id: String) -> String {
        String(id.prefix(12))
    }

    static func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "completed": return .green
        case "failed": return .red
        case "pending": return .blue
        default: return .gray
        }
    }
}

// MARK: - Trace Detail

/// One trace's full execution: header facts (the row-0 summary) + a
/// structured event timeline in the §17 idiom. Static content — a trace is
/// a finished recording — so the auto-scroll fires once on open.
struct TraceDetailView: View {
    let trace: TraceSummary
    let store: TraceStore

    @State private var events: [TraceEventRow] = []
    @State private var isLoading = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    /// Row 0 is the synthetic summary — its facts live in the header, so
    /// the timeline renders only real events.
    private var timelineEvents: [TraceEventRow] {
        events.filter { $0.eventIndex > 0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            } else if let error {
                ContentUnavailableView {
                    Label("Trace Unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timeline
            }
        }
        .frame(width: 720, height: 640)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close trace (Esc)")
            }
        }
        .task {
            await load()
        }
    }

    // MARK: Header (row-0 facts)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(trace.name.isEmpty ? "Untitled trace" : trace.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                TraceStatusBadge(status: trace.sessionStatus)
            }

            HStack(spacing: 16) {
                headerFact("Started") {
                    Text(trace.startedAt, style: .time)
                }
                headerFact("Duration") {
                    Text(TraceFormatting.duration(from: trace.startedAt, to: trace.lastEventAt))
                        .monospaced()
                }
                headerFact("Events") {
                    Text("\(trace.eventCount)")
                        .monospaced()
                }
                headerFact("Trace ID") {
                    HStack(spacing: 4) {
                        Text(TraceFormatting.shortID(trace.traceId))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(trace.traceId, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Copy full trace ID")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func headerFact<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .font(.caption)
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(timelineEvents) { row in
                        TraceTimelineRow(
                            row: row,
                            previousCreatedAt: previousCreatedAt(before: row)
                        )
                        .id(row.eventIndex)
                        if row.eventIndex != timelineEvents.last?.eventIndex {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: isLoading) { _, loading in
                if !loading, let last = timelineEvents.last?.eventIndex {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private func previousCreatedAt(before row: TraceEventRow) -> Date? {
        guard let index = events.firstIndex(where: { $0.eventIndex == row.eventIndex }),
              index > 0 else { return nil }
        return events[index - 1].createdAt
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            events = try await store.traceEvents(traceId: trace.traceId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Timeline row

/// One event in the trace waterfall: colored leading edge + icon per type
/// (§17), time and delta-ms since the previous event like Langfuse.
struct TraceTimelineRow: View {
    let row: TraceEventRow
    let previousCreatedAt: Date?

    private var isError: Bool { row.isError == 1 }

    private var accentColor: Color {
        switch row.eventType {
        case "user": return .blue
        case "assistant": return .purple
        case "tool": return .orange
        case "tool_result": return isError ? .red : .green
        default: return .gray
        }
    }

    private var iconName: String {
        switch row.eventType {
        case "user": return "person.fill"
        case "assistant": return "sparkles"
        case "tool": return "wrench.and.screwdriver.fill"
        case "tool_result": return isError ? "xmark.circle.fill" : "checkmark.circle.fill"
        default: return "circle"
        }
    }

    private var roleText: String {
        switch row.eventType {
        case "user": return "User"
        case "assistant": return "Assistant"
        case "tool": return row.name.isEmpty ? "Tool" : row.name
        case "tool_result": return "Tool Result"
        default: return row.eventType
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(accentColor)
                Text(roleText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Group {
                    Text(row.createdAt, style: .time)
                    if let previousCreatedAt {
                        Text("+" + TraceFormatting.delta(row.createdAt.timeIntervalSince(previousCreatedAt)))
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            content
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(accentColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(roleText) at \(row.createdAt.formatted(date: .omitted, time: .shortened))")
    }

    @ViewBuilder
    private var content: some View {
        switch row.eventType {
        case "user":
            Text(row.input)
                .font(.body)
                .textSelection(.enabled)

        case "assistant":
            Text(row.output)
                .font(.body)
                .textSelection(.enabled)

        case "tool":
            if !row.input.isEmpty {
                DisclosureGroup {
                    Text(row.input)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Input")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case "tool_result":
            DisclosureGroup {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(row.output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.output, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy output")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    Text(isError ? "Error" : "Output")
                }
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
            }

        default:
            EmptyView()
        }
    }
}

#Preview {
    NavigationStack {
        TracesView()
            .environment(AppState())
    }
}
