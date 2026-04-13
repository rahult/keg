import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Container System") {
                HStack {
                    switch appState.systemStatus {
                    case .running(let health):
                        Circle().fill(Color.green).frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Running")
                                .font(.headline)
                            Text("Version: \(health.apiServerVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Build: \(health.apiServerBuild)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop System") {
                            Task { await appState.stopSystem() }
                        }
                        .controlSize(.small)

                    case .stopped:
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text("Stopped")
                            .font(.headline)
                        Spacer()
                        Button("Start System") {
                            Task { await appState.startSystem() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                    case .error(let message):
                        Circle().fill(Color.orange).frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text("Error")
                                .font(.headline)
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retry") {
                            Task { await appState.startSystem() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("About") {
                LabeledContent("App", value: "Keg")
                LabeledContent("Description", value: "Native macOS container manager using Apple's container framework")
                LabeledContent("Requirements", value: "macOS 26+, Apple Silicon, Apple container CLI")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Settings")
        .task {
            await appState.checkSystemStatus()
        }
    }
}
