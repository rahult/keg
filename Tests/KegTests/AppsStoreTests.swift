import XCTest
import Yams
@testable import Keg

/// Pure-logic coverage for the Apps section: bundled catalog integrity,
/// compose template rendering (including adversarial secrets), port
/// probing, and installation records. No container runtime required.
final class AppsStoreTests: XCTestCase {

    // MARK: - Bundled catalog integrity

    func testBundledCatalogLoads() throws {
        let apps = try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents)
        XCTAssertFalse(apps.isEmpty)
        XCTAssertEqual(apps.count, BundledAppCatalog.yamlContents.count)
        XCTAssertEqual(Set(apps.map(\.id)).count, apps.count, "catalog ids must be unique")
        for app in apps {
            XCTAssertFalse(app.name.isEmpty, app.id)
            XCTAssertFalse(app.tagline.isEmpty, app.id)
            XCTAssertFalse(app.summary.isEmpty, app.id)
            XCTAssertFalse(app.compose.isEmpty, app.id)
            XCTAssertNotNil(
                app.id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression),
                "app id must be kebab-case: \(app.id)"
            )
        }
    }

    func testBundledCatalogPlaceholdersAreSatisfiable() throws {
        for app in try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents) {
            let referenced = AppComposeRenderer.placeholders(in: app.compose)
            let provided = Set(app.fields.map(\.id)).union(AppComposeRenderer.reservedIDs)
            XCTAssertEqual(
                referenced.subtracting(provided), [],
                "\(app.id) references placeholders no field provides"
            )
            if app.webUI != nil {
                XCTAssertTrue(
                    referenced.contains("KegWebPort"),
                    "\(app.id) declares a web UI but never substitutes {{.KegWebPort}}"
                )
            }
        }
    }

    func testBundledCatalogContainerNamingConvention() throws {
        // Inter-service hostnames rely on explicit container names, so every
        // bundled service must set one and follow the kegapp-<app>-<service>
        // scheme (status matching and Cooper's log-reading story depend on
        // this being predictable).
        for app in try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents) {
            let values = try AppComposeRenderer.resolvedValues(
                app: app, answers: [:], dataRoot: "/tmp/keg-apps-tests/\(app.id)", webPort: app.webUI?.port ?? 8080
            )
            let rendered = try AppComposeRenderer.render(app: app, values: values)
            let file = try YAMLDecoder().decode(ComposeFile.self, from: rendered)
            XCTAssertFalse(file.services.isEmpty, app.id)
            for (service, config) in file.services {
                XCTAssertEqual(
                    config.containerName.map { String($0.prefix("kegapp-\(app.id)-".count)) },
                    "kegapp-\(app.id)-",
                    "\(app.id)/\(service) must declare container_name prefixed kegapp-\(app.id)-"
                )
                XCTAssertNotNil(config.image, "\(app.id)/\(service) has no image")
            }
        }
    }

    func testBundledCatalogWebUIPortIsPublished() throws {
        for app in try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents) {
            guard let webUI = app.webUI else { continue }
            let values = try AppComposeRenderer.resolvedValues(
                app: app, answers: [:], dataRoot: "/tmp/keg-apps-tests/\(app.id)", webPort: webUI.port
            )
            let rendered = try AppComposeRenderer.render(app: app, values: values)
            let file = try YAMLDecoder().decode(ComposeFile.self, from: rendered)
            let publishedPorts = file.services.values.flatMap { $0.ports ?? [] }
            XCTAssertTrue(
                publishedPorts.contains { $0.contains("\(webUI.port):") || $0.hasPrefix("\(webUI.port)") },
                "\(app.id) web UI port \(webUI.port) is not among published ports: \(publishedPorts)"
            )
        }
    }

    // MARK: - Catalog loading rules

    func testDuplicateIDsAreRejected() {
        let yaml = """
        id: dup
        name: Dup
        tagline: t
        category: c
        icon: circle
        summary: s
        compose: |
          services:
            a:
              image: alpine
        """
        XCTAssertThrowsError(try AppCatalog.load(yamlContents: [yaml, yaml])) { error in
            guard case AppCatalogError.duplicateID = error else {
                return XCTFail("expected duplicateID, got \(error)")
            }
        }
    }

    func testInvalidFieldIDsAreRejected() {
        let yaml = """
        id: badfield
        name: Bad
        tagline: t
        category: c
        icon: circle
        summary: s
        fields:
          - id: "9starts-with-digit"
            label: X
        compose: |
          services:
            a:
              image: alpine
        """
        XCTAssertThrowsError(try AppCatalog.load(yamlContents: [yaml])) { error in
            guard case AppCatalogError.invalidFieldID = error else {
                return XCTFail("expected invalidFieldID, got \(error)")
            }
        }
    }

    // MARK: - Rendering

    func testRenderWithDefaultsOnlyProducesParseableCompose() throws {
        // The zero-input path: every required field has a catalog default.
        for app in try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents) {
            let values = try AppComposeRenderer.resolvedValues(
                app: app, answers: [:], dataRoot: "/tmp/keg-apps-tests/\(app.id)", webPort: app.webUI?.port ?? 8080
            )
            let rendered = try AppComposeRenderer.render(app: app, values: values)
            XCTAssertFalse(rendered.contains("{{."), "\(app.id) still has a placeholder after rendering")
            _ = try YAMLDecoder().decode(ComposeFile.self, from: rendered)
        }
    }

    func testStandaloneSecretsWithYAMLSpecialCharactersSurvive() throws {
        // linkding's password slots are whole-value placeholders, so even
        // hostile characters must round-trip through the rendered YAML.
        let app = try singleApp("linkding")
        let evil = #"p@ss wörd #1 "quoted" 'single: [brackets]{yes}"#
        let values = try AppComposeRenderer.resolvedValues(
            app: app,
            answers: ["AdminUsername": "admin", "AdminPassword": evil],
            dataRoot: "/tmp/keg-apps-tests/linkding",
            webPort: app.webUI!.port
        )
        let rendered = try AppComposeRenderer.render(app: app, values: values)
        let file = try YAMLDecoder().decode(ComposeFile.self, from: rendered)
        let env = file.services["linkding"]?.environment ?? []
        XCTAssertTrue(
            env.contains("LD_SUPERUSER_PASSWORD=\(evil)"),
            "password was corrupted: \(env)"
        )
    }

    func testEmbeddedSecretWithQuoteIsRejected() throws {
        // Passwords interpolated inside a template-quoted DATABASE_URL can't
        // carry double quotes — the renderer must refuse, not emit a broken
        // document.
        let app = try singleApp("miniflux")
        let values = try AppComposeRenderer.resolvedValues(
            app: app,
            answers: [
                "AdminUsername": "admin",
                "AdminPassword": "fine-password",
                "DBPassword": #"bro"ken"#,
            ],
            dataRoot: "/tmp/keg-apps-tests/miniflux",
            webPort: app.webUI!.port
        )
        XCTAssertThrowsError(try AppComposeRenderer.render(app: app, values: values)) { error in
            guard case AppComposeRenderer.RenderError.embeddedUnsafeValue = error else {
                return XCTFail("expected embeddedUnsafeValue, got \(error)")
            }
        }
    }

    func testMissingPlaceholderValueThrows() {
        let app = CatalogApp(
            id: "needs-value", name: "Needs", tagline: "t", category: "c", icon: "circle",
            summary: "s",
            compose: """
            services:
              a:
                image: alpine
                environment:
                  TOKEN: {{.MissingToken}}
            """
        )
        XCTAssertThrowsError(
            try AppComposeRenderer.render(app: app, values: ["Unrelated": "x"])
        ) { error in
            guard case AppComposeRenderer.RenderError.missingValues = error else {
                return XCTFail("expected missingValues, got \(error)")
            }
        }
    }

    func testResolvedValuesExpandKegDataDirInDefaults() throws {
        let app = try singleApp("jellyfin")
        let values = try AppComposeRenderer.resolvedValues(
            app: app, answers: [:], dataRoot: "/Users/x/.keg/apps/jellyfin", webPort: 8096
        )
        XCTAssertEqual(values["MediaDirectory"], "/Users/x/.keg/apps/jellyfin/media")
        XCTAssertEqual(values["KegDataDir"], "/Users/x/.keg/apps/jellyfin")
        XCTAssertEqual(values["KegWebPort"], "8096")
        XCTAssertEqual(values["KegTimeZone"], TimeZone.current.identifier)
    }

    func testAnswersOverrideDefaults() throws {
        let app = try singleApp("linkding")
        let values = try AppComposeRenderer.resolvedValues(
            app: app,
            answers: ["AdminUsername": "ripp", "AdminPassword": "hunter2"],
            dataRoot: "/tmp/d", webPort: 9090
        )
        XCTAssertEqual(values["AdminUsername"], "ripp")
        XCTAssertEqual(values["AdminPassword"], "hunter2")
    }

    // MARK: - YAML scalar quoting

    func testYAMLScalarQuoting() {
        XCTAssertEqual(AppComposeRenderer.yamlScalar(""), "\"\"")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("plain"), "plain")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("8280"), "8280")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("/Users/x/.keg/apps/memos/data"), "/Users/x/.keg/apps/memos/data")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("two words"), "\"two words\"")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("# hash"), "\"# hash\"")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("a: b"), "\"a: b\"")
        XCTAssertEqual(AppComposeRenderer.yamlScalar("true"), "\"true\"")
        // Backslashes are literal in YAML *plain* scalars, so no quoting needed.
        XCTAssertEqual(AppComposeRenderer.yamlScalar("back\\slash"), "back\\slash")
        XCTAssertEqual(AppComposeRenderer.yamlScalar(#"say "hi""#), "\"say \\\"hi\\\"\"")
    }

    // MARK: - Port probe

    func testPortProbeReportsBoundAndFreePorts() throws {
        // Bind an ephemeral listener, then confirm the probe sees it.
        let listener = try POSIXListener()
        XCTAssertTrue(PortProbe.isPortInUse(listener.port), "probe missed a live listener on \(listener.port)")
        listener.close()
        // After close the port may still be probed true briefly (TIME_WAIT is
        // SO_REUSEADDR-exempt for listeners but this is our own bind), so only
        // assert the negative on a distinctly different ephemeral port.
        let free = try POSIXListener()
        let freePort = free.port
        free.close()
        XCTAssertEqual(PortProbe.isPortInUse(freePort), false, "port \(freePort) reported in use right after its listener closed")
    }

    // MARK: - Installation records & paths

    func testInstallationRecordRoundTrips() throws {
        let record = AppInstallation(
            appID: "memos",
            name: "Memos",
            fieldValues: ["Secret": "s3cret"],
            webPort: 5230,
            dataRoot: "/Users/x/.keg/apps/memos",
            composePath: "/Users/x/.keg/apps/memos/app.yaml",
            installedAt: Date(timeIntervalSince1970: 1_758_000_000),
            autoStart: true,
            definitionSHA: "abc123"
        )
        let data = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([AppInstallation].self, from: data)
        XCTAssertEqual(decoded, [record])
    }

    func testInstallationRecordDecodesWithoutDefinitionSHA() throws {
        // Records written before the registry feature have no definitionSHA
        // key — they must keep loading.
        let legacy = """
        [{"appID":"memos","name":"Memos","fieldValues":{},"webPort":5230,
          "dataRoot":"/Users/x/.keg/apps/memos","composePath":"/Users/x/.keg/apps/memos/app.yaml",
          "installedAt":677515200000,"autoStart":true}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([AppInstallation].self, from: legacy)
        XCTAssertEqual(decoded.first?.definitionSHA, nil)
        XCTAssertEqual(decoded.first?.appID, "memos")
    }

    func testProjectAndPathHelpers() {
        XCTAssertEqual(AppStoreManager.projectName(for: "miniflux"), "apps-miniflux")
        XCTAssertTrue(AppStoreManager.defaultDataRoot(for: "memos").hasSuffix("/.keg/apps/memos"))
        XCTAssertTrue(AppStoreManager.composePath(for: "memos").hasSuffix("/.keg/apps/memos/app.yaml"))
        XCTAssertEqual(AppStoreManager.projectName(for: "apps-x"), "apps-apps-x")
    }

    func testSecretGeneratorOutput() {
        let secret = SecretGenerator.password()
        XCTAssertEqual(secret.count, 24)
        XCTAssertTrue(
            secret.allSatisfy { $0.isLetter || $0.isNumber },
            "generated secrets must be alphanumeric for YAML and URL safety: \(secret)"
        )
        XCTAssertNotEqual(SecretGenerator.password(), SecretGenerator.password())
    }

    // MARK: - Error text

    func testErrorDescriptionsAreUserFacing() {
        XCTAssertEqual(
            AppStoreManager.describe(AppStoreManager.AppsError.portInUse(8080)),
            "Port 8080 is already in use on this Mac. Pick another port."
        )
        XCTAssertFalse(AppStoreManager.describe(ComposeError.missingImage("web")).isEmpty)
    }

    // MARK: - Helpers

    private func singleApp(_ id: String) throws -> CatalogApp {
        let apps = try AppCatalog.load(yamlContents: BundledAppCatalog.yamlContents)
        guard let app = apps.first(where: { $0.id == id }) else {
            throw XCTSkip("bundled app \(id) missing")
        }
        return app
    }
}

/// Minimal POSIX TCP listener for port-probe tests.
private final class POSIXListener {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: "POSIXListener", code: 1) }
        fd = descriptor
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { Darwin.close(descriptor); throw NSError(domain: "POSIXListener", code: 2) }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &len)
            }
        }
        guard getNameResult == 0 else { Darwin.close(descriptor); throw NSError(domain: "POSIXListener", code: 3) }
        guard listen(descriptor, 1) == 0 else { Darwin.close(descriptor); throw NSError(domain: "POSIXListener", code: 4) }
        port = UInt16(bound.sin_port.byteSwapped)
    }

    func close() {
        Darwin.close(fd)
    }
}
