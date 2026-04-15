import SwiftUI

// MARK: - Tool Picker Sheet

struct ToolPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTools: [AgentTool]
    let onDismiss: () -> Void

    @State private var selectedToolset = true
    @State private var customToolName = ""
    @State private var customToolDescription = ""
    @State private var permissionPolicy: PermissionPolicy = PermissionPolicy(type: "always_allow")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolTypeSelector
            Divider()
            toolConfig
            Divider()
            actions
        }
        .frame(width: 500, height: 400)
        .navigationTitle("Add Tool")
        .accessibilityLabel("Add tool sheet")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    onDismiss()
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configure a tool for your agent")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolTypeSelector: some View {
        Picker("Tool Type", selection: $selectedToolset) {
            Text("Toolset (Built-in)").tag(true)
            Text("Custom").tag(false)
        }
        .pickerStyle(.segmented)
        .padding()
    }

    @ViewBuilder
    private var toolConfig: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selectedToolset {
                    toolsetConfig
                } else {
                    customToolConfig
                }
            }
            .padding()
        }
    }

    private var toolsetConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toolset Configuration")
                .font(.headline)

            Text("Use built-in tools with configurable permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Permission Policy")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Policy", selection: $permissionPolicy.type) {
                    Text("Always Allow").tag("always_allow")
                    Text("Always Deny").tag("always_deny")
                    Text("Ask").tag("ask")
                }
                .pickerStyle(.menu)
            }

            Text("Toolset tools include: Read, Write, Bash, Web Search, Code Execution, and more.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
    }

    private var customToolConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Tool Configuration")
                .font(.headline)

            Text("Define a custom tool with a name, description, and input schema.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                HStack {
                    Text("Name")
                        .frame(width: 80, alignment: .trailing)
                    TextField("tool_name", text: $customToolName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(alignment: .top) {
                    Text("Description")
                        .frame(width: 80, alignment: .trailing)
                    TextField("What does this tool do?", text: $customToolDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }

            Text("Example: A custom tool could call an external API, query a database, or integrate with your infrastructure.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.escape)
            .accessibilityLabel("Cancel and close")

            Button("Add Tool") {
                addTool()
                dismiss()
                onDismiss()
            }
            .keyboardShortcut(.return)
            .disabled(!canAddTool)
            .accessibilityLabel("Add tool to agent")
        }
        .padding()
    }

    private var canAddTool: Bool {
        if selectedToolset {
            return true
        }
        return !customToolName.isEmpty
    }

    private func addTool() {
        if selectedToolset {
            let tool = AgentTool.agentToolset(
                ToolsetConfig(
                    defaultConfig: ToolsetDefaultConfig(permissionPolicy: permissionPolicy)
                )
            )
            selectedTools.append(tool)
        } else {
            let tool = AgentTool.custom(
                CustomTool(
                    name: customToolName,
                    description: customToolDescription.isEmpty ? nil : customToolDescription
                )
            )
            selectedTools.append(tool)
        }
    }
}
