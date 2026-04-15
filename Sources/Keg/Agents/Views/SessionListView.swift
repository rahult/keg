import SwiftUI

/// Session List - View conversation history
struct SessionListView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Sessions", systemImage: "clock")
        } description: {
            Text("View past conversations with your agents")
        }
    }
}

#Preview {
    SessionListView()
}
