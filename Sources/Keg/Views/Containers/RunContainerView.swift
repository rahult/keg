import SwiftUI
import ContainerAPIClient
import ContainerResource
// Process/Pipe get captured on a background queue while a run is in flight;
// preconcurrency keeps that Sendable-checked without wrapping everything.
@preconcurrency import Foundation

struct RunContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    /// Optional prefilled image (e.g. "Run" from the Images list). If it's a
    /// known quick-start image (hello-world, nginx) the whole form is filled
    /// in — a newcomer pressing "Try a 5-second demo" should land on a sheet
    /// they can just Run, not a wall of empty fields.
    var initialImage: String? = nil

    @State private var imageName = ""
    @State private var containerName = ""
    @State private var command = ""
    @State private var envVars = ""
    @State private var ports = ""
    @State private var volumes = ""
    @State private var cpus: Int = 4
    @State private var memory = "1G"
    @State private var detached = true
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var wasCancelled = false
    /// Set when the run succeeded and the sheet stays up (to show foreground
    /// output or offer the preset URL) instead of dismissing immediately.
    @State private var succeeded = false
    /// What a foreground demo printed (the hello-world greeting).
    @State private var successOutput: String?
    /// The running process, kept so Cancel can stop a slow pull instead of
    /// leaving the sheet wedged with no way out.
    @State private var activeProcess: Process?
    @State private var preset: ContainerRunPreset?

    init(initialImage: String? = nil) {
        self.initialImage = initialImage
        let preset = initialImage.flatMap(ContainerRunPreset.matching(image:))
        _preset = State(initialValue: preset)
        _imageName = State(initialValue: initialImage ?? "")
        // Prefill eagerly, not on Run: the whole point of a quick start is
        // landing on a filled-in form instead of a wall of empty fields.
        if let preset {
            _containerName = State(initialValue: preset.name)
            _ports = State(initialValue: preset.ports)
            _command = State(initialValue: preset.command)
            _envVars = State(initialValue: preset.envVars)
            if let p = preset.cpus { _cpus = State(initialValue: p) }
            if let m = preset.memory { _memory = State(initialValue: m) }
            _detached = State(initialValue: preset.detached)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Container")
                .font(.headline)

            // Before the form, not after a failed run: a missing kernel
            // means the pull below would burn bandwidth and then die at
            // "Fetching kernel". Catch it while the user can still choose.
            BootKernelWarningBanner()

            if let preset, !isRunning, !succeeded {
                Label(preset.blurb, systemImage: "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }

            if succeeded {
                successView
            } else if isRunning {
                runningView
            } else {
                formView
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            await appState.checkBootKernel()
        }
        // No root accessibilityLabel here: it used to bleed onto the buttons,
        // making Cancel and Run indistinguishable to assistive tech.
    }

    @ViewBuilder
    private var formView: some View {
        Form {
            TextField("Image", text: $imageName, prompt: Text("nginx:latest"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Container image")
                .accessibilityHint("Docker image name and tag to run")

            TextField("Name", text: $containerName, prompt: Text("my-container"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Container name")

            TextField("Command", text: $command, prompt: Text("Optional: override entrypoint"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Command override")

            TextField("Environment Variables", text: $envVars, prompt: Text("KEY=VALUE, separated by commas"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Environment variables")

            TextField("Ports", text: $ports, prompt: Text("8080:80, 443:443"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Port mappings")

            VolumeMountField(text: $volumes)

            HStack {
                Stepper("CPUs: \(cpus)", value: $cpus, in: 1...32)
                Spacer()
                TextField("Memory", text: $memory, prompt: Text("1G"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Toggle("Run detached", isOn: $detached)
        }
        .formStyle(.grouped)

        if let errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
                .font(.caption)
                .textSelection(.enabled)
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Run") { runContainer() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
                .help(runButtonHelp)
                .buttonStyle(.borderedProminent)
        }
    }

    private var runningView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Downloading \(imageName)… first run can take a minute")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Running container: downloading \(imageName)")
            Button("Cancel", role: .destructive) {
                cancelRun()
            }
            .keyboardShortcut(.cancelAction)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(containerName.isEmpty ? imageName : containerName) ran successfully", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            if let successOutput, !successOutput.isEmpty {
                Text(successOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, maxHeight: 180, alignment: .topLeading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }

            if let urlString = preset?.successURL, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open \(urlString)", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var isBootKernelMissing: Bool {
        if case .missing = appState.bootKernelStatus { return true }
        return false
    }

    private var canRun: Bool {
        !imageName.isEmpty
            && ContainerRunArguments.volumeMountProblems(volumes).isEmpty
            && !isBootKernelMissing
    }

    private var runButtonHelp: String {
        if imageName.isEmpty { return "Enter an image name first" }
        if !ContainerRunArguments.volumeMountProblems(volumes).isEmpty { return "Fix the highlighted volume entry first" }
        if isBootKernelMissing { return "Install the boot kernel first — new containers can't start without it" }
        return "Download the image if needed and start the container"
    }

    /// Top-up when the user typed a matching image into the generic sheet —
    /// fills only what's still empty, never touches the detach toggle.
    private func applyPreset() {
        guard let preset else { return }
        if containerName.isEmpty { containerName = preset.name }
        if ports.isEmpty { ports = preset.ports }
        if command.isEmpty { command = preset.command }
        if envVars.isEmpty { envVars = preset.envVars }
        if let p = preset.cpus, cpus == 4 { cpus = p }
        if let m = preset.memory, memory == "1G" { memory = m }
    }

    /// Stops an in-flight run. SIGTERM first (lets the CLI clean up); the
    /// wedged-pull case can ignore it, so escalate to SIGKILL shortly after.
    private func cancelRun() {
        wasCancelled = true
        guard let process = activeProcess, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Translates raw CLI run failures into something actionable. The kernel
    /// case is the one users hit through no fault of their own: a runtime
    /// upgrade (container 1.4+) leaves no default registered, and the stock
    /// error says nothing about how to fix it. Raced checks can still land
    /// here — the banner may not have appeared yet.
    static func runFailureMessage(output: String, image: String) -> String {
        if output.contains("default kernel not configured") {
            return "The runtime has no boot kernel registered, so \(image) can't start. Install it with the button above (or Settings → Apple Containers → Boot Kernel), then run again."
        }
        return output.isEmpty ? "Failed to run \(image)" : output
    }

    private func runContainer() {
        // A preset typed image may have changed since init; re-resolve so the
        // success view and resource prefill match what actually runs.
        if preset == nil { preset = ContainerRunPreset.matching(image: imageName) }
        applyPreset()

        isRunning = true
        errorMessage = nil
        wasCancelled = false

        Task {
            do {
                let args = ContainerRunArguments.build(
                    name: containerName,
                    env: ContainerRunArguments.splitList(envVars),
                    ports: ContainerRunArguments.splitList(ports),
                    volumes: ContainerRunArguments.splitVolumes(volumes),
                    cpus: cpus,
                    memory: memory,
                    detached: detached,
                    image: imageName,
                    command: command
                )

                // Resolve the binary explicitly: a Finder-launched app has a
                // stripped PATH, so /usr/bin/env can't find `container`.
                let process = try ContainerCLI.makeProcess(args)
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                activeProcess = process

                // The blocking run/read/wait trio must stay off the main
                // actor — with no suspension point before the read, running
                // it inline would freeze the sheet and make Cancel useless
                // for exactly the slow-pull case it exists for.
                let (status, data) = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try process.run()
                            // Drain before waiting so a chatty pull can't
                            // fill the pipe and deadlock.
                            let data = pipe.fileHandleForReading.readDataToEndOfFile()
                            process.waitUntilExit()
                            continuation.resume(returning: (process.terminationStatus, data))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                activeProcess = nil

                let output = String(data: data, encoding: .utf8) ?? ""
                if status != 0 {
                    errorMessage = wasCancelled
                        ? "Cancelled."
                        : Self.runFailureMessage(output: output, image: imageName)
                } else if !detached {
                    // Foreground demo (hello-world): show what it printed.
                    successOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    succeeded = true
                    NotificationCenter.default.post(name: .kegRefresh, object: nil)
                } else if preset?.successURL != nil {
                    // Keep the sheet up to offer the URL; refresh the list
                    // behind it so the new container is already visible.
                    succeeded = true
                    NotificationCenter.default.post(name: .kegRefresh, object: nil)
                } else {
                    NotificationCenter.default.post(name: .kegRefresh, object: nil)
                    dismiss()
                }
            } catch {
                errorMessage = error.localizedDescription
                activeProcess = nil
            }
            isRunning = false
        }
    }
}
