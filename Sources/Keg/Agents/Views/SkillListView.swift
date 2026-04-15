import SwiftUI

/// Skill List - Manage reusable agent skills
struct SkillListView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Skills", systemImage: "book")
        } description: {
            Text("Create reusable instructions for your agents")
        } actions: {
            Button("Create Skill") {
                // Open skill editor
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    SkillListView()
}
