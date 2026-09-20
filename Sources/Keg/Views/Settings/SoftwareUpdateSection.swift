import SwiftUI

struct SoftwareUpdateSection: View {
    @Environment(SoftwareUpdater.self) private var updater

    private var lastCheckedDescription: String {
        guard let date = updater.lastCheckDate else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        @Bindable var updater = updater

        VStack(alignment: .leading, spacing: 8) {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)

            if updater.automaticallyChecksForUpdates {
                Picker("Check", selection: $updater.checkFrequency) {
                    ForEach(UpdateCheckFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)

            Text("Automatic updates are installed the next time you quit Keg, so a running container is never interrupted by one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text(lastCheckedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .padding(.vertical, 4)
    }
}
