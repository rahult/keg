import XCTest
@testable import Keg

/// DevContainerSpec parsing: devcontainer.json is a hand-edited JSON file
/// with loose typing (ports as Int or String, optional everything), so the
/// decoder must be forgiving and preserve values exactly.
final class DevContainerSpecTests: XCTestCase {

    private func decode(_ json: String) throws -> DevContainerSpec {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(DevContainerSpec.self, from: data)
    }

    func testParsesImageBasedConfig() throws {
        let spec = try decode("""
        {
          "name": "Keg Test",
          "image": "node:20-alpine",
          "forwardPorts": [3000, "9229"],
          "containerEnv": { "NODE_ENV": "development" },
          "workspaceMount": "src=/tmp/project,dst=/workspaces/project,type=bind",
          "workspaceFolder": "/workspaces/project",
          "postCreateCommand": "npm install"
        }
        """)
        XCTAssertEqual(spec.name, "Keg Test")
        XCTAssertEqual(spec.image, "node:20-alpine")
        XCTAssertEqual(spec.forwardPorts?.count, 2)
        XCTAssertEqual(spec.forwardPorts?.first?.portNumber, 3000)
        XCTAssertEqual(spec.forwardPorts?.last?.portNumber, 9229)
        XCTAssertEqual(spec.containerEnv?["NODE_ENV"], "development")
        XCTAssertEqual(spec.workspaceFolder, "/workspaces/project")
        XCTAssertEqual(spec.postCreateCommand, "npm install")
    }

    func testParsesBuildBasedConfig() throws {
        let spec = try decode("""
        {
          "name": "built",
          "build": { "dockerfile": "Dockerfile", "context": "..", "args": { "VERSION": "1.0" } },
          "runArgs": ["--cap-add", "SYS_PTRACE"]
        }
        """)
        XCTAssertEqual(spec.build?.dockerfile, "Dockerfile")
        XCTAssertEqual(spec.build?.context, "..")
        XCTAssertEqual(spec.build?.args?["VERSION"], "1.0")
        XCTAssertEqual(spec.runArgs, ["--cap-add", "SYS_PTRACE"])
        XCTAssertNil(spec.image)
    }

    func testPortValueRejectsOutOfRange() throws {
        let spec = try decode(#"{"image":"alpine","forwardPorts":[70000]}"#)
        XCTAssertNil(spec.forwardPorts?.first?.portNumber)
    }

    func testMinimalConfig() throws {
        let spec = try decode(#"{"image":"alpine:latest"}"#)
        XCTAssertEqual(spec.image, "alpine:latest")
        XCTAssertNil(spec.forwardPorts)
        XCTAssertNil(spec.containerEnv)
        XCTAssertNil(spec.mounts)
    }

    func testRoundTripEncoding() throws {
        let spec = try decode("""
        { "name": "rt", "image": "alpine", "forwardPorts": [8080, "9090"] }
        """)
        let data = try JSONEncoder().encode(spec)
        let reparsed = try JSONDecoder().decode(DevContainerSpec.self, from: data)
        XCTAssertEqual(reparsed.forwardPorts?.first?.portNumber, 8080)
        XCTAssertEqual(reparsed.forwardPorts?.last?.portNumber, 9090)
    }

    // MARK: - mountArgs translation

    /// Long-form specs must become `--mount`: passing them to `-v` makes the
    /// CLI create a *volume* named after the spec, mounting the workspace
    /// empty (verified live against container CLI 1.3.1).
    func testMountArgsLongFormBind() {
        XCTAssertEqual(
            DevContainerVM.mountArgs("src=/tmp/project,dst=/workspaces/project,type=bind,readonly"),
            ["--mount", "type=bind,target=/workspaces/project,source=/tmp/project,readonly"]
        )
    }

    func testMountArgsLongFormTargetAlias() {
        XCTAssertEqual(
            DevContainerVM.mountArgs("source=/a,target=/b"),
            ["--mount", "type=bind,target=/b,source=/a"]
        )
    }

    func testMountArgsShortFormPassesThrough() {
        XCTAssertEqual(
            DevContainerVM.mountArgs("/host/path:/container/path"),
            ["-v", "/host/path:/container/path"]
        )
    }

    func testMountArgsVolumeWithoutSource() {
        let args = DevContainerVM.mountArgs("dst=/data,type=volume")
        XCTAssertEqual(args.first, "--mount")
        XCTAssertEqual(args.last, "type=volume,target=/data")
    }
}
