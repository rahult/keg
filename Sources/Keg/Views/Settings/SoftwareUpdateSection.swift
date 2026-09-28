import SwiftUI

struct SoftwareUpdateSection: View {
    @Environment(SoftwareUpdater.self) private var updater

    private var lastCheckedDescription: String {
        guard let date = updater.lastCheckDate else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        @Bindable var updater = updater

        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsRow("Check for updates automatically") {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .labelsHidden()
            }

            if updater.automaticallyChecksForUpdates {
                Picker("Check", selection: $updater.checkFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            SettingsRow("Download and install updates automatically") {
                Toggle("", isOn: $updater.automaticallyDownloadsUpdates)
                    .labelsHidden()
                    .disabled(!updater.automaticallyChecksForUpdates)
            }

            SettingsCaption("Automatic updates are installed the next time you quit Keg, so a running container is never interrupted by one.")

            Divider()

            HStack {
                SettingsCaption(lastCheckedDescription)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .padding(.vertical, 4)
    }
}
