import SwiftUI

// MARK: - Session Inbox View
/// Craft-style inbox for session management with workflow status, flagging, and bulk actions.

struct SessionInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var vm = SessionInboxVM()
    @State private var selectedIDs: Set<String> = []
    @State private var activeStatusFilter: InboxStatusFilter = .all
    @State private var searchText = ""
    @State private var showingBulkActionMenu = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if vm.isLoading && vm.items.isEmpty {
                loadingView
            } else if filteredItems.isEmpty {
                emptyStateView
            } else {
                sessionTable
            }

            if !selectedIDs.isEmpty {
                Divider()
                bulkActionsToolbar
            }
        }
        .navigationTitle("Session Inbox")
        .searchable(text: $searchText, prompt: "Search sessions")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Select All") { selectAll() }
                    Button("Deselect All") { selectedIDs.removeAll() }
                    Divider()
                    ForEach(InboxStatusFilter.allCases) { filter in
                        Button("Filter: \(filter.label)") {
                            activeStatusFilter = filter
                        }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task {
            await refresh()
        }
        .onChange(of: searchText) { _, _ in }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InboxStatusFilter.allCases) { filter in
                    FilterChip(
                        label: filter.label,
                        count: countForFilter(filter),
                        isSelected: activeStatusFilter == filter,
                        color: filter.color
                    ) {
                        activeStatusFilter = filter
                    }
                }

                Divider()
                    .frame(height: 20)

                Toggle("Flagged", isOn: $vm.showFlaggedOnly)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                if !vm.items.isEmpty {
                    Text("\(filteredItems.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func countForFilter(_ filter: InboxStatusFilter) -> Int {
        switch filter {
        case .all: return vm.items.count
        case .todo: return vm.items.filter { $0.workflowStatus == .inbox }.count
        case .inProgress: return vm.items.filter { $0.workflowStatus == .inProgress }.count
        case .needsReview: return vm.items.filter { $0.workflowStatus == .needsReview }.count
        case .done: return vm.items.filter { $0.workflowStatus == .done }.count
        }
    }

    // MARK: - Session Table

    private var sessionTable: some View {
        Table(filteredItems, selection: $selectedIDs) {
            TableColumn("") { item in
                Image(systemName: item.isFlagged ? "flag.fill" : "flag")
                    .foregroundStyle(item.isFlagged ? .orange : Color.gray)
                    .onTapGesture {
                        Task { await vm.toggleFlag(for: item.sessionID) }
                    }
            }
            .width(28)

            TableColumn("Agent") { item in
                Text(item.agentName)
                    .lineLimit(1)
            }
            .width(min: 100)

            TableColumn("Status") { item in
                StatusPill(status: item.workflowStatus)
            }
            .width(120)

            TableColumn("Summary") { item in
                Text(item.lastMessage ?? "No messages")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 160)

            TableColumn("Updated") { item in
                Text(item.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Remote") { item in
                InboxStatusBadge(status: item.remoteStatus.rawValue.capitalized)
            }
            .width(100)

            TableColumn("Actions") { item in
                HStack(spacing: 4) {
                    ForEach(InboxQuickAction.allCases) { action in
                        Button {
                            Task { await performQuickAction(action, for: item.sessionID) }
                        } label: {
                            Image(systemName: action.icon)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(action.label)
                    }
                }
            }
            .width(80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
    }

    // MARK: - Bulk Actions

    private var bulkActionsToolbar: some View {
        HStack {
            Text("\(selectedIDs.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()
                .frame(height: 16)

            Button {
                Task { await markSelectedAs(.inProgress) }
            } label: {
                Label("Start", systemImage: "play")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                Task { await markSelectedAs(.needsReview) }
            } label: {
                Label("Review", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                Task { await markSelectedAs(.done) }
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()
                .frame(height: 16)

            Button {
                Task { await toggleFlagSelected() }
            } label: {
                Label("Flag", systemImage: "flag")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                Task { await unflagSelected() }
            } label: {
                Label("Unflag", systemImage: "flag.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button(role: .destructive) {
                Task { await deleteSelected() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading inbox...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "tray")
        } description: {
            Text("Sessions matching your filter will appear here")
        }
    }

    // MARK: - Helpers

    private var filteredItems: [InboxItem] {
        var result = vm.items

        switch activeStatusFilter {
        case .all: break
        case .todo: result = result.filter { $0.workflowStatus == .inbox }
        case .inProgress: result = result.filter { $0.workflowStatus == .inProgress }
        case .needsReview: result = result.filter { $0.workflowStatus == .needsReview }
        case .done: result = result.filter { $0.workflowStatus == .done }
        }

        if vm.showFlaggedOnly {
            result = result.filter { $0.isFlagged }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.sessionID.localizedCaseInsensitiveContains(searchText) ||
                $0.agentName.localizedCaseInsensitiveContains(searchText) ||
                ($0.lastMessage?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result
    }

    private func refresh() async {
        await vm.load(client: appState.agentClient)
    }

    private func selectAll() {
        selectedIDs = Set(filteredItems.map(\.sessionID))
    }

    private func markSelectedAs(_ status: SessionWorkflowState.WorkflowStatus) async {
        for id in selectedIDs {
            await vm.setWorkflowStatus(status, for: id)
        }
    }

    private func toggleFlagSelected() async {
        for id in selectedIDs {
            await vm.toggleFlag(for: id)
        }
    }

    private func unflagSelected() async {
        for id in selectedIDs {
            await vm.setFlagged(false, for: id)
        }
    }

    private func deleteSelected() async {
        for id in selectedIDs {
            await vm.deleteSession(id: id, client: appState.agentClient)
        }
        selectedIDs.removeAll()
    }

    private func performQuickAction(_ action: InboxQuickAction, for sessionID: String) async {
        switch action {
        case .flag: await vm.toggleFlag(for: sessionID)
        case .start: await vm.setWorkflowStatus(.inProgress, for: sessionID)
        case .review: await vm.setWorkflowStatus(.needsReview, for: sessionID)
        case .done: await vm.setWorkflowStatus(.done, for: sessionID)
        case .delete: await vm.deleteSession(id: sessionID, client: appState.agentClient)
        }
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.2), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.2) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? color : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status Pill

private struct StatusPill: View {
    let status: SessionWorkflowState.WorkflowStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .inbox: return .blue
        case .inProgress: return .green
        case .needsReview: return .orange
        case .done: return .secondary
        }
    }
}

// MARK: - Inbox Item

struct InboxItem: Identifiable {
    let id: String
    let sessionID: String
    let agentID: String
    let agentName: String
    var workflowStatus: SessionWorkflowState.WorkflowStatus
    var isFlagged: Bool
    var lastMessage: String?
    var remoteStatus: SessionStatus
    let updatedAt: Date
    let createdAt: Date

    var status: SessionWorkflowState.WorkflowStatus { workflowStatus }
}

// MARK: - Inbox Status Filter

enum InboxStatusFilter: String, CaseIterable, Identifiable {
    case all, todo, inProgress, needsReview, done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .needsReview: return "Needs Review"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .all: return .secondary
        case .todo: return .blue
        case .inProgress: return .green
        case .needsReview: return .orange
        case .done: return .gray
        }
    }
}

// MARK: - Quick Actions

enum InboxQuickAction: String, CaseIterable, Identifiable {
    case flag, start, review, done, delete

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .flag: return "flag"
        case .start: return "play"
        case .review: return "eye"
        case .done: return "checkmark"
        case .delete: return "trash"
        }
    }

    var label: String {
        switch self {
        case .flag: return "Flag"
        case .start: return "Start"
        case .review: return "Review"
        case .done: return "Done"
        case .delete: return "Delete"
        }
    }
}

// MARK: - Inbox ViewModel

@Observable
@MainActor
final class SessionInboxVM {
    var items: [InboxItem] = []
    var isLoading = false
    var error: String?
    var showFlaggedOnly = false
    private var workflowStates: [String: SessionWorkflowState] = [:]

    func load(client: ManagedAgentsClient?) async {
        guard let client else {
            items = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let storedStates = try await AgentStorage.shared.loadSessionWorkflowStates()
            workflowStates = Dictionary(uniqueKeysWithValues: storedStates.map { ($0.sessionId, $0) })

            let response = try await client.listAgents()
            var agentNames: [String: String] = [:]
            for agent in response.data {
                agentNames[agent.id] = agent.name
            }

            var allItems: [InboxItem] = []
            for agent in response.data {
                let sessions = try await client.listSessions(agentId: agent.id)
                for session in sessions.data {
                    let state = workflowStates[session.id] ?? SessionWorkflowState(sessionId: session.id)
                    allItems.append(InboxItem(
                        id: session.id,
                        sessionID: session.id,
                        agentID: session.agentId,
                        agentName: agentNames[session.agentId] ?? "Unknown",
                        workflowStatus: state.workflowStatus,
                        isFlagged: state.isFlagged,
                        lastMessage: nil,
                        remoteStatus: session.status,
                        updatedAt: session.updatedAt,
                        createdAt: session.createdAt
                    ))
                }
            }
            items = allItems
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleFlag(for sessionID: String) async {
        guard let idx = items.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        items[idx].isFlagged.toggle()
        await persistState(for: sessionID, isFlagged: items[idx].isFlagged, status: items[idx].workflowStatus)
    }

    func setFlagged(_ flagged: Bool, for sessionID: String) async {
        guard let idx = items.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        items[idx].isFlagged = flagged
        await persistState(for: sessionID, isFlagged: flagged, status: items[idx].workflowStatus)
    }

    func setWorkflowStatus(_ status: SessionWorkflowState.WorkflowStatus, for sessionID: String) async {
        guard let idx = items.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        items[idx].workflowStatus = status
        await persistState(for: sessionID, isFlagged: items[idx].isFlagged, status: status)
    }

    func deleteSession(id: String, client: ManagedAgentsClient?) async {
        guard let client else { return }
        do {
            try await client.deleteSession(id: id)
            items.removeAll { $0.sessionID == id }
            workflowStates.removeValue(forKey: id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func persistState(for sessionID: String, isFlagged: Bool, status: SessionWorkflowState.WorkflowStatus) async {
        var state = workflowStates[sessionID] ?? SessionWorkflowState(sessionId: sessionID)
        state.isFlagged = isFlagged
        state.workflowStatus = status
        state.updatedAt = Date()
        workflowStates[sessionID] = state

        do {
            try await AgentStorage.shared.saveSessionWorkflowStates(Array(workflowStates.values))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Inbox Status Badge

/// Local status badge to avoid ambiguity with shared StatusBadge
private struct InboxStatusBadge: View {
    let status: String

    private var dotColor: Color {
        switch status.lowercased() {
        case "running": return .green
        case "completed": return .blue
        case "failed": return .red
        case "pending": return .yellow
        case "cancelled": return .gray
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
