import SwiftUI

/// Skill List - Manage reusable agent skills
struct SkillListView: View {
    @State private var vm = SkillListVM()
    @Environment(AppState.self) private var appState
    @State private var showEditor = false
    @State private var editingSkill: AgentSkillItem?

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingSkill = nil
                    showEditor = true
                } label: {
                    Label("Create Skill", systemImage: "plus")
                }
                .accessibilityLabel("Create new skill")
                .keyboardShortcut("n", modifiers: .command)
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
        .sheet(isPresented: $showEditor) {
            SkillEditorView(skill: editingSkill) { newSkill in
                if editingSkill != nil {
                    vm.updateSkill(newSkill)
                } else {
                    vm.addSkill(newSkill)
                }
            }
        }
    }
    
    private func refresh() async {
        await vm.load()
    }
    
    private var authenticationRequiredView: some View {
        ContentUnavailableView {
            Label("Authentication Required", systemImage: "person.badge.key")
        } description: {
            Text("Connect your Claude API key in Settings to manage skills")
        } actions: {
            Button("Open Settings") {
                appState.currentArea = .keg
                appState.selectedKegSection = .settings
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
                Table(vm.filteredSkills) {
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
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first,
                       let skill = vm.skills.first(where: { $0.id == id }) {
                        Button("Edit") {
                            editingSkill = skill
                            showEditor = true
                        }
                        .accessibilityLabel("Edit skill \(skill.name)")
                        Button("Duplicate") {
                            let copy = AgentSkillItem(
                                id: UUID().uuidString,
                                name: "\(skill.name) (Copy)",
                                description: skill.description,
                                instructions: skill.instructions,
                                examples: skill.examples,
                                createdAt: Date(),
                                updatedAt: Date()
                            )
                            vm.addSkill(copy)
                        }
                        Divider()
                        Button("Export") {
                            // TODO: Export skill
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
            Button("Create Skill") {
                showEditor = true
            }
            .buttonStyle(.borderedProminent)
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
    
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("Basic") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description)
                }
                
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 300)
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
                    .disabled(name.isEmpty || instructions.isEmpty)
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
            name: name,
            description: description,
            instructions: instructions,
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
        // TODO: Load from local storage
        isLoading = false
    }
    
    func addSkill(_ skill: AgentSkillItem) {
        skills.insert(skill, at: 0)
        // TODO: Save to storage
    }
    
    func updateSkill(_ skill: AgentSkillItem) {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        }
        // TODO: Save to storage
    }
    
    func deleteSkill(id: String) {
        skills.removeAll { $0.id == id }
        // TODO: Remove from storage
    }
}

#Preview {
    NavigationStack {
        SkillListView()
            .environment(AppState())
    }
}
