import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(NavigationSection.allCases, selection: Binding(
            get: { appState.selectedSection },
            set: { appState.selectedSection = $0 ?? .containers }
        )) { section in
            Label(section.rawValue, systemImage: section.iconName)
                .font(.system(size: 13))
                .padding(.vertical, 2)
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
    }
}
