import SwiftUI
import UniformTypeIdentifiers

/// Skill List - Manage reusable agent skills
struct SkillListView: View {
    @State private var vm = SkillListVM()
    @Environment(AppState.self) private var appState
    @State private var showEditor = false
    @State private var editingSkill: AgentSkillItem?
    @State private var showImportPicker = false
    @State private var showExportSheet = false
    @State private var exportDocument = SkillExportDocument(data: Data())
    @State private var exportFilename = "skill"
    @State private var selectedSkillID: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isAgentAuthenticated {
                authenticationRequiredView
            } else {
                skillTable
            }
        }
        .navigationTitle("Skills")
        .searchable(text: $vm.searchText, prompt: "Search skills")
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editingSkill = nil
                    showEditor = true
                } label: {
                    Label("Create Skill", systemImage: "plus")
                }
                .accessibilityLabel("Create new skill")
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    showImportPicker = true
                } label: {
                    Label("Import Skill", systemImage: "square.and.arrow.down")
                }
                .accessibilityLabel("Import skill")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel("Refresh skill list")
            }
        }
        .task {
            await vm.load()
        }
        .onChange(of: vm.error) { _, newValue in
            appState.updateAgentServiceReachability(for: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kegFocusSearch)) { _ in
            guard appState.currentArea == .agents,
                  appState.selectedAgentSection == .skills else { return }
            isSearchFocused = true
        }
        .onDeleteCommand {
            if let selectedSkillID {
                vm.deleteSkill(id: selectedSkillID)
                self.selectedSkillID = nil
            }
        }
        .onExitCommand {
            if showEditor {
                showEditor = false
            } else if selectedSkillID != nil {
                selectedSkillID = nil
            }
        }
        .sheet(isPresented: $showEditor) {
            SkillEditorView(skill: editingSkill) { newSkill in
                if editingSkill != nil {
                    vm.updateSkill(newSkill)
                } else {
                    vm.addSkill(newSkill)
                }
            }
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await vm.importSkill(from: url) }
            case .failure(let error):
                vm.error = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExportSheet,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                vm.error = error.localizedDescription
            }
        }
        .overlay(alignment: .top) {
            if let issue = currentIssue {
                ErrorBanner(
                    message: issue.message,
                    actionTitle: issue.actionTitle,
                    onAction: { handle(issue: issue) }
                ) {
                    vm.error = nil
                    appState.updateAgentServiceReachability(for: nil)
                }
            }
        }
    }

    private func refresh() async {
        await vm.load()
        appState.updateAgentServiceReachability(for: vm.error)
    }

    private var currentIssue: AgentIssuePresentation? {
        AgentIssuePresentation(message: vm.error)
    }

    private func handle(issue: AgentIssuePresentation) {
        switch issue.kind {
        case .auth:
            appState.openSettings()
        case .offline, .timeout, .generic:
            Task { await refresh() }
        }
    }

    private func beginExport(for skill: AgentSkillItem) {
        Task {
            if let document = await vm.exportDocument(for: skill) {
                exportDocument = document
                exportFilename = skill.name.replacingOccurrences(of: "/", with: "-")
                showExportSheet = true
            }
        }
    }

    private var authenticationRequiredView: some View {
        ContentUnavailableView {
            Label("Authentication Required", systemImage: "person.badge.key")
        } description: {
            Text("Connect your Claude API key in Settings to manage skills")
        } actions: {
            Button("Open Settings") {
                appState.openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityLabel("Authentication required to manage skills")
    }

    private var skillTable: some View {
        Group {
            if vm.skills.isEmpty && !vm.isLoading {
                emptyStateView
            } else {
                Table(vm.filteredSkills, selection: $selectedSkillID) {
                    TableColumn("Name") { skill in
                        Text(skill.name)
                            .fontWeight(.medium)
                            .accessibilityLabel("Skill name: \(skill.name)")
                    }
                    .width(min: 150)

                    TableColumn("Description") { skill in
                        Text(skill.description)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel("Description: \(skill.description)")
                    }
                    .width(min: 200)

                    TableColumn("Updated") { skill in
                        Text(skill.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Updated \(skill.updatedAt, format: .dateTime)")
                    }
                    .width(100)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Skills list")
                .accessibilityValue("\(vm.filteredSkills.count) skills")
                .accessibilityHint("Use arrow keys to change selection. Press Delete to remove the selected skill. Press Escape to clear selection.")
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let skill = vm.filteredSkills.first(where: { $0.id == id }) {
                        Button("Edit") {
                            editingSkill = skill
                            showEditor = true
                        }
                        .accessibilityLabel("Edit skill \(skill.name)")
                        Button("Duplicate") {
                            vm.duplicateSkill(skill)
                        }
                        Divider()
                        Button("Export") {
                            beginExport(for: skill)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            vm.deleteSkill(id: id)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Skills", systemImage: "book")
        } description: {
            Text("Create reusable instructions for your agents")
        } actions: {
            HStack {
                Button("Create Skill") {
                    showEditor = true
                }
                .buttonStyle(.borderedProminent)

                Button("Import Skill") {
                    showImportPicker = true
                }
            }
        }
        .accessibilityLabel("No skills available")
    }
}

// MARK: - Skill Editor

struct SkillEditorView: View {
    let skill: AgentSkillItem?
    let onSave: (AgentSkillItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var examples = ""
    @State private var selectedTab = 0

    private var validation: SkillFormValidation {
        SkillFormValidation(name: name, instructions: instructions)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Basic") {
                    TextField("Name", text: $name)

                    if let message = validation.nameMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    TextField("Description", text: $description)
                }

                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)

                    if let message = validation.instructionsMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()
            .tabItem {
                Label("YAML", systemImage: "doc.text")
            }
            .tag(0)

            VStack(alignment: .leading, spacing: 12) {
                Text("Examples & Usage Guide")
                    .font(.headline)
                TextEditor(text: $examples)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 400)
            }
            .padding()
            .tabItem {
                Label("Markdown", systemImage: "doc.richtext")
            }
            .tag(1)
        }
        .frame(width: 600, height: 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!validation.isValid)
            }
        }
        .onAppear {
            if let skill = skill {
                name = skill.name
                description = skill.description
                instructions = skill.instructions
                examples = skill.examples ?? ""
            }
        }
    }

    private func save() {
        let now = Date()
        let newSkill = AgentSkillItem(
            id: skill?.id ?? UUID().uuidString,
            name: validation.trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: validation.trimmedInstructions,
            examples: examples.isEmpty ? nil : examples,
            createdAt: skill?.createdAt ?? now,
            updatedAt: now
        )
        onSave(newSkill)
        dismiss()
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class SkillListVM {
    var skills: [AgentSkillItem] = []
    var isLoading = false
    var error: String?
    var searchText = ""

    var filteredSkills: [AgentSkillItem] {
        if searchText.isEmpty { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            skills = try await AgentStorage.shared.loadSkills()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addSkill(_ skill: AgentSkillItem) {
        skills.insert(skill, at: 0)
        Task { await persistSkills() }
    }

    func updateSkill(_ skill: AgentSkillItem) {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
            Task { await persistSkills() }
        }
    }

    func duplicateSkill(_ skill: AgentSkillItem) {
        let now = Date()
        let copy = AgentSkillItem(
            id: UUID().uuidString,
            name: "\(skill.name) (Copy)",
            description: skill.description,
            instructions: skill.instructions,
            examples: skill.examples,
            createdAt: now,
            updatedAt: now
        )
        addSkill(copy)
    }

    func deleteSkill(id: String) {
        skills.removeAll { $0.id == id }
        Task { await persistSkills() }
    }

    func importSkill(from url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let skill = try await AgentStorage.shared.importSkill(from: data)
            skills.insert(skill, at: 0)
            try await AgentStorage.shared.saveSkills(skills)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func exportDocument(for skill: AgentSkillItem) async -> SkillExportDocument? {
        do {
            let data = try await AgentStorage.shared.exportSkill(skill)
            return SkillExportDocument(data: data)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func persistSkills() async {
        do {
            try await AgentStorage.shared.saveSkills(skills)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Export Document

struct SkillExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    NavigationStack {
        SkillListView()
            .environment(AppState())
    }
}
