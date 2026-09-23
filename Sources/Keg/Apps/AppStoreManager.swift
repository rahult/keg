import AppKit
import ContainerAPIClient
import Foundation
import Yams

// MARK: - Installation Record

/// One installed app: what the user answered in the wizard, where its data
/// lives, and how to reach its compose file. Secrets live in this record
/// (plain JSON under ~/.keg/apps) because the compose file next to it
/// contains the same values anyway; the whole directory is user-owned data.
struct AppInstallation: Codable, Identifiable, Hashable, Sendable {
    let appID: String
    let name: String
    let fieldValues: [String: String]
    /// Host port the app's web UI is published on, when the app has one.
    let webPort: Int?
    let dataRoot: String
    let composePath: String
    let installedAt: Date
    /// Re-created automatically when Keg opens (after the runtime is up).
    /// Stopping an app by hand clears this; installing or starting sets it.
    var autoStart: Bool
    /// Checksum of the catalog definition at install time (or the last
    /// Update that adopted a new template). When it differs from the
    /// current catalog entry's checksum, the template changed and Update
    /// will apply it.
    var definitionSHA: String?

    var id: String { appID }
}

// MARK: - Manager

/// Drives the Apps section: the curated catalog, install/update/uninstall
/// lifecycle (rendered compose + ComposeOrchestrator underneath), status
/// refresh, and start-at-Keg-launch for installed apps. All container work
/// goes through the same orchestrator the Compose section uses, so anything
/// installed here also shows up in Containers and answers the Docker API.
@Observable
@MainActor
final class AppStoreManager {
    enum AppsError: Error, CustomStringConvertible {
        case alreadyInstalled(String)
        case busy(String)
        case portInUse(Int)
        case privilegedPort(Int)
        case composeFileMissing(String)

        var description: String {
            switch self {
            case .alreadyInstalled(let id): return "\(id) is already installed."
            case .busy(let what): return "\(what) is still finishing — wait for it to complete."
            case .portInUse(let port): return "Port \(port) is already in use on this Mac. Pick another port."
            case .privilegedPort(let port): return "Port \(port) needs administrator rights. Pick a port above 1024."
            case .composeFileMissing(let path): return "The app's compose file is missing: \(path)"
            }
        }
    }

    struct ServiceState: Identifiable, Hashable, Sendable {
        let service: String
        let container: String
        let state: String
        var id: String { service }
    }

    enum AppStatus: Hashable, Sendable {
        case running
        case partial
        case stopped
        case working(String)
        case unknown

        var label: String {
            switch self {
            case .running: return "Running"
            case .partial: return "Partial"
            case .stopped: return "Stopped"
            case .working(let what): return what
            case .unknown: return "Unknown"
            }
        }
    }

    /// Where the catalog currently stands relative to the remote registry.
    enum RemoteCatalogState: Equatable {
        case idle
        case syncing
        case synced(Date, Int)
        case failed(String)

        var isSyncing: Bool {
            if case .syncing = self { return true }
            return false
        }
    }

    typealias Progress = @MainActor (String) -> Void

    private(set) var catalog: [CatalogApp] = []
    /// Non-fatal catalog problems (bad user-added YAML) surfaced in the UI.
    private(set) var catalogWarnings: [String] = []
    /// appID → the winning catalog YAML for that id, for definition
    /// checksums (install/update adoption).
    private(set) var catalogSources: [String: String] = [:]
    private(set) var remoteCatalogState: RemoteCatalogState = .idle
    private(set) var installations: [AppInstallation] = []
    private(set) var serviceStates: [String: [ServiceState]] = [:]
    /// appID → label of the lifecycle operation currently in flight.
    private(set) var activeOperations: [String: String] = [:]
    var isRefreshingStatuses = false

    private let orchestrator = ComposeOrchestrator()
    private let containerClient = ContainerClient()
    private var didLoad = false
    private var isSyncingCatalog = false

    // Injectable roots/session so catalog merge and registry sync can be
    // exercised against temp directories in tests.
    var catalogUserDirectoryOverride: String?
    var catalogRemoteCacheOverride: URL?
    var catalogRemoteBaseOverride: URL?
    var catalogSession: URLSession = RemoteCatalog.makeSession()

    private var userCatalogDirectoryURL: String {
        catalogUserDirectoryOverride ?? Self.userCatalogDirectory
    }
    private var remoteCacheDirectoryURL: URL {
        catalogRemoteCacheOverride ?? RemoteCatalog.cacheDirectory
    }

    // MARK: Paths
    // Pure path/namespace builders — usable from any isolation.

    nonisolated static var appsDirectory: String {
        NSString(string: "~/.keg/apps").expandingTildeInPath
    }
    nonisolated static var registryPath: String {
        appsDirectory + "/registry.json"
    }
    nonisolated static var userCatalogDirectory: String {
        appsDirectory + "/catalog"
    }
    nonisolated static func defaultDataRoot(for appID: String) -> String {
        appsDirectory + "/\(appID)"
    }
    nonisolated static func composePath(for appID: String) -> String {
        appsDirectory + "/\(appID)/app.yaml"
    }
    /// Compose project namespace for an installed app. Everything the
    /// orchestrator creates for this app carries it (network names) or an
    /// explicit kegapp- container name from the template.
    nonisolated static func projectName(for appID: String) -> String {
        "apps-\(appID)"
    }

    nonisolated private static let lastSyncDefaultsKey = "apps.catalog.lastSync"

    // MARK: Loading

    /// Cheap at construction; real work happens on first prepare() so app
    /// launch never waits on catalog parsing.
    init() {}

    func prepare() {
        guard !didLoad else { return }
        didLoad = true
        loadCatalog()
        loadInstallations()
    }

    func reloadCatalog() {
        loadCatalog()
    }

    /// Rebuilds the catalog from three tiers, later tiers overriding earlier
    /// ones by id: bundled definitions (offline fallback) → the synced
    /// remote registry → user-added local YAMLs in ~/.keg/apps/catalog.
    /// A tier can retire an app with `hidden: true`; a later tier can
    /// un-retire it by re-declaring it with `hidden: false`.
    func loadCatalog() {
        var warnings: [String] = []
        var merged: [String: (app: CatalogApp, source: String)] = [:]

        for yaml in BundledAppCatalog.yamlContents {
            do {
                for app in try AppCatalog.load(yamlContents: [yaml]) {
                    merged[app.id] = (app, yaml)
                }
            } catch {
                warnings.append("Bundled app catalog problem: \(error)")
            }
        }

        for (entry, yaml) in RemoteCatalog.cachedFiles(cacheDir: remoteCacheDirectoryURL) {
            do {
                for app in try AppCatalog.load(yamlContents: [yaml]) {
                    merged[app.id] = (app, yaml)
                }
            } catch {
                warnings.append("Registry \(entry.file): \(error)")
            }
        }

        let userURL = URL(filePath: userCatalogDirectoryURL)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: userURL, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "yaml" || file.pathExtension == "yml" {
                guard let yaml = try? String(contentsOf: file, encoding: .utf8) else {
                    warnings.append("Could not read \(file.lastPathComponent)")
                    continue
                }
                do {
                    for app in try AppCatalog.load(yamlContents: [yaml]) {
                        merged[app.id] = (app, yaml)
                    }
                } catch {
                    warnings.append("\(file.lastPathComponent): \(error)")
                }
            }
        }

        catalog = merged.values.map(\.app)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        catalogSources = merged.mapValues(\.source)
        catalogWarnings = warnings
        restoreRemoteCatalogState()
    }

    private func restoreRemoteCatalogState() {
        if let last = UserDefaults.standard.object(forKey: Self.lastSyncDefaultsKey) as? Date {
            remoteCatalogState = .synced(last, RemoteCatalog.cachedFiles(cacheDir: remoteCacheDirectoryURL).count)
        } else {
            remoteCatalogState = .idle
        }
    }

    private func loadInstallations() {
        let url = URL(filePath: Self.registryPath)
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([AppInstallation].self, from: data) {
            installations = decoded
        }
    }

    private func saveInstallations() {
        let url = URL(filePath: Self.registryPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(installations) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Lookups

    func app(withID id: String) -> CatalogApp? {
        prepare()
        return catalog.first { $0.id == id }
    }

    func installation(withID id: String) -> AppInstallation? {
        installations.first { $0.appID == id }
    }

    var installedAppIDs: Set<String> {
        Set(installations.map(\.appID))
    }

    var runningAppCount: Int {
        installations.filter { status(for: $0.appID) == .running }.count
    }

    func status(for appID: String) -> AppStatus {
        if let operation = activeOperations[appID] {
            return .working(operation)
        }
        let states = serviceStates[appID] ?? []
        if states.isEmpty { return .unknown }
        if states.allSatisfy({ $0.state == "running" }) { return .running }
        if states.contains(where: { $0.state == "running" }) { return .partial }
        return .stopped
    }

    // MARK: Status refresh

    /// One `container list` for every installed app, matched against the
    /// expected container names from each compose file (same naming rules
    /// the orchestrator uses: explicit container_name, else
    /// <project>-<service>-1).
    func refreshStatuses() async {
        guard !isRefreshingStatuses else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }
        let rows = await containerRows()
        for installation in installations where activeOperations[installation.appID] == nil {
            // Empty rows means the listing itself failed (runtime down) —
            // "unknown", not a misleading "stopped".
            serviceStates[installation.appID] = rows.isEmpty ? [] : states(for: installation, rows: rows)
        }
    }

    private func currentState(for installation: AppInstallation) async -> [ServiceState] {
        states(for: installation, rows: await containerRows())
    }

    private func containerRows() async -> [(id: String, isRunning: Bool)] {
        do {
            let containers = try await Bounded.withTimeout(.seconds(20)) {
                try await self.containerClient.list(filters: .all)
            }
            return containers.map { (id: $0.id, isRunning: $0.status == .running) }
        } catch {
            // Runtime unreachable: callers render "unknown" instead of a
            // misleading "stopped".
            return []
        }
    }

    private func states(
        for installation: AppInstallation,
        rows: [(id: String, isRunning: Bool)]
    ) -> [ServiceState] {
        guard let compose = try? String(contentsOfFile: installation.composePath, encoding: .utf8),
              let file = try? YAMLDecoder().decode(ComposeFile.self, from: compose) else {
            return []
        }
        let project = Self.projectName(for: installation.appID)
        return file.services.sorted(by: { $0.key < $1.key }).map { entry in
            let expected = entry.value.containerName ?? "\(project)-\(entry.key)-1"
            let row = rows.first { $0.id == expected || $0.id.contains(expected) }
            return ServiceState(
                service: entry.key,
                container: row?.id ?? expected,
                state: row.map { $0.isRunning ? "running" : "stopped" } ?? "not created"
            )
        }
    }

    // MARK: Lifecycle

    func install(
        app: CatalogApp,
        answers: [String: String],
        webPort: Int,
        dataRoot: String,
        progress: Progress? = nil
    ) async throws {
        prepare()
        if installation(withID: app.id) != nil {
            throw AppsError.alreadyInstalled(app.id)
        }
        if app.webUI != nil {
            try validatePort(webPort)
        }

        let absoluteDataRoot = NSString(string: dataRoot).expandingTildeInPath
        let values = try AppComposeRenderer.resolvedValues(
            app: app, answers: answers, dataRoot: absoluteDataRoot, webPort: webPort
        )
        try AppComposeRenderer.validateRequired(app: app, values: values)
        try AppComposeRenderer.validateEmbeddable(app: app, values: values)
        let rendered = try AppComposeRenderer.render(app: app, values: values)

        let composePath = Self.composePath(for: app.id)
        try FileManager.default.createDirectory(
            at: URL(filePath: composePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: URL(filePath: absoluteDataRoot), withIntermediateDirectories: true
        )
        try rendered.write(toFile: composePath, atomically: true, encoding: .utf8)

        do {
            try await pullImages(in: rendered, progress: progress)
            progress?("Starting services…")
            try await orchestrator.up(
                filePath: composePath,
                projectName: Self.projectName(for: app.id),
                detached: true,
                progress: progress
            )
        } catch {
            // A half-started install must not linger as mystery containers.
            try? await orchestrator.down(
                filePath: composePath,
                projectName: Self.projectName(for: app.id),
                progress: nil
            )
            throw error
        }

        let record = AppInstallation(
            appID: app.id,
            name: app.name,
            fieldValues: answers,
            webPort: app.webUI == nil ? nil : webPort,
            dataRoot: absoluteDataRoot,
            composePath: composePath,
            installedAt: Date(),
            autoStart: true,
            definitionSHA: definitionSHA(for: app.id)
        )
        installations.append(record)
        saveInstallations()
        serviceStates[app.id] = await currentState(for: record)
    }

    /// Starts (or recreates) every service of an installed app.
    func start(_ installation: AppInstallation, progress: Progress? = nil) async throws {
        try beginOperation(installation.appID, label: "Starting…")
        defer { endOperation(installation.appID) }
        guard FileManager.default.fileExists(atPath: installation.composePath) else {
            throw AppsError.composeFileMissing(installation.composePath)
        }
        let compose = try String(contentsOfFile: installation.composePath, encoding: .utf8)
        try await pullImages(in: compose, progress: progress)
        try await orchestrator.up(
            filePath: installation.composePath,
            projectName: Self.projectName(for: installation.appID),
            detached: true,
            progress: progress
        )
        setAutoStart(installation, enabled: true)
        serviceStates[installation.appID] = await currentState(for: installation)
    }

    /// Stops the app: containers removed, networks cleaned up, data kept
    /// (bind mounts under the data root are untouched). Stopping by hand
    /// also opts the app out of auto-start — "unless stopped" semantics.
    func stop(_ installation: AppInstallation, progress: Progress? = nil) async throws {
        try beginOperation(installation.appID, label: "Stopping…")
        defer { endOperation(installation.appID) }
        guard FileManager.default.fileExists(atPath: installation.composePath) else {
            throw AppsError.composeFileMissing(installation.composePath)
        }
        try await orchestrator.down(
            filePath: installation.composePath,
            projectName: Self.projectName(for: installation.appID),
            progress: progress
        )
        setAutoStart(installation, enabled: false)
        serviceStates[installation.appID] = await currentState(for: installation)
    }

    /// Update: re-pull images, recreate containers, and — when the catalog
    /// definition changed since install (registry refresh) — re-render the
    /// app from the new template, reusing the stored wizard answers (new
    /// fields fall back to their defaults). Data volumes are bind mounts,
    /// so app data survives all of it.
    func update(_ installation: AppInstallation, progress: Progress? = nil) async throws {
        try beginOperation(installation.appID, label: "Updating…")
        defer { endOperation(installation.appID) }
        guard FileManager.default.fileExists(atPath: installation.composePath) else {
            throw AppsError.composeFileMissing(installation.composePath)
        }

        let catalogApp = app(withID: installation.appID)
        let compose: String
        if let catalogApp {
            let values = try AppComposeRenderer.resolvedValues(
                app: catalogApp,
                answers: installation.fieldValues,
                dataRoot: installation.dataRoot,
                webPort: installation.webPort ?? catalogApp.webUI?.port ?? 8080
            )
            try AppComposeRenderer.validateRequired(app: catalogApp, values: values)
            compose = try AppComposeRenderer.render(app: catalogApp, values: values)
            try compose.write(toFile: installation.composePath, atomically: true, encoding: .utf8)
        } else {
            // App left the catalog (or is hidden): update images in place.
            compose = try String(contentsOfFile: installation.composePath, encoding: .utf8)
        }

        try await pullImages(in: compose, progress: progress)
        try await orchestrator.down(
            filePath: installation.composePath,
            projectName: Self.projectName(for: installation.appID),
            progress: progress
        )
        try await orchestrator.up(
            filePath: installation.composePath,
            projectName: Self.projectName(for: installation.appID),
            detached: true,
            progress: progress
        )
        if catalogApp != nil, let sha = definitionSHA(for: installation.appID),
           let index = installations.firstIndex(where: { $0.appID == installation.appID }) {
            installations[index].definitionSHA = sha
            saveInstallations()
        }
        serviceStates[installation.appID] = await currentState(for: installation)
    }

    /// Removes the app: containers and networks go, the record is deleted,
    /// and — only when asked — the app's own data root is deleted. Folders
    /// the user pointed at from elsewhere (e.g. a media library) are never
    /// touched.
    func uninstall(_ installation: AppInstallation, deleteData: Bool) async throws {
        try beginOperation(installation.appID, label: "Removing…")
        defer { endOperation(installation.appID) }
        if FileManager.default.fileExists(atPath: installation.composePath) {
            try await orchestrator.down(
                filePath: installation.composePath,
                projectName: Self.projectName(for: installation.appID),
                progress: nil
            )
        }
        installations.removeAll { $0.appID == installation.appID }
        saveInstallations()
        serviceStates[installation.appID] = []
        if deleteData {
            try? FileManager.default.removeItem(atPath: installation.dataRoot)
        }
    }

    func setAutoStart(_ installation: AppInstallation, enabled: Bool) {
        guard let index = installations.firstIndex(where: { $0.appID == installation.appID }) else { return }
        installations[index].autoStart = enabled
        saveInstallations()
    }

    /// Called once the runtime is up: recreates apps that opted into
    /// auto-start and are not currently running. Failures are silent by
    /// design — the app simply stays stopped and shows its status.
    func startAutoStartApps() async {
        prepare()
        await refreshStatuses()
        for installation in installations where installation.autoStart {
            guard status(for: installation.appID) != .running,
                  activeOperations[installation.appID] == nil else { continue }
            try? await start(installation)
        }
    }

    // MARK: Remote registry

    /// Checksum of the catalog definition currently shown for an app, to
    /// compare against an installation's `definitionSHA`.
    func definitionSHA(for appID: String) -> String? {
        prepare()
        return catalogSources[appID].map { RemoteCatalog.sha256Hex(Data($0.utf8)) }
    }

    /// True when the app's template changed since it was installed/last
    /// updated — the catalog card shows a badge and Update adopts it.
    func definitionChanged(for installation: AppInstallation) -> Bool {
        guard let recorded = installation.definitionSHA,
              let current = definitionSHA(for: installation.appID) else { return false }
        return recorded != current
    }

    /// Forces a registry sync. Failures keep the previous (or bundled)
    /// catalog and land in `remoteCatalogState` for the UI.
    func refreshRemoteCatalog() async {
        guard !isSyncingCatalog else { return }
        isSyncingCatalog = true
        remoteCatalogState = .syncing
        defer { isSyncingCatalog = false }
        do {
            let base = catalogRemoteBaseOverride ?? RemoteCatalog.configuredBaseURL
            let result = try await RemoteCatalog.sync(
                base: base, session: catalogSession, cacheDir: remoteCacheDirectoryURL
            )
            loadCatalog()
            UserDefaults.standard.set(Date(), forKey: Self.lastSyncDefaultsKey)
            remoteCatalogState = .synced(Date(), result.total)
        } catch {
            remoteCatalogState = .failed(Self.describe(error))
        }
    }

    /// Auto-refresh path: throttled to once per `maxAge` (24h). Call sites:
    /// app launch and the Apps section appearing; the button bypasses the
    /// throttle by calling refreshRemoteCatalog() directly.
    func maybeRefreshRemoteCatalog(maxAge: TimeInterval = 86_400) async {
        prepare()
        if let last = UserDefaults.standard.object(forKey: Self.lastSyncDefaultsKey) as? Date,
           Date().timeIntervalSince(last) < maxAge {
            return
        }
        await refreshRemoteCatalog()
    }

    // MARK: Web UI

    func webURL(for installation: AppInstallation) -> URL? {
        guard let port = installation.webPort,
              let app = app(withID: installation.appID),
              let webUI = app.webUI else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(webUI.path)")
    }

    func openWebUI(for installation: AppInstallation) {
        guard let url = webURL(for: installation) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Helpers

    /// Compact status text for Cooper's `apps_list` tool: one line per
    /// installed app with overall status, port, and container names (so the
    /// model can hand those to the container tools).
    func cooperSummary() async -> String {
        prepare()
        await refreshStatuses()
        guard !installations.isEmpty else {
            return "No apps are installed from the Apps section."
        }
        return installations.sorted { $0.name < $1.name }.map { installation -> String in
            let status = status(for: installation.appID).label
            let port = installation.webPort.map { ", web port \($0)" } ?? ""
            let containers = (serviceStates[installation.appID] ?? []).map(\.container).joined(separator: ", ")
            return "- \(installation.name) (\(installation.appID)): \(status)\(port); containers: \(containers)"
        }.joined(separator: "\n")
    }

    // Cooper entry points. The gateway authorizes before calling these;
    // each returns a model-facing result string instead of throwing.
    func cooperStart(appID: String) async -> String {
        await performCooper(appID: appID, verb: "Start") { installation, progress in
            try await self.start(installation, progress: progress)
        }
    }

    func cooperStop(appID: String) async -> String {
        await performCooper(appID: appID, verb: "Stop") { installation, progress in
            try await self.stop(installation, progress: progress)
        }
    }

    func cooperUpdate(appID: String) async -> String {
        await performCooper(appID: appID, verb: "Update") { installation, progress in
            try await self.update(installation, progress: progress)
        }
    }

    func cooperRemove(appID: String) async -> String {
        await performCooper(appID: appID, verb: "Remove") { installation, _ in
            try await self.uninstall(installation, deleteData: false)
        }
    }

    private func performCooper(
        appID: String,
        verb: String,
        _ body: (AppInstallation, Progress?) async throws -> Void
    ) async -> String {
        prepare()
        guard let installation = installation(withID: appID) else {
            return "No installed app with id '\(appID)'."
        }
        do {
            try await body(installation, nil)
            return "\(verb) completed for \(installation.name)."
        } catch {
            return "\(verb) failed for \(installation.name): \(Self.describe(error))"
        }
    }

    /// Single error-to-text funnel shared by the Apps views and Cooper.
    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let render as AppComposeRenderer.RenderError: return render.description
        case let apps as AppsError: return apps.description
        case let compose as ComposeError: return compose.description
        case let catalog as AppCatalogError: return catalog.description
        case let remote as RemoteCatalogError: return remote.description
        default: return error.localizedDescription
        }
    }

    func logs(for installation: AppInstallation, service: String, tail: Int = 200) async -> String {
        let entries = (try? await orchestrator.logs(
            filePath: installation.composePath,
            projectName: Self.projectName(for: installation.appID),
            serviceName: service,
            tail: tail
        )) ?? []
        guard let entry = entries.first else { return "No logs available." }
        return entry.logs.isEmpty ? "No logs available." : entry.logs
    }

    func restartService(_ installation: AppInstallation, service: String, progress: Progress? = nil) async throws {
        try beginOperation(installation.appID, label: "Restarting \(service)…")
        defer { endOperation(installation.appID) }
        try await orchestrator.restart(
            filePath: installation.composePath,
            projectName: Self.projectName(for: installation.appID),
            serviceName: service,
            progress: progress
        )
        serviceStates[installation.appID] = await currentState(for: installation)
    }

    /// Pre-pulls every service image for the native platform so `container
    /// run` never has to pull inside its bounded window. Images already
    /// present re-resolve cheaply (manifest check).
    private func pullImages(in compose: String, progress: Progress?) async throws {
        let file: ComposeFile
        do {
            file = try YAMLDecoder().decode(ComposeFile.self, from: compose)
        } catch {
            throw ComposeError.parseFailed(error.localizedDescription)
        }
        for image in Array(Set(file.services.values.compactMap(\.image))).sorted() {
            progress?("Pulling \(image)…")
            let (code, output) = try await ContainerCLI.run(
                ["container", "image", "pull", "--platform", "linux/arm64", image],
                timeout: .seconds(1200)
            )
            if code != 0 {
                throw ComposeError.runFailed("pull \(image)", output)
            }
        }
    }

    private func validatePort(_ port: Int) throws {
        guard port > 1024, port <= 65535 else { throw AppsError.privilegedPort(port) }
        if PortProbe.isPortInUse(UInt16(port)) {
            throw AppsError.portInUse(port)
        }
    }

    private func beginOperation(_ appID: String, label: String) throws {
        guard activeOperations[appID] == nil else {
            throw AppsError.busy(appID)
        }
        activeOperations[appID] = label
    }

    private func endOperation(_ appID: String) {
        activeOperations[appID] = nil
    }
}

/// Bounds an API-client call the same way AppState does: a wedged apiserver
/// never bounds its own XPC calls, so the deadline lives on our side.
private enum Bounded {
    static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ContainerCLIError.unresponsive(command: "apps status check")
            }
            let winner = try await group.next()!
            group.cancelAll()
            return winner
        }
    }
}
