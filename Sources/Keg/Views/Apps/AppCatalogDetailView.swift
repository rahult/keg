import SwiftUI
import Yams

/// Route pushed from the Apps grid for a catalog app that may not be
/// installed. Distinct from AppDetailView's String-based route so both can
/// coexist as navigationDestination(item:) destinations.
struct CatalogAppRoute: Hashable {
    let id: String
}

/// Detail page for a catalog app before (or regardless of) installing: the
/// full description, links to the project, a preflight of exactly what will
/// run on the Mac — services, images, published ports, host folders — and
/// the exact compose file the install will write.
struct AppCatalogDetailView: View {
    let appID: String

    @Environment(AppState.self) private var appState
    @State private var installSheet: CatalogApp?
    @State private var showsComposeFile = false

    private var apps: AppStoreManager { appState.apps }
    private var app: CatalogApp? { apps.app(withID: appID) }
    private var installation: AppInstallation? { apps.installation(withID: appID) }

    /// The install plan, computed once from the template with default
    /// answers: what services, what ports, what host folders.
    private struct Plan {
        struct PlannedService: Identifiable {
            let name: String
            let container: String
            let image: String
            let ports: [String]
            let mounts: [String]
            var id: String { name }
        }

        let services: [PlannedService]
        let composeText: String
        let composePath: String
        let dataRoot: String
    }

    @State private var plan: Plan?

    var body: some View {
        Group {
            if let app {
                content(app)
            } else {
                EmptyState(
                    "App unavailable",
                    description: "This app is no longer in the catalog.",
                    systemImage: "shippingbox"
                )
            }
        }
        .navigationTitle(app?.name ?? appID)
        .onAppear(perform: buildPlan)
        .sheet(item: $installSheet) { sheetApp in
            AppInstallSheet(app: sheetApp)
        }
    }

    // MARK: Content

    private func content(_ app: CatalogApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(app)
                about(app)
                if let plan {
                    whatWillRun(app, plan: plan)
                    filesAndNetwork(app, plan: plan)
                    composeFileSection(plan)
                }
            }
            .padding(20)
        }
    }

    private func header(_ app: CatalogApp) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AppIcon(symbolName: app.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(app.name)
                                .font(.title3.weight(.semibold))
                            if installation != nil {
                                StatusBadge(status: "installed")
                            }
                        }
                        Text(app.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    linkButtons(app)
                }

                HStack {
                    if installation != nil {
                        Label("Installed — manage it from its app detail page.", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open App") {
                            if let installation {
                                apps.openWebUI(for: installation)
                            }
                        }
                        .disabled(apps.status(for: app.id) != .running)
                    } else {
                        Text("Everything below is what installing will set up — nothing runs until you install.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Install…") {
                            installSheet = app
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func about(_ app: CatalogApp) -> some View {
        GroupBox("About") {
            VStack(alignment: .leading, spacing: 8) {
                Text(app.summary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = app.note {
                    Label {
                        Text(note)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "lightbulb.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    /// The preflight: every service, its image, published ports, and the
    /// host folders it will use — derived from the template with default
    /// answers, so it matches what Install will actually write.
    private func whatWillRun(_ app: CatalogApp, plan: Plan) -> some View {
        GroupBox("What Will Run on This Mac") {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(plan.services.count) service\(plan.services.count == 1 ? "" : "s"), each in its own lightweight virtual machine — sealed from your Mac and from other apps' containers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(plan.services) { service in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(service.name)
                                .font(.subheadline.weight(.semibold))
                                .fontDesign(.monospaced)
                            Text(service.container)
                                .font(.caption2)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        Text(service.image)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !service.ports.isEmpty {
                            Label {
                                Text("Publishes \(service.ports.joined(separator: ", ")) on this Mac")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "bolt.horizontal")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !service.mounts.isEmpty {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(service.mounts, id: \.self) { mount in
                                        Text(mount)
                                            .font(.caption)
                                            .fontDesign(.monospaced)
                                            .textSelection(.enabled)
                                    }
                                }
                            } icon: {
                                Image(systemName: "externaldrive")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        }
    }

    private func filesAndNetwork(_ app: CatalogApp, plan: Plan) -> some View {
        GroupBox("Files & Network") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("App data")
                        .foregroundStyle(.secondary)
                    Text(plan.dataRoot)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Compose file")
                        .foregroundStyle(.secondary)
                    Text(plan.composePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let webUI = app.webUI {
                    GridRow {
                        Text("Web address")
                            .foregroundStyle(.secondary)
                        Text("http://127.0.0.1:\(webUI.port)\(webUI.path) (port is yours to change at install)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                GridRow {
                    Text("Images")
                        .foregroundStyle(.secondary)
                    Text("Pulled for linux/arm64 from their registries")
                        .font(.caption)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func composeFileSection(_ plan: Plan) -> some View {
        GroupBox("The File It Boots From") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Installing writes this exact file to \(plan.composePath) and starts its services from it. You can read or edit it later; it lives next to the app's data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup(isExpanded: $showsComposeFile) {
                    ScrollView {
                        Text(plan.composeText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 280)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                } label: {
                    Text("Show compose file")
                        .font(.caption.weight(.medium))
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Helpers

    @ViewBuilder
    private func linkButtons(_ app: CatalogApp) -> some View {
        HStack(spacing: 8) {
            if let homepage = app.homepage, let url = URL(string: homepage) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Website", systemImage: "safari")
                }
                .help(homepage)
            }
            if let source = app.source, let url = URL(string: source) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Source", systemImage: "curlybraces.square")
                }
                .help(source)
            }
        }
        .controlSize(.small)
    }

    private func buildPlan() {
        guard let app, plan == nil else { return }
        let dataRoot = AppStoreManager.defaultDataRoot(for: app.id)
        let values = (try? AppComposeRenderer.resolvedValues(
            app: app, answers: [:], dataRoot: dataRoot, webPort: app.webUI?.port ?? 8080
        )) ?? [:]
        guard let rendered = try? AppComposeRenderer.render(app: app, values: values),
              let file = try? YAMLDecoder().decode(ComposeFile.self, from: rendered) else {
            return
        }
        let project = AppStoreManager.projectName(for: app.id)
        let services = file.services.sorted(by: { $0.key < $1.key }).map { entry -> Plan.PlannedService in
            let service = entry.value
            let container = service.containerName ?? "\(project)-\(entry.key)-1"
            let ports = (service.ports ?? []).map { port in
                port.split(separator: ":").count == 2
                    ? "127.0.0.1:\(port.split(separator: ":")[0]) → container \(port.split(separator: ":")[1])"
                    : port
            }
            let mounts = (service.volumes ?? []).map { volume -> String in
                let parts = volume.split(separator: ":", maxSplits: 2).map(String.init)
                if parts.count >= 2, parts[0].hasPrefix("/") || parts[0].hasPrefix("~") {
                    let ro = parts.count == 3 && parts[2] == "ro" ? " (read-only)" : ""
                    return "\(parts[0]) → \(parts[1])\(ro)"
                }
                return volume
            }
            return Plan.PlannedService(
                name: entry.key,
                container: container,
                image: service.image ?? "—",
                ports: ports,
                mounts: mounts
            )
        }
        plan = Plan(
            services: services,
            composeText: rendered,
            composePath: AppStoreManager.composePath(for: app.id),
            dataRoot: dataRoot
        )
    }
}
