import SwiftUI
import UniformTypeIdentifiers

/// The install wizard for one catalog app: plain-language fields rendered
/// from the app definition, a port picker with live conflict checking, a
/// data location, and a live console of the pull + start output.
struct AppInstallSheet: View {
    let app: CatalogApp

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var answers: [String: String] = [:]
    @State private var revealedSecrets: Set<String> = []
    @State private var webPort = 0
    @State private var dataRoot = ""
    @State private var showAdvanced = false
    @State private var isInstalling = false
    @State private var didInstall = false
    @State private var console = ""
    @State private var portMessage: String?
    @State private var errorMessage: String?
    @State private var directoryTarget: String?

    private var apps: AppStoreManager { appState.apps }
    private var basicFields: [CatalogField] { app.fields.filter { !$0.advanced } }
    private var advancedFields: [CatalogField] { app.fields.filter(\.advanced) }

    private var missingRequired: [String] {
        app.fields
            .filter { $0.required }
            .filter { (answers[$0.id] ?? "").isEmpty }
            .map(\.label)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isInstalling || !console.isEmpty {
                consoleView
            } else {
                form
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 620)
        .onAppear(perform: seed)
        .task(id: webPort) { await checkPort() }
        .fileImporter(
            isPresented: Binding(
                get: { directoryTarget != nil },
                set: { if !$0 { directoryTarget = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                directoryTarget = nil
                return
            }
            if directoryTarget == "dataRoot" {
                dataRoot = url.path
            } else if let fieldID = directoryTarget {
                answers[fieldID] = url.path
            }
            directoryTarget = nil
        }
        .accessibilityLabel("Install \(app.name)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(symbolName: app.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install \(app.name)")
                    .font(.headline)
                Text(app.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .disabled(isInstalling)
        }
        .padding(16)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(app.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !basicFields.isEmpty {
                    GroupBox("Set up") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(basicFields) { field in
                                fieldRow(field)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                GroupBox("Where it lives") {
                    VStack(alignment: .leading, spacing: 14) {
                        if app.webUI != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Web address port")
                                    .font(.subheadline.weight(.medium))
                                HStack {
                                    TextField("Port", value: $webPort, format: .number.grouping(.never))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 110)
                                    if let portMessage {
                                        Label(portMessage, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text("http://127.0.0.1:\(webPort)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fontDesign(.monospaced)
                                    }
                                }
                                Text("The app's web page opens at this port. Change it if another app already uses it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("App data folder")
                                .font(.subheadline.weight(.medium))
                            HStack {
                                TextField("Data folder", text: $dataRoot)
                                    .textFieldStyle(.roundedBorder)
                                    .fontDesign(.monospaced)
                                Button("Choose…") { directoryTarget = "dataRoot" }
                                    .disabled(isInstalling)
                            }
                            Text("Your app's files and settings are saved here and survive updates.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }

                if !advancedFields.isEmpty {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(advancedFields) { field in
                                fieldRow(field)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                if let note = app.note {
                    Label {
                        Text(note)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                if !missingRequired.isEmpty {
                    Label("Please fill in: \(missingRequired.joined(separator: ", "))", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: CatalogField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(field.label)
                    .font(.subheadline.weight(.medium))
                if field.generate {
                    Button {
                        answers[field.id] = SecretGenerator.password()
                        revealedSecrets.remove(field.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Generate a new secret")
                }
            }
            valueControl(field)
            if let help = field.helpText {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func valueControl(_ field: CatalogField) -> some View {
        let binding = Binding(
            get: { answers[field.id] ?? "" },
            set: { answers[field.id] = $0 }
        )
        switch field.kind {
        case .password:
            HStack {
                if revealedSecrets.contains(field.id) {
                    TextField(field.label, text: binding)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                } else {
                    SecureField(field.label, text: binding)
                        .textFieldStyle(.roundedBorder)
                        .fontDesign(.monospaced)
                }
                Button {
                    if revealedSecrets.contains(field.id) {
                        revealedSecrets.remove(field.id)
                    } else {
                        revealedSecrets.insert(field.id)
                    }
                } label: {
                    Image(systemName: revealedSecrets.contains(field.id) ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealedSecrets.contains(field.id) ? "Hide" : "Show")
            }
        case .directory:
            HStack {
                TextField("Folder", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .fontDesign(.monospaced)
                Button("Choose…") { directoryTarget = field.id }
            }
        case .select:
            Picker(field.label, selection: binding) {
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .leading)
        case .text, .number, .port:
            TextField(field.kind == .port || field.kind == .number ? "0" : field.label, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Console

    private var consoleView: some View {
        ScrollView {
            Text(console.isEmpty ? "Working…" : console)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if didInstall {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(app.name) is installed and running.")
                    .font(.subheadline)
                Spacer()
                if app.webUI != nil {
                    Button("Open App") {
                        if let installation = apps.installation(withID: app.id) {
                            apps.openWebUI(for: installation)
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Done") { dismiss() }
            } else {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isInstalling)
                if !didInstall {
                    Button(isInstalling ? "Installing…" : "Install") {
                        Task { await install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isInstalling || !missingRequired.isEmpty || (app.webUI != nil && portMessage != nil))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func seed() {
        guard answers.isEmpty else { return }
        let dataDir = AppStoreManager.defaultDataRoot(for: app.id)
        for field in app.fields {
            var value = field.defaultValue.replacingOccurrences(of: "{{.KegDataDir}}", with: dataDir)
            if field.generate && value.isEmpty {
                value = SecretGenerator.password()
            }
            answers[field.id] = value
        }
        webPort = app.webUI?.port ?? 8080
        dataRoot = dataDir
    }

    /// Live port sanity check, debounced so typing doesn't probe per keystroke.
    private func checkPort() async {
        guard app.webUI != nil, webPort != 0 else { return }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        guard webPort > 1024, webPort <= 65535 else {
            portMessage = webPort <= 1024 ? "Ports below 1024 need administrator rights" : "Not a valid port"
            return
        }
        if apps.installations.contains(where: { $0.webPort == webPort && $0.appID != app.id }) {
            portMessage = "Another installed app already uses port \(webPort)"
            return
        }
        portMessage = PortProbe.isPortInUse(UInt16(webPort)) ? "Port \(webPort) is already in use on this Mac" : nil
    }

    private func install() async {
        isInstalling = true
        console = ""
        errorMessage = nil
        do {
            try await apps.install(
                app: app,
                answers: answers,
                webPort: webPort,
                dataRoot: dataRoot,
                progress: { line in
                    console += (console.isEmpty ? "" : "\n") + line
                }
            )
            didInstall = true
        } catch {
            errorMessage = Self.describe(error)
        }
        isInstalling = false
    }

    static func describe(_ error: Error) -> String {
        AppStoreManager.describe(error)
    }
}
