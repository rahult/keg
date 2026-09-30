import SwiftUI

/// Settings → About: identity, version (copyable), and links.
struct AboutSettingsPane: View {
    private let websiteURL = URL(string: "https://keg.rahultrikha.com")!
    private let repositoryURL = URL(string: "https://github.com/rahult/keg")!
    private let releasesURL = URL(string: "https://github.com/rahult/keg/releases")!

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Keg", caption: "Docker Desktop replacement for macOS — native containers, Docker API, Compose, and Kubernetes.") {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsValueRow("Version") {
                            SettingsCopyLine(value: AppVersion.displayString, accessibilityLabel: "Copy version")
                        }
                        SettingsValueRow("Website") {
                            Link("keg.rahultrikha.com", destination: websiteURL)
                        }
                        SettingsValueRow("Repository") {
                            Link("github.com/rahult/keg", destination: repositoryURL)
                        }
                        SettingsValueRow("Releases") {
                            Link("github.com/rahult/keg/releases", destination: releasesURL)
                        }
                        SettingsValueRow("Runtime") {
                            Text("Apple Containerization")
                                .foregroundStyle(.secondary)
                        }
                        SettingsValueRow("Requirements") {
                            Text("macOS 26+, Apple Silicon, Apple container CLI")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        SettingsValueRow("License", isLast: true) {
                            Text("Apache 2.0")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
