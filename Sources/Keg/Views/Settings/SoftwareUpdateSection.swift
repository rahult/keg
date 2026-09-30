import SwiftUI

/// Settings → Software Update: Sparkle's automatic-check controls and a
/// manual check, in the shared value-row anatomy.
struct SoftwareUpdateSection: View {
    @Environment(SoftwareUpdater.self) private var updater

    private var lastCheckedDescription: String {
        guard let date = updater.lastCheckDate else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        @Bindable var updater = updater

        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Updates", caption: "Automatic updates are installed the next time you quit Keg, so a running container is never interrupted by one.") {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsValueRow("Check for updates automatically", description: "Looks for a new version in the background.") {
                            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                                .labelsHidden()
                        }

                        if updater.automaticallyChecksForUpdates {
                            SettingsValueRow("Check frequency", description: "How often Keg asks the update server.") {
                                Picker("Check frequency", selection: $updater.checkFrequency) {
                                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                                        Text(frequency.label).tag(frequency)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()
                            }
                        }

                        SettingsValueRow("Download and install updates automatically", description: "Installs in the background, applied on the next quit.", isLast: true) {
                            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                                .labelsHidden()
                                .disabled(!updater.automaticallyChecksForUpdates)
                        }
                    }
                }
            }

            SettingsGroup("Manual check", caption: lastCheckedDescription) {
                HStack {
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
