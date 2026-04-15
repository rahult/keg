import SwiftUI

// MARK: - Skill Picker Sheet

struct SkillPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedSkills: [AgentSkill]
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedSkillID = ""
    @State private var skillConfig: [String: String] = [:]
    @State private var showSkillConfig = false

    private let availableSkills: [(id: String, name: String, description: String, category: String)] = [
        ("github", "GitHub", "Interact with GitHub using gh CLI for issues, PRs, CI runs, and API queries", "Development"),
        ("clerk", "Clerk Auth", "Add Clerk authentication to web or native apps with prebuilt or custom flows", "Authentication"),
        ("clerk-nextjs", "Clerk Next.js", "Advanced Next.js patterns with middleware, Server Actions, and caching", "Authentication"),
        ("clerk-swift", "Clerk Swift", "Implement Clerk authentication for native Swift and iOS apps", "Authentication"),
        ("clerk-android", "Clerk Android", "Implement Clerk authentication for native Android with Jetpack Compose", "Authentication"),
        ("docker", "Docker", "Execute research code in isolated Docker containers for safe replication", "Infrastructure"),
        ("alpha-research", "Alpha Research", "Search, read, and query academic papers via alphaXiv-backed research", "Research"),
        ("deep-research", "Deep Research", "Run thorough, source-heavy investigations with provenance tracking", "Research"),
        ("literature-review", "Literature Review", "Run literature reviews using paper search and primary-source synthesis", "Research"),
        ("paper-code-audit", "Paper Code Audit", "Compare paper claims against public codebases for consistency", "Research"),
        ("paper-writing", "Paper Writing", "Turn research into polished paper-style drafts with citations", "Research"),
        ("preview", "Preview", "Preview Markdown, LaTeX, PDF, or code artifacts in browser or PDF", "Utilities"),
        ("macos-design-guidelines", "macOS Design", "Apple Human Interface Guidelines for Mac SwiftUI and AppKit", "Design"),
        ("frontend-design", "Frontend Design", "Create distinctive frontend interfaces with high design quality", "Design"),
        ("presentation-creator", "Presentation", "Create data-driven presentation slides with charts and animations", "Presentation"),
        ("learn-codebase", "Learn Codebase", "Discover project conventions and surface security concerns", "Development"),
        ("write-todos", "Write Todos", "Write clear, actionable todos that workers can execute", "Development"),
        ("commit", "Commit", "Generate conventional commit messages with proper formatting", "Development"),
        ("code-simplifier", "Code Simplifier", "Refine code for clarity, consistency, and maintainability", "Development"),
        ("caveman", "Caveman Mode", "Ultra-compressed communication for token efficiency", "Communication"),
        ("caveman-review", "Caveman Review", "Ultra-compressed code review comments preserving signal", "Communication"),
        ("session-log", "Session Log", "Write durable session logs with findings and next steps", "Utilities"),
        ("session-search", "Session Search", "Search past session transcripts to recover prior context", "Utilities"),
        ("modal-compute", "Modal Compute", "Run GPU workloads on Modal serverless infrastructure", "Infrastructure"),
        ("runpod-compute", "RunPod Compute", "Provision GPU pods on RunPod with SSH and large datasets", "Infrastructure"),
        ("autoresearch", "Auto Research", "Autonomous experiment loop that tries ideas and measures results", "Research"),
        ("replication", "Replication", "Plan or execute replications of papers, claims, or benchmarks", "Research"),
        ("peer-review", "Peer Review", "Simulate tough but constructive peer review of AI research", "Research"),
        ("watch", "Watch", "Set up recurring research watches on topics, papers, or products", "Research"),
        ("eli5", "ELI5", "Explain research papers in plain English with minimal jargon", "Communication"),
        ("source-comparison", "Source Comparison", "Compare papers, tools, or frameworks across multiple sources", "Research"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            skillList
            Divider()
            actions
        }
        .frame(width: 550, height: 450)
        .navigationTitle("Add Skill")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    onDismiss()
                }
            }
        }
        .sheet(isPresented: $showSkillConfig) {
            SkillConfigSheet(
                skillID: selectedSkillID,
                config: $skillConfig,
                onSave: {
                    addSkill()
                    dismiss()
                    onDismiss()
                }
            )
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search skills...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filteredSkills: [(id: String, name: String, description: String, category: String)] {
        if searchText.isEmpty {
            return availableSkills
        }
        return availableSkills.filter {
            $0.id.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedSkills: [(String, [(id: String, name: String, description: String, category: String)])] {
        let filtered = filteredSkills
        let grouped = Dictionary(grouping: filtered) { $0.category }
        return grouped.sorted { $0.key < $1.key }
    }

    private var skillList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedSkills, id: \.0) { category, skills in
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))

                    ForEach(skills, id: \.id) { skill in
                        SkillListRow(
                            skill: skill,
                            isSelected: selectedSkillID == skill.id,
                            onTap: { selectedSkillID = skill.id }
                        )
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Text(selectedSkillID.isEmpty ? "Select a skill" : "Selected: \(selectedSkillID)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.escape)

            Button("Add Skill") {
                if skillConfig.isEmpty {
                    addSkill()
                    dismiss()
                    onDismiss()
                } else {
                    showSkillConfig = true
                }
            }
            .keyboardShortcut(.return)
            .disabled(selectedSkillID.isEmpty)
        }
        .padding()
    }

    private func addSkill() {
        let skill = AgentSkill(
            identifier: selectedSkillID,
            config: skillConfig.isEmpty ? nil : skillConfig
        )
        selectedSkills.append(skill)
    }
}

// MARK: - Skill List Row

private struct SkillListRow: View {
    let skill: (id: String, name: String, description: String, category: String)
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(isSelected ? .white : .primary)

                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Skill Config Sheet

struct SkillConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skillID: String
    @Binding var config: [String: String]
    let onSave: () -> Void

    @State private var configKey = ""
    @State private var configValue = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Configure \(skillID)")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()

            Divider()

            Form {
                Section("Current Configuration") {
                    if config.isEmpty {
                        Text("No configuration yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(config.keys.sorted()), id: \.self) { key in
                            HStack {
                                Text(key)
                                    .font(.system(.caption, design: .monospaced))
                                Text("=")
                                    .foregroundStyle(.secondary)
                                Text(config[key] ?? "")
                                Spacer()
                                Button {
                                    config.removeValue(forKey: key)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("Add Configuration") {
                    HStack {
                        TextField("Key", text: $configKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("Value", text: $configValue)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            if !configKey.isEmpty {
                                config[configKey] = configValue
                                configKey = ""
                                configValue = ""
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(configKey.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Add Skill") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
            .padding()
        }
        .frame(width: 400, height: 350)
    }
}
