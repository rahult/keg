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
        SettingsGroup("Storage Locations", caption: "Everything persistent lives under the data root set in Container System → Data Location. Moving it means stopping the system, copying the folder, and updating that field.") {
            SettingsCard {
                VStack(spacing: 0) {
                    pathRow("Containers", description: "Container root filesystems and metadata.", "\(rootPath)/containers", isLast: false)
                    pathRow("Volumes", description: "Named volumes.", "\(rootPath)/volumes", isLast: false)
                    pathRow("Images", description: "Image content store.", "\(rootPath)/content", isLast: true)
                }
            }
        }
    }

    private var rootPath: String { appState.effectiveDataRootPath }

    /// A storage path needs middle-truncation, so the row carries the path in
    /// its trailing control (monospaced value + borderless copy).
    private func pathRow(_ label: String, description: String, _ path: String, isLast: Bool) -> some View {
        SettingsValueRow(label, description: description, isLast: isLast) {
            HStack(spacing: 4) {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: 200)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Copy \(label) path")
            }
        }
    }

    /// Kernel and vminit pin the platform's boot stack. Keg shows them for
    /// awareness but never writes them — a bad value here prevents every
    /// container from starting.
    private var advancedSection: some View {
        DisclosureGroup("Advanced (read-only)", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                SettingsValueRow("Kernel", isLast: false) { advancedValue(vm.settings.kernelBinaryPath) }
                SettingsValueRow("Kernel URL", isLast: false) { advancedValue(vm.settings.kernelURL) }
                SettingsValueRow("vminit Image", isLast: false) { advancedValue(vm.settings.vminitImage) }
                SettingsCaption("Pinned by the container platform and updated with it. Edit the config TOML by hand only if you know why.")
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    private func advancedValue(_ value: String) -> some View {
        Text(value.isEmpty ? "—" : value)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: 240)
    }

    /// CPUs: slider bounded by the host's core count, with an editable text
    /// that is clamped to the same range (typing 100 must not reach the TOML).
    private func cpuRow(_ label: String, description: String, value: Binding<Int>, isLast: Bool = false) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, 1), PlatformSettingsVM.hostCoreCount) }
        )
        return SettingsValueRow(label, description: description, isLast: isLast) {
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { Double(clamped.wrappedValue) },
                    set: { clamped.wrappedValue = Int($0.rounded()) }
                ), in: 1...Double(PlatformSettingsVM.hostCoreCount), step: 1)
                .frame(width: 120)
                TextField("", value: clamped, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 52)
                SettingsCaption("cores")
                    .frame(width: 42, alignment: .leading)
            }
        }
    }

    /// Memory in GB (half-gig steps), backed by megabytes in the config.
    /// Text entry is clamped to the slider range as well.
    private func memoryRow(_ label: String, description: String, mb: Binding<Int>, isLast: Bool = false) -> some View {
        let limits = 512...PlatformSettingsVM.hostMemoryGB * 1024
        let gb = Binding(
            get: { Double(mb.wrappedValue) / 1024.0 },
            set: { mb.wrappedValue = min(max(Int((($0 * 2).rounded() / 2) * 1024), limits.lowerBound), limits.upperBound) }
        )
        return SettingsValueRow(label, description: description, isLast: false) {
            HStack(spacing: 10) {
                Slider(value: gb, in: 0.5...Double(PlatformSettingsVM.hostMemoryGB), step: 0.5)
                    .frame(width: 120)
                TextField("", value: gb, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 64)
                SettingsCaption("GB")
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
            storageLocations

            VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                SettingsGroup("Containers", caption: "Resources for newly created containers.") {
                    SettingsCard {
                        VStack(spacing: 0) {
                            cpuRow("CPUs", description: "Default CPUs for new containers.", value: $vm.settings.containerCPUs)
                            memoryRow("Memory", description: "Default memory for new containers.", mb: $vm.settings.containerMemoryMB, isLast: true)
                        }
                    }
                }

                SettingsGroup("Builds", caption: "Resources for `container build`.") {
                    SettingsCard {
                        VStack(spacing: 0) {
                            cpuRow("CPUs", description: "CPUs for image builds.", value: $vm.settings.buildCPUs)
                            memoryRow("Memory", description: "Memory for image builds.", mb: $vm.settings.buildMemoryMB)
                            SettingsValueRow("Rosetta", description: "Use Rosetta for x86-64 builds.") {
                                Toggle("Rosetta", isOn: $vm.settings.buildRosetta)
                                    .labelsHidden()
                            }
                            SettingsValueRow("Builder Image", description: "The builder image `container build` uses.", isLast: true) {
                                TextField("", text: $vm.settings.buildImage, prompt: Text("ghcr.io/apple/…/builder:tag"))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                            }
                        }
                    }
                }

                SettingsGroup("Machines", caption: "Defaults for full Linux machines.") {
                    SettingsCard {
                        VStack(spacing: 0) {
                            cpuRow("CPUs", description: "Default CPUs for full machines.", value: $vm.settings.machineCPUs)
                            memoryRow("Memory", description: "Default memory for full machines.", mb: $vm.settings.machineMemoryMB)
                            SettingsValueRow("Home Mount", description: "Whether containers see your Mac home folder, and how.") {
                                Picker("Home Mount", selection: $vm.settings.machineHomeMount) {
                                    Text("Read-only").tag("ro")
                                    Text("Read-write").tag("rw")
                                    Text("None").tag("none")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .help("Whether containers see your Mac home folder, and how")
                            }
                            SettingsValueRow("Virtualization", description: "Virtualization support for full Linux machines.", isLast: true) {
                                Toggle("Virtualization", isOn: $vm.settings.machineVirtualization)
                                    .labelsHidden()
                            }
                        }
                    }
                }

                SettingsGroup("Registry", caption: "Where images are pulled from; docker.io covers Docker Hub.") {
                    SettingsCard {
                        SettingsValueRow("Domain", description: "Default registry for image pulls.", isLast: true) {
                            TextField("", text: $vm.settings.registryDomain, prompt: Text("docker.io"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                    }
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

                SettingsCaption("Changes save automatically and apply to new containers, builds, and machines.")
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

            dnsSection
        }
        .padding(.vertical, 4)
        .task {
            await vm.load()
        }
    }

    private var dnsSection: some View {
        SettingsGroup("DNS Domains", caption: "Local domains the runtime resolves between containers. Creating a domain needs an administrator: `sudo container system dns create <name>`.") {
            SettingsValueRow("Domains", description: "Re-check after creating one with the CLI.", isLast: true) {
                Button {
                    Task { await vm.loadDNS() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if vm.dnsDomains.isEmpty {
                SettingsCaption("No local DNS domains. Containers remain reachable by IP and published ports.")
            } else {
                ForEach(vm.dnsDomains, id: \.self) { domain in
                    Label(domain, systemImage: "network")
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }
}
