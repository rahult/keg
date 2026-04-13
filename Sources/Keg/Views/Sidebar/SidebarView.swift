import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(selection: Binding<NavigationSection?>(
            get: { appState.selectedSection },
            set: { appState.selectedSection = $0 ?? .containers }
        )) {
            ForEach(NavigationSection.allCases) { section in
                Label(section.rawValue, systemImage: section.iconName)
                    .font(.system(size: 13))
                    .padding(.vertical, 2)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Keg")
    }
}
