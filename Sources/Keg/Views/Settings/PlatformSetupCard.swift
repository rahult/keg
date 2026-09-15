import SwiftUI

/// Shown when Apple's container platform is not installed. Offers a
/// one-click install (signed pkg downloaded from GitHub, extracted into the
/// user's home — no admin password) alongside the manual Homebrew path.
struct PlatformSetupCard: View {
    @State private var installer = PlatformInstaller()
    @State private var showFailed = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Container Platform Not Installed")
                            .font(.headline)
                        Text("Keg runs on Apple's open-source container platform. Install it here — no administrator password needed — or via Homebrew.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                switch installer.phase {
                case .idle:
                    HStack(spacing: 12) {
                        Button("Install Platform…") {
                            Task { await installer.install() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Install via Homebrew…") {
                            let command = "brew install container"
                            let script = "tell application \"Terminal\" to do script \"\(command)\""
                            var error: NSDictionary?
                            NSAppleScript(source: script)?.executeAndReturnError(&error)
                        }
                        .controlSize(.small)
                    }

                case .fetchingRelease:
                    Label("Finding latest release…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)

                case .downloading(let received, let expected):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: expected > 0 ? Double(received) / Double(expected) : nil)
                        Text(expected > 0
                             ? "Downloading \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))"
                             : "Downloading installer…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .expanding:
                    Label("Expanding installer…", systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                case .installing:
                    Label("Installing into ~/.keg/platform…", systemImage: "shippingbox")
                        .foregroundStyle(.secondary)

                case .done(let version):
                    Label("Platform \(version) installed. Starting up…", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .task {
                            // Let the user see the confirmation, then bring
                            // the system up and refresh this card away.
                            try? await Task.sleep(for: .seconds(2))
                            NotificationCenter.default.post(name: .kegPlatformInstalled, object: nil)
                        }

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Install failed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await installer.install() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(4)
        }
        .accessibilityElement(children: .contain)
    }
}

extension Notification.Name {
    static let kegPlatformInstalled = Notification.Name("keg.platformInstalled")
}
