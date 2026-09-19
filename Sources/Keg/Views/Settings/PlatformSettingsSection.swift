import AppKit
import SwiftUI

/// Editable platform defaults (new-container CPU/memory, machine resources,
/// builder settings, default registry, home-mount policy) plus DNS domain
/// listing. Values are validated by the platform's own config loader on next
/// read; Keg writes clean TOML overrides.
struct PlatformSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var vm = PlatformSettingsVM()
    @State private var showAdvanced = false

    /// Where persistent data lives — the volume location for containers,
    /// named volumes, and images — derived from the configured data root.
    private var storageLocations: some View {
        let root = appState.effectiveDataRootPath
        return VStack(alignment: .leading, spacing: 5) {
            Text("Storage Locations")
                .font(.headline)
            storageRow("Containers", "\(root)/containers")
            storageRow("Volumes", "\(root)/volumes")
            storageRow("Images", "\(root)/content")
            Text("Everything persistent lives under the data root set in Container System → Data Location. Moving it means stopping the system, copying the folder, and updating that field.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func storageRow(_ label: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
    }

    /// Kernel and vminit pin the platform's boot stack. Keg shows them for
    /// awareness but never writes them — a bad value here prevents every
    /// container from starting.
    private var advancedSection: some View {
        DisclosureGroup("Advanced (read-only)", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 5) {
                advancedRow("Kernel", vm.settings.kernelBinaryPath)
                advancedRow("Kernel URL", vm.settings.kernelURL)
                advancedRow("vminit Image", vm.settings.vminitImage)
                Text("Pinned by the container platform and updated with it. Edit the config TOML by hand only if you know why.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    private func advancedRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            storageLocations

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {                GridRow {
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
                    Text("Builder Image")
                        .foregroundStyle(.secondary)
                    TextField("ghcr.io/apple/…/builder:tag", text: $vm.settings.buildImage)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                }
                GridRow {
                    Text("Machine CPUs")
                        .foregroundStyle(.secondary)
                    Stepper("\(vm.settings.machineCPUs)", value: $vm.settings.machineCPUs, in: 1...64)
                }
                GridRow {
                    Text("Machine Memory")
                        .foregroundStyle(.secondary)
                    TextField("8gb", text: $vm.settings.machineMemory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                GridRow {
                    Text("Home Mount")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $vm.settings.machineHomeMount) {
                        Text("Read-only").tag("ro")
                        Text("Read-write").tag("rw")
                        Text("None").tag("none")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .help("Whether containers see your Mac home folder, and how")
                }
                GridRow {
                    Text("Machine Virtualization")
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $vm.settings.machineVirtualization)
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
            .disabled(vm.isLoading)

            advancedSection

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
