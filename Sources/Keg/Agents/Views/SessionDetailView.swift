import SwiftUI
import UniformTypeIdentifiers

/// Session Detail View - Full transcript display with export and actions
struct SessionDetailView: View {
    let session: Session
    let agent: Agent?
    
    @State private var vm: SessionDetailVM
    @Environment(AppState.self) private var appState
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteAlert = false
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @State private var labelDraft = ""
    
    init(session: Session, agent: Agent? = nil) {
        self.session = session
        self.agent = agent
        self._vm = State(initialValue: SessionDetailVM(session: session))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
            
            if vm.isLoading && vm.events.isEmpty {
                loadingView
            } else if vm.error != nil && vm.events.isEmpty {
                errorView
            } else {
                transcriptView
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await loadEvents() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(vm.isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh transcript")
                
                Menu {
                    Button {
                        copyTranscript()
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: .command)
                    
                    Button {
                        showingExportSheet = true
                    } label: {
                        Label("Export as Markdown", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions menu")
            }
        }
        .task {
            await loadSessionData()
        }
        .onChange(of: vm.error) { _, newValue in
            appState.updateAgentServiceReachability(for: newValue)
        }
        .onAppear {
            labelDraft = vm.workflowState.labels.joined(separator: ", ")
        }
        .onChange(of: vm.workflowState.labels) { _, labels in
            labelDraft = labels.joined(separator: ", ")
        }
        .alert("Delete Session", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSession() }
            }
        } message: {
            Text("Are you sure you want to delete this session? This action cannot be undone.")
        }
        .fileExporter(
            isPresented: $showingExportSheet,
            document: MarkdownDocument(content: vm.markdownExport),
            contentType: .plainText,
            defaultFilename: "session-\(session.id.prefix(8))-\(formattedDate()).md"
        ) { result in
            switch result {
            case .success(let url):
                exportURL = url
            case .failure(let error):
                vm.exportError = error.localizedDescription
            }
        }
        .overlay(alignment: .top) {
            if let issue = bannerIssue {
                ErrorBanner(
                    message: issue.message,
                    actionTitle: issue.actionTitle,
                    onAction: { handle(issue: issue) }
                ) {
                    if vm.exportError != nil {
                        vm.exportError = nil
                    } else {
                        vm.error = nil
                        appState.updateAgentServiceReachability(for: nil)
                    }
                }
            }
        }
    }
    
    private func loadSessionData() async {
        await vm.loadLocalState()
        if let client = await appState.agentClient {
            await vm.loadEvents(client: client)
            appState.updateAgentServiceReachability(for: vm.error)
        }
    }

    private func loadEvents() async {
        if let client = await appState.agentClient {
            await vm.loadEvents(client: client)
            appState.updateAgentServiceReachability(for: vm.error)
        }
    }

    private var currentIssue: AgentIssuePresentation? {
        AgentIssuePresentation(message: vm.error)
    }

    private var bannerIssue: AgentIssuePresentation? {
        if let exportError = vm.exportError {
            return AgentIssuePresentation(message: exportError)
        }
        return vm.error != nil && vm.events.isEmpty ? currentIssue : nil
    }

    private func handle(issue: AgentIssuePresentation) {
        switch issue.kind {
        case .auth:
            appState.currentArea = .agents
            appState.selectedAgentSection = .account
        case .offline, .timeout, .generic:
            Task { await loadEvents() }
        }
    }
    
    private func deleteSession() async {
        if let client = await appState.agentClient {
            do {
                try await client.deleteSession(id: session.id)
                dismiss()
            } catch {
                vm.error = AgentIssuePresentation(error: error).message
            }
        }
    }
    
    private func copyTranscript() {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(vm.markdownExport, forType: .string)
        #endif
    }
    
    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: session.createdAt)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent?.name ?? "Unknown Agent")
                        .font(.headline)
                    
                    Text("Session \(session.id.prefix(12))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadge(status: session.status.rawValue.capitalized)
                    
                    let duration = session.updatedAt.timeIntervalSince(session.createdAt)
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(spacing: 16) {
                Label {
                    Text(session.createdAt, style: .date)
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                Label {
                    Text(session.createdAt, style: .time)
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(vm.events.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            workflowSection
            activitySection
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Content Views
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading transcript...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading transcript")
    }
    
    private var errorView: some View {
        let issue = currentIssue ?? AgentIssuePresentation(kind: .generic, message: vm.error ?? "Unknown error")

        return ContentUnavailableView {
            Label(issue.kind == .auth ? "Authentication Required" : "Failed to Load", systemImage: issue.kind == .auth ? "person.badge.key" : "exclamationmark.triangle")
        } description: {
            Text(issue.message)
        } actions: {
            Button(issue.actionTitle) {
                handle(issue: issue)
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session transcript unavailable. \(issue.message)")
    }
    
    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(vm.displayEvents.enumerated()), id: \.offset) { index, event in
                        EventRow(event: event, isLast: index == vm.displayEvents.count - 1)
                            .id(index)
                    }
                }
                .padding()
            }
            .onChange(of: vm.events.count) { _, _ in
                if let lastIndex = vm.displayEvents.indices.last {
                    withAnimation {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workflow")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                Toggle(isOn: Binding(
                    get: { vm.workflowState.isFlagged },
                    set: { isFlagged in
                        Task { await vm.setFlagged(isFlagged) }
                    }
                )) {
                    Label("Flagged", systemImage: vm.workflowState.isFlagged ? "flag.fill" : "flag")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Picker("Workflow Status", selection: Binding(
                    get: { vm.workflowState.workflowStatus },
                    set: { newStatus in
                        Task { await vm.setWorkflowStatus(newStatus) }
                    }
                )) {
                    ForEach(SessionWorkflowState.WorkflowStatus.allCases) { status in
                        Text(status.rawValue).tag(status)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                TextField("Labels (comma-separated)", text: $labelDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await vm.updateLabels(from: labelDraft) }
                    }

                Button("Save Labels") {
                    Task { await vm.updateLabels(from: labelDraft) }
                }
                .controlSize(.small)
            }

            if vm.workflowState.labels.isEmpty {
                Text("No labels")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(vm.workflowState.labels.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(vm.activityEntries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vm.activityEntries.isEmpty {
                Text("No local activity yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.activityEntries.prefix(6)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.caption)
                                Text(entry.timestamp, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: SessionEvent
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            eventHeader

            eventContent
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)

        if !isLast {
            Divider()
                .padding(.leading, 16)
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [roleText]
        if let content = event.content {
            let preview = content.prefix(100)
            parts.append(String(preview))
        }
        if let timestamp = event.timestamp {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            parts.append("at \(formatter.string(from: timestamp))")
        }
        return parts.joined(separator: ". ")
    }
    
    @ViewBuilder
    private var eventHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(accentColor)
            
            Text(roleText)
                .font(.subheadline)
                .fontWeight(.medium)
            
            Spacer()
            
            if let timestamp = event.timestamp {
                Text(timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    @ViewBuilder
    private var eventContent: some View {
        switch event.type {
        case .userMessage:
            Text(event.content ?? "")
                .font(.body)
                .textSelection(.enabled)
            
        case .assistantMessage:
            Text(event.content ?? "")
                .font(.body)
                .textSelection(.enabled)
            
        case .toolUse:
            if let tool = event.toolUse {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.tool)
                        .font(.headline)
                        .foregroundStyle(accentColor)
                    
                    Text(formatToolInput(tool.toolInput))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            
        case .toolResult:
            if let result = event.toolResult {
                VStack(alignment: .leading, spacing: 4) {
                    if result.isError == true {
                        Label("Error", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    
                    Text(formatToolOutput(result.toolOutput))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(result.isError == true ? .red : .primary)
                        .textSelection(.enabled)
                }
            }
            
        case .error:
            if let content = event.content {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(content)
                        .foregroundStyle(.orange)
                }
                .font(.body)
            }
            
        case .statusUpdate:
            if let content = event.content {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(content)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
    
    private var iconName: String {
        switch event.type {
        case .userMessage: return "person.fill"
        case .assistantMessage: return "sparkles"
        case .toolUse: return "wrench.and.screwdriver.fill"
        case .toolResult: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .statusUpdate: return "info.circle.fill"
        }
    }
    
    private var roleText: String {
        switch event.type {
        case .userMessage: return "User"
        case .assistantMessage: return "Assistant"
        case .toolUse: return "Tool Call"
        case .toolResult: return "Tool Result"
        case .error: return "Error"
        case .statusUpdate: return "Status"
        }
    }
    
    private var accentColor: Color {
        switch event.type {
        case .userMessage: return .blue
        case .assistantMessage: return .purple
        case .toolUse: return .orange
        case .toolResult: return .green
        case .error: return .red
        case .statusUpdate: return .blue
        }
    }
    
    private var backgroundColor: Color {
        switch event.type {
        case .userMessage: return .blue.opacity(0.05)
        case .assistantMessage: return .purple.opacity(0.05)
        case .toolUse: return .orange.opacity(0.05)
        case .toolResult: return .green.opacity(0.05)
        case .error: return .red.opacity(0.05)
        case .statusUpdate: return .blue.opacity(0.05)
        }
    }
    
    private func formatToolInput(_ input: [String: AnyCodable]) -> String {
        var result: [String: Any] = [:]
        for (key, value) in input {
            result[key] = value.value
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: input)
        }
        return string
    }
    
    private func formatToolOutput(_ output: AnyCodable) -> String {
        if let string = output.value as? String {
            // Try to parse as JSON
            if let data = string.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let prettyString = String(data: prettyData, encoding: .utf8) {
                return prettyString
            }
            return string
        }
        
        return String(describing: output.value)
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class SessionDetailVM {
    let session: Session
    var events: [SessionEvent] = []
    var isLoading = false
    var error: String?
    var exportError: String?
    var workflowState: SessionWorkflowState
    var activityEntries: [SessionActivityEntry] = []
    
    var displayEvents: [SessionEvent] {
        events
    }
    
    var markdownExport: String {
        var output = "# Session Transcript\n\n"
        output += "**Session ID:** \(session.id)\n"
        output += "**Agent:** \(session.agentId)\n"
        output += "**Status:** \(session.status.rawValue)\n"
        output += "**Created:** \(session.createdAt.formatted())\n"
        output += "**Updated:** \(session.updatedAt.formatted())\n\n"
        output += "---\n\n"
        
        for event in events {
            output += formatEventAsMarkdown(event)
            output += "\n---\n\n"
        }
        
        return output
    }
    
    init(session: Session) {
        self.session = session
        self.workflowState = SessionWorkflowState(sessionId: session.id)
    }

    func loadLocalState() async {
        do {
            let states = try await AgentStorage.shared.loadSessionWorkflowStates()
            workflowState = states.first(where: { $0.sessionId == session.id }) ?? SessionWorkflowState(sessionId: session.id)

            let existingActivities = try await AgentStorage.shared.loadSessionActivityEntries(sessionId: session.id)
            if existingActivities.isEmpty {
                let initialEntry = SessionActivityEntry(
                    sessionId: session.id,
                    timestamp: session.createdAt,
                    kind: "session",
                    message: "Remote session created"
                )
                try await AgentStorage.shared.appendSessionActivityEntry(initialEntry)
                activityEntries = [initialEntry]
            } else {
                activityEntries = existingActivities.sorted { $0.timestamp > $1.timestamp }
            }
        } catch {
            self.error = AgentIssuePresentation(error: error).message
        }
    }

    func loadEvents(client: ManagedAgentsClient?) async {
        guard let client else {
            error = "Not authenticated"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            events = try await client.getEvents(sessionId: session.id)
            await appendActivity(kind: "refresh", message: "Transcript refreshed in Keg")
        } catch {
            self.error = AgentIssuePresentation(error: error).message
        }
    }

    func setFlagged(_ isFlagged: Bool) async {
        workflowState.isFlagged = isFlagged
        workflowState.updatedAt = Date()
        await persistWorkflowState(activityMessage: isFlagged ? "Session flagged" : "Session unflagged")
    }

    func setWorkflowStatus(_ status: SessionWorkflowState.WorkflowStatus) async {
        workflowState.workflowStatus = status
        workflowState.updatedAt = Date()
        await persistWorkflowState(activityMessage: "Workflow status changed to \(status.rawValue)")
    }

    func updateLabels(from labelString: String) async {
        workflowState.labels = labelString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        workflowState.updatedAt = Date()
        await persistWorkflowState(activityMessage: workflowState.labels.isEmpty ? "Labels cleared" : "Labels updated to \(workflowState.labels.joined(separator: ", "))")
    }

    private func persistWorkflowState(activityMessage: String) async {
        do {
            var states = try await AgentStorage.shared.loadSessionWorkflowStates()
            if let index = states.firstIndex(where: { $0.sessionId == session.id }) {
                states[index] = workflowState
            } else {
                states.append(workflowState)
            }
            try await AgentStorage.shared.saveSessionWorkflowStates(states)
            await appendActivity(kind: "workflow", message: activityMessage)
        } catch {
            self.error = AgentIssuePresentation(error: error).message
        }
    }

    private func appendActivity(kind: String, message: String) async {
        let entry = SessionActivityEntry(sessionId: session.id, kind: kind, message: message)
        do {
            try await AgentStorage.shared.appendSessionActivityEntry(entry)
            activityEntries.insert(entry, at: 0)
            activityEntries.sort { $0.timestamp > $1.timestamp }
        } catch {
            self.error = AgentIssuePresentation(error: error).message
        }
    }
    
    private func formatEventAsMarkdown(_ event: SessionEvent) -> String {
        let role: String
        var content: String
        
        switch event.type {
        case .userMessage:
            role = "## User"
            content = event.content ?? ""
        case .assistantMessage:
            role = "## Assistant"
            content = event.content ?? ""
        case .toolUse:
            role = "## Tool Call"
            if let tool = event.toolUse {
                content = "**Tool:** `\(tool.tool)`\n\n```json\n\(formatToolInputJSON(tool.toolInput))\n```"
            } else {
                content = ""
            }
        case .toolResult:
            role = "## Tool Result"
            if let result = event.toolResult {
                content = "```json\n\(result.toolOutput)\n```"
            } else {
                content = ""
            }
        case .error:
            role = "## Error"
            content = event.content ?? ""
        case .statusUpdate:
            role = "## Status Update"
            content = event.content ?? ""
        }
        
        let timestamp = event.timestamp.map { $0.formatted(date: .omitted, time: .standard) } ?? ""
        
        return "\(role) \(timestamp.isEmpty ? "" : "(\(timestamp))")\n\n\(content)"
    }
    
    private func formatToolInputJSON(_ input: [String: AnyCodable]) -> String {
        var result: [String: Any] = [:]
        for (key, val) in input {
            result[key] = val.value
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: input)
        }
        return string
    }
}

// MARK: - Markdown Export Document

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    
    var content: String
    
    init(content: String) {
        self.content = content
    }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            content = string
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = content.data(using: .utf8)!
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    NavigationStack {
        SessionDetailView(
            session: Session(
                id: "test-session-123",
                type: "agent",
                agentId: "agent-456",
                agentVersion: 1,
                environmentId: "env-789",
                status: .completed,
                createdAt: Date().addingTimeInterval(-3600),
                updatedAt: Date()
            ),
            agent: nil
        )
        .environment(AppState())
    }
}
#endif
