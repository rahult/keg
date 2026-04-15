import SwiftUI

/// Source List - Manage agent data sources (MCP, REST, files)
struct SourceListView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Sources", systemImage: "square.stack.3d.up")
        } description: {
            Text("Connect MCP servers, REST APIs, and file sources")
        } actions: {
            Button("Add Source") {
                // Open source editor
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    SourceListView()
}
