import XCTest
@testable import Keg

/// Unit tests for the Docker API streaming layer: stdcopy framing,
/// hijack-path parsing, and pull-progress mapping.
final class DockerAPIStreamingTests: XCTestCase {

    // MARK: - stdcopy framing

    func testStdcopyFrameLayout() {
        let payload: [UInt8] = Array("hello".utf8)
        let buffer = DockerStreamFraming.frame(.stdout, payload: payload)
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: 13)
        XCTAssertEqual(Array(bytes?.prefix(4) ?? []), [1, 0, 0, 0], "stream byte + padding")
        XCTAssertEqual(Array(bytes?.dropFirst(4).prefix(4) ?? []), [0, 0, 0, 5], "big-endian payload length")
        XCTAssertEqual(Array(bytes?.dropFirst(8) ?? []), payload)
    }

    func testStdcopyFrameDataVariant() throws {
        let data = DockerStreamFraming.frame(.stderr, payload: Data("x".utf8)).getData(
            at: 0,
            length: 9
        )
        let frame = try XCTUnwrap(data)
        XCTAssertEqual(frame[0], 2, "stderr stream byte")
        XCTAssertEqual(frame[4], 0, "length high byte")
        XCTAssertEqual(frame[7], 1, "length low byte")
    }

    // MARK: - hijack path parsing

    func testHijackTargetExecStart() {
        XCTAssertEqual(
            DockerAPIServer.hijackTarget(forPath: "/v1.51/exec/abc123/start"),
            .execStart("abc123")
        )
        XCTAssertEqual(
            DockerAPIServer.hijackTarget(forPath: "/exec/abc/start"),
            .execStart("abc")
        )
    }

    func testHijackTargetAttach() {
        XCTAssertEqual(
            DockerAPIServer.hijackTarget(forPath: "/v1.45/containers/myctr/attach?stream=1&stdout=1&stderr=1&stdin=0"),
            .containerAttach("myctr", stdin: false)
        )
        XCTAssertEqual(
            DockerAPIServer.hijackTarget(forPath: "/containers/myctr/attach?stream=1&stdin=1&stdout=1"),
            .containerAttach("myctr", stdin: true)
        )
    }

    func testHijackTargetRejectsOtherPaths() {
        XCTAssertNil(DockerAPIServer.hijackTarget(forPath: "/v1.45/containers/myctr/start"))
        XCTAssertNil(DockerAPIServer.hijackTarget(forPath: "/v1.45/exec/abc/json"))
        XCTAssertNil(DockerAPIServer.hijackTarget(forPath: "/exec"))
    }

    func testExecIDFromPath() {
        XCTAssertEqual(DockerAPIServer.execIDFromPath("/v1.41/exec/e1/start"), "e1")
        XCTAssertNil(DockerAPIServer.execIDFromPath("/v1.41/exec/e1/resize"))
    }

    // MARK: - pull progress mapping

    func testPullProgressMapperExtractsShortLayerID() throws {
        let message = try XCTUnwrap(PullProgressMapper.message(
            forLine: "pulling blob sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        ))
        XCTAssertEqual(message.id, "abcdef123456")
        XCTAssertFalse(message.status.isEmpty)
    }

    func testPullProgressMapperSkipsEmptyLines() {
        XCTAssertNil(PullProgressMapper.message(forLine: "   "))
        XCTAssertNil(PullProgressMapper.message(forLine: ""))
    }

    func testPullProgressMapperPlainLine() throws {
        let message = try XCTUnwrap(PullProgressMapper.message(forLine: "unpacked image"))
        XCTAssertNil(message.id)
        XCTAssertEqual(message.status, "unpacked image")
    }

    // MARK: - stats JSON shape

    func testStatsEncodesDockerFieldNames() throws {
        let stats = DockerContainerStats(
            read: "2026-01-01T00:00:02Z",
            preread: "2026-01-01T00:00:01Z",
            id: "ctr",
            name: "ctr",
            pidsStats: DockerPidsStats(current: 3),
            cpuStats: DockerCPUStats(
                cpuUsage: DockerCPUUsage(totalUsage: 100, usageInKernelmode: 10, usageInUsermode: 90),
                systemCpuUsage: 1_000,
                onlineCpus: 8
            ),
            precpuStats: DockerCPUStats(
                cpuUsage: DockerCPUUsage(totalUsage: 50, usageInKernelmode: 5, usageInUsermode: 45),
                systemCpuUsage: 500,
                onlineCpus: 8
            ),
            memoryStats: DockerMemoryStats(usage: 1024, limit: 4096, stats: nil),
            networks: ["eth0": DockerNetworkStats(rxBytes: 10, txBytes: 20)]
        )
        let data = try JSONEncoder().encode(stats)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The docker CLI reads these exact snake_case keys.
        XCTAssertNotNil(json["cpu_stats"])
        XCTAssertNotNil(json["precpu_stats"])
        XCTAssertNotNil(json["memory_stats"])
        XCTAssertNotNil(json["pids_stats"])
        XCTAssertNotNil(json["networks"])
        XCTAssertEqual((json["id"] as? String), "ctr")
    }

    // MARK: - exec session registry

    func testExecSessionLifecycleStates() async {
        let registry = ExecSessionRegistry()
        let request = DockerExecCreateRequest(
            cmd: ["sh", "-c", "ls"],
            env: nil,
            workingDir: nil,
            user: nil,
            tty: true,
            attachStdin: false,
            attachStdout: true,
            attachStderr: true,
            detachKeys: nil,
            privileged: nil
        )
        let id = await registry.create(containerID: "ctr", request: request)

        let created = await registry.inspect(id: id)
        XCTAssertEqual(created?.running, false)
        XCTAssertNil(created?.exitCode)
        XCTAssertEqual(created?.processConfig?.tty, true)

        await registry.markStarted(id: id)
        let running = await registry.inspect(id: id)
        XCTAssertEqual(running?.running, true)

        await registry.markFinished(id: id, exitCode: 3)
        let finished = await registry.inspect(id: id)
        XCTAssertEqual(finished?.running, false)
        XCTAssertEqual(finished?.exitCode, 3)

        await registry.remove(id: id)
        let removed = await registry.inspect(id: id)
        XCTAssertNil(removed)
    }

    // MARK: - exec pump frame encoding

    func testServerStdcopyFrameDataEncoding() {
        let chunk = ExecPump.TaggedChunk(stream: .stderr, data: Data([0xAA, 0xBB]))
        let frame = DockerAPIServer.stdcopyFrame(chunk)
        XCTAssertEqual(Array(frame.prefix(4)), [2, 0, 0, 0], "stream byte + padding")
        XCTAssertEqual(Array(frame.dropFirst(4).prefix(4)), [0, 0, 0, 2], "big-endian length")
        XCTAssertEqual(Array(frame.dropFirst(8)), [0xAA, 0xBB])
    }
}
