import SwiftUI

/// Editable platform defaults (new-container CPU/memory, builder resources,
/// default registry) plus DNS domain listing. Values are validated by the
/// platform's own config loader on next read; Keg writes clean TOML overrides.
struct PlatformSettingsSection: View {
    @State private var vm = PlatformSettingsVM()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Default CPUs")
                        .foregroundStyle(.secondary)
                    Stepper("\(vm.settings.containerCPUs)", value: $vm.settings.containerCPUs, in: 1...32)
                }
                GridRow {
                    Text("Default Memory")
                        .foregroundStyle(.secondary)
                    TextField("1gb", text: $vm.settings.containerMemory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                GridRow {
                    Text("Builder CPUs")
                        .foregroundStyle(.secondary)
                    Stepper("\(vm.settings.buildCPUs)", value: $vm.settings.buildCPUs, in: 1...16)
                }
                GridRow {
                    Text("Builder Memory")
                        .foregroundStyle(.secondary)
                    TextField("2048mb", text: $vm.settings.buildMemory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                GridRow {
                    Text("Builder Rosetta")
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $vm.settings.buildRosetta)
                        .labelsHidden()
                }
                GridRow {
                    Text("Registry Domain")
                        .foregroundStyle(.secondary)
                    TextField("docker.io", text: $vm.settings.registryDomain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }

            if !vm.canEdit {
                Label("Config is not writable at your install location — these fields are read-only.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await vm.save() }
                } label: {
                    HStack {
                        if vm.isSaving { ProgressView().controlSize(.small) }
                        Text("Save Defaults")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canEdit || vm.isSaving || vm.isLoading)

                Button {
                    Task { await vm.load() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(vm.isLoading)
            }

            if let notice = vm.saveNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let error = vm.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Text("DNS Domains")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await vm.loadDNS() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if vm.dnsDomains.isEmpty {
                Text("No local DNS domains. Containers remain reachable by IP and published ports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.dnsDomains, id: \.self) { domain in
                    Label(domain, systemImage: "network")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            Text("Creating a DNS domain requires an administrator: run `sudo container system dns create <name>` in Terminal, then set it as the default registry/domain above.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .task {
            await vm.load()
        }
    }
}

/// Preferred terminal emulator for one-click container shells.
struct TerminalPreferenceSection: View {
    @State private var preferred = TerminalLauncher.preferred

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            Text("Used by Open Terminal in the Containers list and container detail view.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
