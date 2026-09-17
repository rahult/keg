import XCTest
@testable import KegCLICore

/// Unit tests for the keg CLI's core: install-location policy, response
/// parsing, log demuxing, formatting, and socket resolution.
final class KegCLICoreTests: XCTestCase {

    // MARK: - Install locations

    func testPreferredLocationPicksFirstWritableSystemDir() {
        let location = KegCLIInstall.preferredLocation(
            fileExists: { _ in true },
            isWritable: { $0 == "/usr/local/bin" }
        )
        XCTAssertEqual(location?.directory, "/usr/local/bin")
        XCTAssertEqual(location?.needsPATHSetup, false)
    }

    func testPreferredLocationFallsBackToHomebrewPrefix() {
        let location = KegCLIInstall.preferredLocation(
            fileExists: { $0 == "/opt/homebrew/bin" },
            isWritable: { $0 == "/opt/homebrew/bin" }
        )
        XCTAssertEqual(location?.directory, "/opt/homebrew/bin")
    }

    func testPreferredLocationAlwaysWorksWithUserDirectory() {
        // Nothing system-level exists or is writable — the user-level
        // directory must still be offered (it is created on demand).
        let location = KegCLIInstall.preferredLocation(
            fileExists: { _ in false },
            isWritable: { _ in false }
        )
        XCTAssertEqual(location?.directory, KegCLIInstall.userBinDirectory)
        XCTAssertEqual(location?.needsPATHSetup, true)
    }

    func testPathHintOnlyForUserDirectory() {
        let system = KegCLIInstall.Location(directory: "/usr/local/bin", needsPATHSetup: false)
        let user = KegCLIInstall.Location(directory: KegCLIInstall.userBinDirectory, needsPATHSetup: true)
        XCTAssertEqual(KegCLIInstall.pathHint(for: system), "")
        XCTAssertTrue(KegCLIInstall.pathHint(for: user).hasPrefix("export PATH="))
        XCTAssertTrue(KegCLIInstall.pathHint(for: user, shell: "fish").hasPrefix("fish_add_path"))
    }

    func testInstalledLinkFindsExistingCommand() {
        let location = KegCLIInstall.installedLink { $0 == "/opt/homebrew/bin/keg" }
        XCTAssertEqual(location?.directory, "/opt/homebrew/bin")
        XCTAssertNil(KegCLIInstall.installedLink { _ in false })
    }

    func testInstallCreatesReplaceableSymlink() throws {
        let dir = NSTemporaryDirectory() + "keg-cli-tests-\(UUID().uuidString.prefix(6))"
        let binary = dir + "/binary"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        fm.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8))

        let location = KegCLIInstall.Location(directory: dir, needsPATHSetup: false)
        let link = try KegCLIInstall.install(binaryPath: binary, into: location)
        XCTAssertTrue(fm.fileExists(atPath: link))
        // Re-install replaces rather than failing.
        XCTAssertNoThrow(try KegCLIInstall.install(binaryPath: binary, into: location))
        // And a stale FILE (not symlink) at the destination is replaced too.
        try fm.removeItem(atPath: link)
        fm.createFile(atPath: link, contents: nil)
        XCTAssertNoThrow(try KegCLIInstall.install(binaryPath: binary, into: location))
    }

    // MARK: - HTTP response parsing

    private func makeClient() -> UnixSocketHTTPClient {
        UnixSocketHTTPClient(socketPath: "/dev/null")
    }

    func testParseContentLengthResponse() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
        let parsed = try XCTUnwrap(makeClient().dynamicParse(raw))
        XCTAssertEqual(parsed.status, 200)
        XCTAssertEqual(parsed.headers["content-type"], "text/plain")
        XCTAssertEqual(String(data: parsed.bodyData, encoding: .utf8), "hello")
        XCTAssertTrue(parsed.hasCompleteBody)
    }

    func testParseChunkedResponse() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n3;x=1\r\n wo\r\n0\r\n\r\n"
        let parsed = try XCTUnwrap(makeClient().dynamicParse(raw))
        XCTAssertEqual(String(data: parsed.bodyData, encoding: .utf8), "hello wo")
        XCTAssertTrue(parsed.hasCompleteBody)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(makeClient().dynamicParse("not http at all"))
        XCTAssertNil(makeClient().dynamicParse("HTTP/1.1 abc def\r\n\r\n"))
    }

    // MARK: - Log demuxing

    func testDemuxSplitsStreamsAndSkipsHeaders() {
        var framed = Data()
        framed.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 5])
        framed.append(contentsOf: Array("hello".utf8))
        framed.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 3])
        framed.append(contentsOf: Array("err".utf8))

        let output = DockerLogDemuxer.demux(framed)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "hello")
        XCTAssertEqual(String(data: output.stderr, encoding: .utf8), "err")
    }

    func testDemuxToleratesTruncatedFrame() {
        var framed = Data([1, 0, 0, 0, 0, 0, 0, 10])
        framed.append(contentsOf: Array("short".utf8))
        let output = DockerLogDemuxer.demux(framed)
        XCTAssertTrue(output.stdout.isEmpty, "truncated frame should be dropped, not partially read")
    }

    // MARK: - Formatting

    func testTableAlignsColumns() {
        let table = OutputFormatting.table(
            headers: ["NAME", "STATE"],
            rows: [["web", "running"], ["worker-with-a-long-name", "exited"]]
        )
        let lines = table.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4)
        // The state column starts at the same offset in every data row.
        func columnStart(of needle: String, in line: String) -> Int {
            line.range(of: needle)!.lowerBound.utf16Offset(in: line)
        }
        let header = columnStart(of: "STATE", in: lines[0])
        let first = columnStart(of: "running", in: lines[2])
        let second = columnStart(of: "exited", in: lines[3])
        XCTAssertEqual(header, first)
        XCTAssertEqual(first, second)
    }

    func testAgoRendersSensibleUnits() {
        var reference = Date()
        reference.addTimeInterval(-90)
        XCTAssertEqual(OutputFormatting.ago(epochSeconds: Int64(reference.timeIntervalSince1970), from: Date()), "1 minute ago")
        reference = Date()
        reference.addTimeInterval(-3 * 86400 - 100)
        XCTAssertEqual(OutputFormatting.ago(epochSeconds: Int64(reference.timeIntervalSince1970), from: Date()), "3 days ago")
    }

    // MARK: - Socket resolution

    func testResolvePrefersExistingDockerHost() {
        let path = KegSocketResolver.resolve(environment: ["DOCKER_HOST": "unix:///tmp/some.sock", "OTHER": "1"])
        XCTAssertEqual(path, "/tmp/some.sock")
    }

    func testResolveFallsBackToOnDiskCandidates() {
        // The test host's environment may or may not point somewhere; with
        // DOCKER_HOST unset, resolution must return a path only if the
        // candidate exists. Fake existence is not injectable here, so assert
        // the invariant rather than a concrete value.
        let path = KegSocketResolver.resolve(environment: [:])
        if let path {
            XCTAssertTrue(KegSocketResolver.candidates.contains(path))
        }
    }
}

private extension UnixSocketHTTPClient {
    /// Test hook into the internal parser.
    func dynamicParse(_ text: String) -> ParsedResponse? {
        Self.parse(Data(text.utf8))
    }
}
