import XCTest
@testable import Keg

/// Tests for the Compose topology graph: level assignment, column ordering,
/// cycle safety, and the plan data the graph is built from. All pure —
/// no container runtime involved.
final class ComposeGraphLayoutTests: XCTestCase {

    private func service(
        _ name: String,
        image: String? = nil,
        dependsOn: [String] = []
    ) -> ComposeOrchestrator.ComposePlan.PlannedService {
        .init(name: name, image: image, dependsOn: dependsOn, command: "container run \(name)", warnings: [])
    }

    // MARK: - Level assignment

    func testLinearChainLevelsAndFlowDirection() {
        // web → api → db. db is the leaf (level 0); the display columns are
        // reversed so web renders leftmost and traffic reads left to right.
        let layout = ComposeGraphLayout.build(from: [
            service("db"),
            service("api", dependsOn: ["db"]),
            service("web", dependsOn: ["api"]),
        ])

        XCTAssertEqual(layout.columns, 3)
        let levels = Dictionary(uniqueKeysWithValues: layout.geometry.nodes.map { ($0.id, $0.level) })
        XCTAssertEqual(levels["db"], 0)
        XCTAssertEqual(levels["api"], 1)
        XCTAssertEqual(levels["web"], 2)

        let columns = Dictionary(uniqueKeysWithValues: layout.geometry.nodes.map { ($0.id, $0.column) })
        XCTAssertEqual(columns["web"], 0, "entry point renders leftmost")
        XCTAssertEqual(columns["db"], 2, "leaf dependency renders rightmost")

        XCTAssertEqual(layout.geometry.edges.count, 2)
        XCTAssertTrue(layout.geometry.edges.contains(ComposeGraphLayout.Edge(from: "web", to: "api")))
        XCTAssertTrue(layout.geometry.edges.contains(ComposeGraphLayout.Edge(from: "api", to: "db")))
    }

    func testDiamondDependenciesShareLevel() {
        let layout = ComposeGraphLayout.build(from: [
            service("db"),
            service("api", dependsOn: ["db"]),
            service("worker", dependsOn: ["db"]),
            service("web", dependsOn: ["api", "worker"]),
        ])

        let levels = Dictionary(uniqueKeysWithValues: layout.geometry.nodes.map { ($0.id, $0.level) })
        XCTAssertEqual(levels["api"], 1)
        XCTAssertEqual(levels["worker"], 1)
        XCTAssertEqual(levels["web"], 2)
        XCTAssertEqual(layout.geometry.edges.count, 4)
    }

    func testLongestPathWinsForLevel() {
        // web → api → db and web → cache. web must sit at level 2, not 1.
        let layout = ComposeGraphLayout.build(from: [
            service("db"),
            service("cache"),
            service("api", dependsOn: ["db"]),
            service("web", dependsOn: ["api", "cache"]),
        ])

        let web = layout.geometry.node(named: "web")
        XCTAssertEqual(web?.level, 2)
    }

    // MARK: - Malformed input

    func testCycleDoesNotHangAndStillLaysOut() {
        let layout = ComposeGraphLayout.build(from: [
            service("a", dependsOn: ["b"]),
            service("b", dependsOn: ["a"]),
        ])

        XCTAssertEqual(layout.geometry.nodes.count, 2)
        for node in layout.geometry.nodes {
            XCTAssertTrue(layout.geometry.size.width >= node.center.x)
            XCTAssertTrue(layout.geometry.size.height >= node.center.y)
        }
    }

    func testUnknownDependencyIsIgnored() {
        let layout = ComposeGraphLayout.build(from: [
            service("web", dependsOn: ["ghost"]),
        ])

        let web = layout.geometry.node(named: "web")
        XCTAssertEqual(web?.level, 0, "a dependency on an undefined service adds no level")
        XCTAssertTrue(layout.geometry.edges.isEmpty, "no edge may point at a service that does not exist")
    }

    func testDuplicateDependenciesProduceOneEdge() {
        let layout = ComposeGraphLayout.build(from: [
            service("db"),
            service("api", dependsOn: ["db", "db"]),
        ])

        XCTAssertEqual(layout.geometry.edges.count, 1)
    }

    // MARK: - Geometry

    func testNodesStayInsideCanvasAndRowOrderIsStable() {
        let layout = ComposeGraphLayout.build(from: [
            service("db"),
            service("cache"),
            service("api", dependsOn: ["db"]),
            service("worker", dependsOn: ["cache"]),
        ])

        // api and worker share the middle column; their rows follow first
        // appearance so the graph doesn't reshuffle when services are added.
        let api = layout.geometry.node(named: "api")
        let worker = layout.geometry.node(named: "worker")
        XCTAssertEqual(api?.row, 0)
        XCTAssertEqual(worker?.row, 1)
        XCTAssertLessThan(api!.center.y, worker!.center.y)

        for node in layout.geometry.nodes {
            let halfW = ComposeGraphLayout.Geometry.nodeWidth / 2
            let halfH = ComposeGraphLayout.Geometry.nodeHeight / 2
            XCTAssertGreaterThanOrEqual(node.center.x - halfW, 0)
            XCTAssertLessThanOrEqual(node.center.x + halfW, layout.geometry.size.width)
            XCTAssertGreaterThanOrEqual(node.center.y - halfH, 0)
            XCTAssertLessThanOrEqual(node.center.y + halfH, layout.geometry.size.height)
        }
    }

    func testEmptyPlanProducesEmptyLayout() {
        let layout = ComposeGraphLayout.build(from: [])
        XCTAssertEqual(layout.columns, 1)
        XCTAssertTrue(layout.geometry.nodes.isEmpty)
        XCTAssertTrue(layout.geometry.edges.isEmpty)
    }

    // MARK: - Plan data feeding the graph

    func testPlanCarriesImageAndDependencies() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keg-graph-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          web:
            image: nginx:alpine
            depends_on: [api]
          api:
            image: node:20-alpine
            depends_on: [db, ghost]
          db:
            image: postgres:16-alpine
        """.write(to: file, atomically: true, encoding: .utf8)

        let plan = try await ComposeOrchestrator().plan(filePath: file.path, projectName: "graphtest")

        let web = plan.services.first { $0.name == "web" }
        let api = plan.services.first { $0.name == "api" }
        XCTAssertEqual(web?.image, "nginx:alpine")
        XCTAssertEqual(web?.dependsOn, ["api"])
        XCTAssertEqual(api?.dependsOn, ["db"], "dangling references are dropped before the graph sees them")
    }
}
