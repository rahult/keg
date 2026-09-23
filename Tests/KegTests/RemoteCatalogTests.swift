import XCTest
import Yams
@testable import Keg

/// Registry sync and catalog merging for the Apps section. Network is a
/// stubbed URLProtocol; all disk access goes through temp directories, so
/// nothing here touches ~/.keg or the container runtime.
final class RemoteCatalogTests: XCTestCase {
    private var cacheDir: URL!
    private var userDir: URL!

    private static let lastSyncKey = "apps.catalog.lastSync"

    override func setUp() async throws {
        try await super.setUp()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-registry-tests-\(UUID().uuidString.prefix(8))")
        userDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-registry-user-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.removeItem(at: userDir)
        StubURLProtocol.routes = [:]
        try await super.tearDown()
    }

    /// A manager pointed at the test's temp directories instead of ~/.keg.
    @MainActor
    private func makeManager() -> AppStoreManager {
        let manager = AppStoreManager()
        manager.catalogUserDirectoryOverride = userDir.path
        manager.catalogRemoteCacheOverride = cacheDir
        return manager
    }

    // MARK: - Index parsing

    func testIndexDecodes() throws {
        let yaml = """
        version: 1
        updated: 2026-09-24
        apps:
          - id: memos
            file: apps/memos.yaml
            sha256: abc
          - id: gitea
            file: apps/gitea.yaml
        """
        let index = try YAMLDecoder().decode(RemoteCatalogIndex.self, from: yaml)
        XCTAssertEqual(index.version, 1)
        XCTAssertEqual(index.apps.count, 2)
        XCTAssertEqual(index.apps[0].sha256, "abc")
        XCTAssertNil(index.apps[1].sha256)
    }

    // MARK: - Sync

    func testSyncDownloadsAndCachesRegistry() async throws {
        let base = URL(string: "https://registry.test/main")!
        let appYAML = bundledMemosYAML
        StubURLProtocol.routes = [
            base.appending(path: "index.yaml").absoluteString: .success(indexData(memosEntry(sha: sha(appYAML)))),
            base.appending(path: "apps/memos.yaml").absoluteString: .success(indexData(appYAML)),
        ]

        let result = try await RemoteCatalog.sync(base: base, session: stubbedSession, cacheDir: cacheDir)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.downloaded, 1)
        XCTAssertEqual(result.registryUpdated, "2026-09-24")

        // The mirror is complete and readable.
        let cached = RemoteCatalog.cachedFiles(cacheDir: cacheDir)
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached.first?.yaml, appYAML)
        XCTAssertEqual(cached.first?.entry.id, "memos")
    }

    func testSyncSkipsUnchangedFilesOnSecondRun() async throws {
        let base = URL(string: "https://registry.test/main")!
        let appYAML = bundledMemosYAML
        let sha = sha(appYAML)
        StubURLProtocol.routes = [
            base.appending(path: "index.yaml").absoluteString: .success(indexData(memosEntry(sha: sha))),
            base.appending(path: "apps/memos.yaml").absoluteString: .success(indexData(appYAML)),
        ]
        _ = try await RemoteCatalog.sync(base: base, session: stubbedSession, cacheDir: cacheDir)

        // Second run: everything matches the checksums, nothing downloads.
        // (The app file route is removed; if the sync tried to fetch it, the
        // stub 404s and the sync fails.)
        StubURLProtocol.routes[base.appending(path: "apps/memos.yaml").absoluteString] = nil
        let second = try await RemoteCatalog.sync(base: base, session: stubbedSession, cacheDir: cacheDir)
        XCTAssertEqual(second.downloaded, 0)
    }

    func testSyncRejectsChecksumMismatch() async throws {
        let base = URL(string: "https://registry.test/main")!
        StubURLProtocol.routes = [
            base.appending(path: "index.yaml").absoluteString: .success(indexData(memosEntry(sha: String(repeating: "0", count: 64)))),
            base.appending(path: "apps/memos.yaml").absoluteString: .success(indexData(bundledMemosYAML)),
        ]
        do {
            _ = try await RemoteCatalog.sync(base: base, session: stubbedSession, cacheDir: cacheDir)
            XCTFail("expected checksumMismatch")
        } catch let error as RemoteCatalogError {
            XCTAssertTrue(error.description.contains("Checksum mismatch"), error.description)
        }
        // The commit point semantics: a failed sync leaves no cached index.
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.appending(path: "index.yaml").path))
    }

    func testSyncRejectsPathTraversal() async throws {
        let base = URL(string: "https://registry.test/main")!
        let index = """
        version: 1
        apps:
          - id: evil
            file: ../../outside.yaml
        """
        StubURLProtocol.routes = [
            base.appending(path: "index.yaml").absoluteString: .success(Data(index.utf8)),
        ]
        do {
            _ = try await RemoteCatalog.sync(base: base, session: stubbedSession, cacheDir: cacheDir)
            XCTFail("expected unsafePath")
        } catch let error as RemoteCatalogError {
            guard case .unsafePath = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testSyncRejects404Index() async throws {
        let base = URL(string: "https://registry.test/missing")!
        do {
            _ = try await RemoteCatalog.sync(base: base, session: stubbedSession, cacheDir: cacheDir)
            XCTFail("expected badStatus")
        } catch let error as RemoteCatalogError {
            guard case .badStatus(404, _) = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: - Catalog merge precedence

    @MainActor
    func testRemoteOverridesBundledAndUserOverridesRemote() async throws {
        let memosYAML = bundledMemosYAML
        let remoteMemos = memosYAML.replacingOccurrences(
            of: "tagline: Lightweight, self-hosted note taking",
            with: "tagline: REMOTE OVERRIDE"
        )
        let userMemos = memosYAML.replacingOccurrences(
            of: "tagline: Lightweight, self-hosted note taking",
            with: "tagline: USER OVERRIDE"
        )
        try indexData(memosEntry(sha: sha(remoteMemos)))
            .write(to: cacheDir.appending(path: "index.yaml"))
        try FileManager.default.createDirectory(at: cacheDir.appending(path: "apps"), withIntermediateDirectories: true)
        try remoteMemos.write(to: cacheDir.appending(path: "apps/memos.yaml"), atomically: true, encoding: .utf8)
        try userMemos.write(to: userDir.appendingPathComponent("memos.yaml"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        manager.loadCatalog()

        let memos = manager.catalog.first { $0.id == "memos" }
        XCTAssertEqual(memos?.tagline, "USER OVERRIDE")
        XCTAssertEqual(manager.definitionSHA(for: "memos"), sha(userMemos))

        // Everything else still comes from the bundled tier.
        XCTAssertTrue(manager.catalog.contains { $0.id == "gitea" })
    }

    @MainActor
    func testRegistryCanHideAnApp() async throws {
        let memosYAML = bundledMemosYAML.replacingOccurrences(
            of: "tagline: Lightweight, self-hosted note taking",
            with: "tagline: Lightweight, self-hosted note taking\nhidden: true"
        )
        try indexData(memosEntry(sha: sha(memosYAML)))
            .write(to: cacheDir.appending(path: "index.yaml"))
        try FileManager.default.createDirectory(at: cacheDir.appending(path: "apps"), withIntermediateDirectories: true)
        try memosYAML.write(to: cacheDir.appending(path: "apps/memos.yaml"), atomically: true, encoding: .utf8)

        let manager = makeManager()
        manager.loadCatalog()
        print("DEBUG warnings:", manager.catalogWarnings)
        print("DEBUG catalog ids:", manager.catalog.map { $0.id })
        print("DEBUG memos hidden:", manager.catalog.first { $0.id == "memos" }?.hidden as Any)
        XCTAssertEqual(manager.catalog.first { $0.id == "memos" }?.hidden, true)
        // Hidden apps stay resolvable for installed apps.
        XCTAssertNotNil(manager.app(withID: "memos"))
    }

    @MainActor
    func testDefinitionChangedDetectsTemplateUpdates() async throws {
        let manager = makeManager()
        manager.loadCatalog()
        let currentSHA = manager.definitionSHA(for: "memos")
        let installed = try installation(sha: currentSHA)
        XCTAssertFalse(manager.definitionChanged(for: installed), "matching checksum must read as unchanged")

        let drifted = try installation(sha: String(repeating: "f", count: 64))
        XCTAssertTrue(manager.definitionChanged(for: drifted), "different checksum must read as changed")

        // Pre-registry installs have no recorded checksum: not "changed".
        XCTAssertFalse(manager.definitionChanged(for: try installation(sha: nil)))
    }

    // MARK: - Required-field guard

    func testValidateRequiredRejectsEmptyRequiredValues() throws {
        let app = try singleApp("linkding")
        let values = try AppComposeRenderer.resolvedValues(
            app: app,
            answers: ["AdminUsername": "admin", "AdminPassword": "  "],
            dataRoot: "/tmp/d", webPort: 9090
        )
        XCTAssertThrowsError(try AppComposeRenderer.validateRequired(app: app, values: values)) { error in
            guard case AppComposeRenderer.RenderError.missingRequired = error else {
                return XCTFail("expected missingRequired, got \(error)")
            }
        }
        XCTAssertNoThrow(try AppComposeRenderer.validateRequired(
            app: app,
            values: ["AdminUsername": "admin", "AdminPassword": "real-secret"]
        ))
    }

    // MARK: - Checksums

    func testSHA256KnownVector() {
        XCTAssertEqual(
            RemoteCatalog.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// End-to-end: sync the repo's own seeded registry/ folder over a
    /// file:// URL — the same path a fresh install uses before the GitHub
    /// repo exists, and a format check on the shipped index.
    func testSyncsSeededRegistryOverFileURL() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/KegTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let registry = repoRoot.appending(path: "registry")
        guard FileManager.default.fileExists(atPath: registry.appending(path: "index.yaml").path) else {
            throw XCTSkip("registry/ folder not present")
        }

        let result = try await RemoteCatalog.sync(
            base: registry, session: .shared, cacheDir: cacheDir
        )
        XCTAssertEqual(result.total, 9, "the seeded registry should list every bundled app")
        XCTAssertEqual(result.downloaded, 9)
        let cached = RemoteCatalog.cachedFiles(cacheDir: cacheDir)
        XCTAssertEqual(cached.count, 9)
        XCTAssertTrue(cached.allSatisfy { !$0.yaml.isEmpty })
    }

    // MARK: - Helpers

    private var stubbedSession: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var bundledMemosYAML: String {
        guard let yaml = BundledAppCatalog.yamlContents.first(where: { $0.contains("id: memos") }) else {
            fatalError("bundled memos definition missing")
        }
        // yamlContents already holds the compiled (indentation-stripped) text.
        return yaml.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func memosEntry(sha: String) -> String {
        """
        version: 1
        updated: 2026-09-24
        apps:
          - id: memos
            file: apps/memos.yaml
            sha256: \(sha)
        """
    }

    private func indexData(_ entry: String) -> Data {
        Data(entry.utf8)
    }

    private func sha(_ string: String) -> String {
        RemoteCatalog.sha256Hex(Data(string.utf8))
    }

    @MainActor
    private func installation(sha: String?) throws -> AppInstallation {
        guard let recorded = sha else {
            return AppInstallation(
                appID: "memos", name: "Memos", fieldValues: [:], webPort: 5230,
                dataRoot: "/tmp/d", composePath: "/tmp/d/app.yaml",
                installedAt: Date(), autoStart: true, definitionSHA: nil
            )
        }
        return AppInstallation(
            appID: "memos", name: "Memos", fieldValues: [:], webPort: 5230,
            dataRoot: "/tmp/d", composePath: "/tmp/d/app.yaml",
            installedAt: Date(), autoStart: true, definitionSHA: recorded
        )
    }

    private func singleApp(_ id: String) throws -> CatalogApp {
        let apps = try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents)
        guard let app = apps.first(where: { $0.id == id }) else {
            throw XCTSkip("bundled app \(id) missing")
        }
        return app
    }
}

/// Maps URLs to canned responses for URLSession-based tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [String: Result<Data, Error>] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        switch Self.routes[url.absoluteString] {
        case .success(let data):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
