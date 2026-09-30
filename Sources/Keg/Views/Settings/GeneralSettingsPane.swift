import SwiftUI

/// Settings → General: experience level, terminal preference, launch at
/// login, and the companion-CLI installer. The pane the window opens on — no
/// status card, just calm groups.
struct GeneralSettingsPane: View {
    @Environment(AppState.self) private var appState
    @State private var loginItem = LoginItemController()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            SettingsGroup("Experience", caption: "Controls how many sections Keg shows and how much help you get.") {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsValueRow("Level", isLast: true) {
                            Picker("Level", selection: Binding(
                                get: { appState.experienceLevel },
                                set: { appState.experienceLevel = $0 }
                            )) {
                                ForEach(ExperienceLevel.allCases) { level in
                                    Label(level.rawValue, systemImage: level.iconName)
                                        .tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .help("Controls how many sections Keg shows and how much help you get")
                        }
                    }
                }

                SettingsCaption(appState.experienceLevel.detail)

                HStack {
                    SettingsCaption("Not sure? Replay the welcome quick select.")
                    Spacer()
                    Button("Show Welcome…") {
                        NotificationCenter.default.post(name: .kegShowWelcome, object: nil)
                    }
                    .controlSize(.small)
                }
            }

            SettingsGroup("Terminal", caption: "Used by Open Terminal in the Containers list and container detail view.") {
                TerminalPreferenceSection()
            }

            SettingsGroup("Login", caption: "Starts Keg (and its Docker socket) when you log in.") {
                SettingsCard {
                    VStack(spacing: 0) {
                        SettingsValueRow("Launch Keg at login", isLast: true) {
                            Toggle("Launch Keg at login", isOn: $loginItem.isEnabled)
                                .labelsHidden()
                        }
                    }
                }
            }

            SettingsGroup("Keg CLI", caption: "Terminal control of Keg — status, ps, images, logs, start/stop/rm, doctor, and `keg open` to jump back into the app.") {
                KegCLIStatusRow()
            }
        }
    }
}

/// Preferred terminal emulator for one-click container shells.
struct TerminalPreferenceSection: View {
    @State private var preferred = TerminalLauncher.preferred

    var body: some View {
        Picker("Open shells in", selection: $preferred) {
            ForEach(TerminalEmulator.allCases) { emulator in
                if emulator.isAvailable {
                    Text(emulator.rawValue).tag(emulator)
                }
            }
        }
        .pickerStyle(.radioGroup)
        .onChange(of: preferred) {
            TerminalLauncher.preferred = preferred
        }
    }
}

/// Keg's own companion CLI (`keg`): status + one-click PATH installation.
/// No privileges needed — the first writable of /usr/local/bin,
/// /opt/homebrew/bin, ~/.keg/bin wins (same rules the CLI itself uses).
struct KegCLIStatusRow: View {
    @State private var installer = KegCLIInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            statusCard

            if case .notInstalled = installer.state {
                SettingsCaption("Adds the `keg` command to your shell — status, ps, images, logs, start/stop/rm, doctor, and `keg open` to jump back into the app. No admin rights needed.")
            }

            if let hint = installer.pathHint {
                SettingsCopyLine(value: hint, accessibilityLabel: "Copy PATH line")
                SettingsCaption("Run this in your shell, then restart the terminal.")
            }

            if let error = installer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { installer.refresh() }
    }

    @ViewBuilder
    private var statusCard: some View {
        switch installer.state {
        case .installed(let link, _):
            SettingsStatusCard(.ok, title: "Installed") {
                Text(link)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } headerAction: {
                Button("Uninstall") { installer.uninstall() }
                    .controlSize(.small)
                    .disabled(installer.isWorking)
            }
        case .notInstalled:
            SettingsStatusCard(.warning, title: "Not Installed", detail: {
                Text("keg — companion CLI for terminal control of Keg")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }, headerAction: {
                Button("Install") { installer.install() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(installer.isWorking)
            })
        case .unavailable:
            SettingsStatusCard(.inactive, title: "Unavailable in this build", detail: {
                Text("The keg binary ships inside Keg.app — run a make app build")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            })
        }
    }
}
