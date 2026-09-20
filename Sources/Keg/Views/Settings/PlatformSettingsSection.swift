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

    /// A labelled group of related rows: the fastest way to tell the three
    /// CPU/memory triples apart.
    private func group(_ name: String, caption: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            content()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    /// One settings row: fixed-width label column so every control starts at
    /// the same x. A plain HStack — Grid centers cells in their columns and
    /// stretches Steppers, which scattered the controls across the row.
    private func settingRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
            // Fixed control column: every control starts at the same x even
            // though the fields themselves have different natural widths.
            HStack(spacing: 0) {
                control()
                Spacer(minLength: 0)
            }
            .frame(width: 330, alignment: .leading)
            Spacer(minLength: 0)
        }
        // Full-width leading frame: the Settings form centers fixed-width
        // rows, which offsets controls differently on every row.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// CPUs: slider bounded by the host's core count, with an editable text
    /// that is clamped to the same range (typing 100 must not reach the TOML).
    private func cpuRow(_ label: String, value: Binding<Int>) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, 1), PlatformSettingsVM.hostCoreCount) }
        )
        return settingRow(label) {
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { Double(clamped.wrappedValue) },
                    set: { clamped.wrappedValue = Int($0.rounded()) }
                ), in: 1...Double(PlatformSettingsVM.hostCoreCount), step: 1)
                .frame(width: 140)
                TextField("", value: clamped, format: .number)
                    .textFieldStyle(.squareBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 52)
                Text("cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
        }
    }

    /// Memory in GB (half-gig steps), backed by megabytes in the config.
    /// Text entry is clamped to the slider range as well.
    private func memoryRow(_ label: String, mb: Binding<Int>) -> some View {
        let limits = 512...PlatformSettingsVM.hostMemoryGB * 1024
        let gb = Binding(
            get: { Double(mb.wrappedValue) / 1024.0 },
            set: { mb.wrappedValue = min(max(Int((($0 * 2).rounded() / 2) * 1024), limits.lowerBound), limits.upperBound) }
        )
        return settingRow(label) {
            HStack(spacing: 10) {
                Slider(value: gb, in: 0.5...Double(PlatformSettingsVM.hostMemoryGB), step: 0.5)
                    .frame(width: 140)
                TextField("", value: gb, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.squareBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64)
                Text("GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            storageLocations

            VStack(alignment: .leading, spacing: 14) {
                group("Containers", caption: "Resources for newly created containers.") {
                    cpuRow("CPUs", value: $vm.settings.containerCPUs)
                    memoryRow("Memory", mb: $vm.settings.containerMemoryMB)
                }

                group("Builds", caption: "Resources for `container build`.") {
                    cpuRow("CPUs", value: $vm.settings.buildCPUs)
                    memoryRow("Memory", mb: $vm.settings.buildMemoryMB)
                    settingRow("Rosetta") {
                        Toggle("", isOn: $vm.settings.buildRosetta)
                            .labelsHidden()
                    }
                    settingRow("Builder Image") {
                        TextField("", text: $vm.settings.buildImage, prompt: Text("ghcr.io/apple/…/builder:tag"))
                            .textFieldStyle(.squareBorder)
                            .frame(width: 320)
                    }
                }

                group("Machines", caption: "Defaults for full Linux machines.") {
                    cpuRow("CPUs", value: $vm.settings.machineCPUs)
                    memoryRow("Memory", mb: $vm.settings.machineMemoryMB)
                    settingRow("Home Mount") {
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
                    settingRow("Virtualization") {
                        Toggle("", isOn: $vm.settings.machineVirtualization)
                            .labelsHidden()
                    }
                }

                group("Registry") {
                    settingRow("Domain") {
                        TextField("", text: $vm.settings.registryDomain, prompt: Text("docker.io"))
                            .textFieldStyle(.squareBorder)
                            .frame(width: 220)
                    }
                    Text("Where images are pulled from; docker.io covers Docker Hub.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(vm.isLoading || !vm.canEdit)
            .onChange(of: vm.settings) { _, _ in
                vm.scheduleSave()
            }

            advancedSection

            if !vm.canEdit {
                Label("Config is not writable at your install location — these fields are read-only.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await vm.load() }
                } label: {
                    Label("Revert", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(vm.isLoading)

                Text("Changes save automatically and apply to new containers, builds, and machines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("Creating a domain needs an administrator: `sudo container system dns create <name>`.")
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
