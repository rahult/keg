import XCTest
@testable import Keg

final class ToolExecutorTests: XCTestCase {

    private var tempDir: URL!
    private nonisolated(unsafe) var executor: ToolExecutor!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolExecutorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        executor = ToolExecutor(workingDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helper

    private func execute(_ name: String, _ args: [String: Any] = [:]) async throws -> ToolExecutor.ToolOutput {
        nonisolated(unsafe) let input = ToolExecutor.ToolInput(name: name, arguments: args)
        return try await executor.execute(input)
    }

    // MARK: - Bash Tool

    func testBashEchoHello() async throws {
        let output = try await execute("bash", ["command": "echo hello"])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("hello"))
    }

    func testBashTimeout() async throws {
        let output = try await execute("bash", ["command": "sleep 5", "timeout": 1])
        // Process should be terminated; the exit will be non-zero
        XCTAssertTrue(output.isError)
    }

    func testBashMissingCommand() async throws {
        do {
            _ = try await execute("bash", [:])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "command")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testBashNonZeroExitCode() async throws {
        let output = try await execute("bash", ["command": "exit 1"])
        XCTAssertTrue(output.isError)
    }

    // MARK: - Read Tool

    func testReadFileHappyPath() async throws {
        let filePath = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: filePath, atomically: true, encoding: .utf8)

        let output = try await execute("read", ["path": filePath.path])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("Hello, World!"))
    }

    func testReadNonExistentFile() async throws {
        let fakePath = tempDir.appendingPathComponent("does-not-exist.txt").path
        do {
            _ = try await execute("read", ["path": fakePath])
            XCTFail("Expected fileNotFound error")
        } catch let error as ToolExecutorError {
            if case .fileNotFound = error {
                // expected
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testReadMissingPathArgument() async throws {
        do {
            _ = try await execute("read", [:])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "path")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Write Tool

    func testWriteFileHappyPath() async throws {
        let filePath = tempDir.appendingPathComponent("output.txt").path
        let output = try await execute("write", ["path": filePath, "content": "written content"])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("Wrote"))

        let written = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(written, "written content")
    }

    func testWriteMissingArguments() async throws {
        // Missing content
        do {
            _ = try await execute("write", ["path": "/tmp/x.txt"])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "content")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }

        // Missing path
        do {
            _ = try await execute("write", ["content": "hello"])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "path")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Edit Tool

    func testEditHappyPath() async throws {
        let filePath = tempDir.appendingPathComponent("editable.txt")
        try "foo bar baz".write(to: filePath, atomically: true, encoding: .utf8)

        let output = try await execute("edit", [
            "path": filePath.path,
            "old_text": "bar",
            "new_text": "qux"
        ])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("Replaced"))

        let edited = try String(contentsOf: filePath, encoding: .utf8)
        XCTAssertEqual(edited, "foo qux baz")
    }

    func testEditNonMatchingOldString() async throws {
        let filePath = tempDir.appendingPathComponent("editable2.txt")
        try "foo bar baz".write(to: filePath, atomically: true, encoding: .utf8)

        do {
            _ = try await execute("edit", [
                "path": filePath.path,
                "old_text": "nonexistent",
                "new_text": "replacement"
            ])
            XCTFail("Expected textNotFound error")
        } catch let error as ToolExecutorError {
            if case .textNotFound = error {
                // expected
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testEditMissingArguments() async throws {
        do {
            _ = try await execute("edit", [:])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "path")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Glob Tool

    func testGlobHappyPath() async throws {
        // Create files in a subdirectory
        let subDir = tempDir.appendingPathComponent("globtest")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "a".write(to: subDir.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: subDir.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: subDir.appendingPathComponent("three.md"), atomically: true, encoding: .utf8)

        // Non-recursive glob: implementation calls deletingLastPathComponent() on the path,
        // so we pass a path whose parent is the directory containing the files.
        let output = try await execute("glob", [
            "pattern": "*.txt",
            "path": subDir.appendingPathComponent("dummy").path,
            "recursive": false
        ])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("one.txt"))
        XCTAssertTrue(output.content.contains("two.txt"))
        XCTAssertFalse(output.content.contains("three.md"))
    }

    func testGlobNoMatches() async throws {
        let subDir = tempDir.appendingPathComponent("emptyglob")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "a".write(to: subDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let output = try await execute("glob", [
            "pattern": "*.xyz",
            "path": subDir.appendingPathComponent("dummy").path,
            "recursive": false
        ])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("No files matching"))
    }

    // MARK: - Grep Tool

    func testGrepHappyPath() async throws {
        let filePath = tempDir.appendingPathComponent("searchable.txt")
        try "line one\nline two\nline three\n".write(to: filePath, atomically: true, encoding: .utf8)

        let output = try await execute("grep", [
            "path": filePath.path,
            "pattern": "two"
        ])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("two"))
        XCTAssertTrue(output.content.contains("Matches"))
    }

    func testGrepNoMatches() async throws {
        let filePath = tempDir.appendingPathComponent("searchable2.txt")
        try "line one\nline two\n".write(to: filePath, atomically: true, encoding: .utf8)

        let output = try await execute("grep", [
            "path": filePath.path,
            "pattern": "zzz_nonexistent"
        ])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("No matches"))
    }

    func testGrepMissingArguments() async throws {
        // Missing pattern
        do {
            _ = try await execute("grep", ["path": "/tmp/x.txt"])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "pattern")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }

        // Missing path
        do {
            _ = try await execute("grep", ["pattern": "test"])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "path")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Web Fetch Tool

    func testWebFetchMissingURL() async throws {
        do {
            _ = try await execute("web_fetch", [:])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "url")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Web Search Tool

    func testWebSearchMissingQuery() async throws {
        do {
            _ = try await execute("web_search", [:])
            XCTFail("Expected missingArgument error")
        } catch let error as ToolExecutorError {
            if case .missingArgument(let arg) = error {
                XCTAssertEqual(arg, "query")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Unknown Tool

    func testUnknownToolThrows() async throws {
        do {
            _ = try await execute("nonexistent_tool", [:])
            XCTFail("Expected unknownTool error")
        } catch let error as ToolExecutorError {
            if case .unknownTool(let name) = error {
                XCTAssertEqual(name, "nonexistent_tool")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }
}
