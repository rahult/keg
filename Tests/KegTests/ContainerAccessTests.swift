import XCTest
import ContainerResource
import ContainerizationOCI
@testable import Keg

/// The containers list and inspector surface a reachable URL per container
/// (Gateway hostname for installed apps, localhost port otherwise). These
/// tests pin the resolution rules, including the dash-y app-id naming
/// contract (`kegapp-uptime-kuma-uptime-kuma`).
final class ContainerAccessTests: XCTestCase {
    private let installations = [
        AppInstallation(
            appID: "memos", name: "Memos", fieldValues: [:], webPort: 5230,
            dataRoot: "/tmp/keg-tests/memos", composePath: "/tmp/keg-tests/memos/app.yaml",
            installedAt: Date(timeIntervalSince1970: 1_758_000_000), autoStart: false, definitionSHA: nil
        ),
        AppInstallation(
            appID: "uptime-kuma", name: "Uptime Kuma", fieldValues: [:], webPort: 3001,
            dataRoot: "/tmp/keg-tests/kuma", composePath: "/tmp/keg-tests/kuma/app.yaml",
            installedAt: Date(timeIntervalSince1970: 1_758_000_000), autoStart: false, definitionSHA: nil
        ),
    ]

    private func snapshot(name: String?, project: String?) -> ContainerSnapshot {
        var configuration = ContainerConfiguration(
            id: "deadbeef1234",
            image: ImageDescription(
                reference: "docker.io/library/memos:latest",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:\(String(repeating: "a", count: 64))",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labels: [String: String] = [:]
        if let name { labels["name"] = name }
        if let project { labels["com.docker.compose.project"] = project }
        configuration.labels = labels
        return ContainerSnapshot(configuration: configuration, status: .running, networks: [])
    }

    func testGatewayURLFromProjectLabel() {
        let access = ContainerAccessResolver.resolve(
            snapshot(name: "kegapp-memos-memos", project: "apps-memos"),
            installations: installations,
            gatewayEnabled: true
        )
        XCTAssertEqual(access?.display, "memos.keg:\(GatewayConfig.proxyPort)")
        XCTAssertEqual(access?.url.absoluteString, "http://memos.keg:\(GatewayConfig.proxyPort)")
        XCTAssertEqual(access?.isGateway, true)
    }

    func testNamePrefixFallbackResolvesDashedAppID() {
        // No project label: the container name must disambiguate an id that
        // itself contains dashes.
        let access = ContainerAccessResolver.resolve(
            snapshot(name: "kegapp-uptime-kuma-uptime-kuma", project: nil),
            installations: installations,
            gatewayEnabled: true
        )
        XCTAssertEqual(access?.url.absoluteString, "http://uptime-kuma.keg:\(GatewayConfig.proxyPort)")
    }

    func testLocalhostFallbackWhenGatewayDisabled() {
        let access = ContainerAccessResolver.resolve(
            snapshot(name: "kegapp-memos-memos", project: "apps-memos"),
            installations: installations,
            gatewayEnabled: false
        )
        XCTAssertEqual(access?.display, "localhost:5230")
        XCTAssertEqual(access?.url.absoluteString, "http://localhost:5230")
        XCTAssertEqual(access?.isGateway, false)
    }

    func testAppWithoutWebPortFallsThrough() {
        let noWebPort = [AppInstallation(
            appID: "syncthing", name: "Syncthing", fieldValues: [:], webPort: nil,
            dataRoot: "/tmp/keg-tests/syncthing", composePath: "/tmp/keg-tests/syncthing/app.yaml",
            installedAt: Date(timeIntervalSince1970: 1_758_000_000), autoStart: false, definitionSHA: nil
        )]
        // No published ports on the snapshot either, so nothing to open.
        let access = ContainerAccessResolver.resolve(
            snapshot(name: "kegapp-syncthing-syncthing", project: "apps-syncthing"),
            installations: noWebPort,
            gatewayEnabled: true
        )
        XCTAssertNil(access)
    }

    func testPlainContainerWithoutPortsResolvesToNil() {
        let access = ContainerAccessResolver.resolve(
            snapshot(name: nil, project: nil),
            installations: installations,
            gatewayEnabled: true
        )
        XCTAssertNil(access)
    }
}

@MainActor
final class ContainerActivityLogTests: XCTestCase {
    private func snapshot(id: String, status: RuntimeStatus) -> ContainerSnapshot {
        let configuration = ContainerConfiguration(
            id: id,            image: ImageDescription(
                reference: "docker.io/library/alpine:latest",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.manifest.v1+json",
                    digest: "sha256:\(String(repeating: "b", count: 64))",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        return ContainerSnapshot(configuration: configuration, status: status, networks: [])
    }

    func testFirstSightingSeedsWithoutLogging() {
        let log = ContainerActivityLog()
        log.observe([snapshot(id: "c1", status: .running)])
        XCTAssertTrue(log.events(for: "c1").isEmpty)
    }

    func testTransitionLogsOncePerChange() {
        let log = ContainerActivityLog()
        log.observe([snapshot(id: "c1", status: .running)])
        log.observe([snapshot(id: "c1", status: .stopped)])
        XCTAssertEqual(log.events(for: "c1").map(\.kind), [.stopped])
        log.observe([snapshot(id: "c1", status: .stopped)])
        XCTAssertEqual(log.events(for: "c1").count, 1)
        log.observe([snapshot(id: "c1", status: .running)])
        XCTAssertEqual(log.events(for: "c1").map(\.kind), [.started, .stopped])
    }

    func testVanishedContainersLeaveTheBaseline() {
        let log = ContainerActivityLog()
        log.observe([snapshot(id: "c1", status: .running), snapshot(id: "c2", status: .running)])
        log.observe([snapshot(id: "c1", status: .running)])
        // c2 deleted; when it reappears as running it must seed, not log.
        log.observe([snapshot(id: "c1", status: .running), snapshot(id: "c2", status: .running)])
        XCTAssertTrue(log.events(for: "c2").isEmpty)
        XCTAssertTrue(log.events(for: "c1").isEmpty)
    }
}
