import XCTest
@testable import KegCLICore

final class KegSandboxTests: XCTestCase {

    // MARK: - Naming

    func testSlugSanitization() {
        XCTAssertEqual(KegSandboxNaming.slug("MyApp"), "myapp")
        XCTAssertEqual(KegSandboxNaming.slug("My App_2.0"), "my-app-2-0")
        XCTAssertEqual(KegSandboxNaming.slug("  spaced  out  "), "spaced-out")
        XCTAssertEqual(KegSandboxNaming.slug("already-good-123"), "already-good-123")
        // Long names truncate to the Docker 63-char budget INCLUDING the prefix.
        let long = KegSandboxNaming.slug(String(repeating: "a", count: 100))
        XCTAssertEqual(long.count, 63 - KegSandboxConfig.namePrefix.count)
        XCTAssertTrue(KegSandboxNaming.containerName(dir: URL(filePath: "/tmp/" + String(repeating: "A", count: 100)))
            .hasPrefix(KegSandboxConfig.namePrefix))
    }

    func testContainerNameFromDir() {
        XCTAssertEqual(
            KegSandboxNaming.containerName(dir: URL(filePath: "/Users/x/Code/My App")),
            "kegsandbox-my-app"
        )
        // Missing/empty basenames (root, ".") fall back to "work".
        XCTAssertEqual(KegSandboxNaming.containerName(dir: URL(filePath: "/")), "kegsandbox-work")
        XCTAssertEqual(KegSandboxNaming.containerName(dir: URL(filePath: "/tmp/...")), "kegsandbox-work")
    }

    func testNameResolutionAcceptsShortOrFull() {
        let existing = ["kegsandbox-todo", "kegsandbox-blog-api"]
        XCTAssertEqual(KegSandboxNaming.resolve("todo", existingNames: existing), "kegsandbox-todo")
        XCTAssertEqual(KegSandboxNaming.resolve("kegsandbox-todo", existingNames: existing), "kegsandbox-todo")
        XCTAssertEqual(KegSandboxNaming.resolve("blog-api", existingNames: existing), "kegsandbox-blog-api")
        XCTAssertNil(KegSandboxNaming.resolve("nope", existingNames: existing))
        XCTAssertNil(KegSandboxNaming.resolve("todo", existingNames: []))
    }

    // MARK: - Env parsing

    func testEnvKeyValuePassesThrough() throws {
        let resolved = try KegSandboxEnv.resolve(["A=1", "B=two words", "EMPTY="], environment: [:])
        XCTAssertEqual(resolved, ["A=1", "B=two words", "EMPTY="])
    }

    func testEnvBareKeyInheritsFromProcessEnv() throws {
        let resolved = try KegSandboxEnv.resolve(["ANTHROPIC_API_KEY"], environment: ["ANTHROPIC_API_KEY": "sk-test"])
        XCTAssertEqual(resolved, ["ANTHROPIC_API_KEY=sk-test"])
    }

    func testEnvBareKeyMissingIsClearError() {
        XCTAssertThrowsError(try KegSandboxEnv.resolve(["NO_SUCH_KEY"], environment: [:])) { error in
            let description = (error as? KegSandboxError).map(\.description) ?? "\(error)"
            XCTAssertTrue(description.contains("NO_SUCH_KEY"), "error must name the missing key: \(description)")
            XCTAssertTrue(description.contains("--env"), "error must hint at the flag: \(description)")
        }
    }

    func testEnvRejectsEmptyKey() {
        XCTAssertThrowsError(try KegSandboxEnv.resolve(["=value"], environment: [:]))
        XCTAssertThrowsError(try KegSandboxEnv.resolve([""], environment: [:]))
    }

    // MARK: - Run plan

    func testRunPlan() {
        XCTAssertEqual(KegSandboxPlan.plan(exists: true, running: true), .execRunning)
        XCTAssertEqual(KegSandboxPlan.plan(exists: true, running: false), .startThenExec)
        XCTAssertEqual(KegSandboxPlan.plan(exists: false, running: false), .createStartExec)
    }

    // MARK: - Argument grammar

    func testHarnessConsumesRestOfArgv() throws {
        let options = try KegSandboxParser.parseRun(["--dir", "/x", "--harness", "claude", "--model", "opus", "--", "weird"])
        XCTAssertEqual(options.dir, "/x")
        XCTAssertEqual(options.harness, ["claude", "--model", "opus", "weird"], "--harness consumes everything after it; one bare -- separator is dropped")
    }

    func testHarnessStripsOnlyFirstSeparator() throws {
        let stripped = try KegSandboxParser.parseRun(["--harness", "claude", "--", "--model", "x"])
        XCTAssertEqual(stripped.harness, ["claude", "--model", "x"])
        let laterKept = try KegSandboxParser.parseRun(["--harness", "claude", "--model", "x", "--"])
        XCTAssertEqual(laterKept.harness, ["claude", "--model", "x"], "a trailing lone -- is also just a separator")
    }

    func testDefaultHarnessIsPi() throws {
        XCTAssertEqual(try KegSandboxParser.parseRun([]).harness, ["pi"])
        XCTAssertEqual(try KegSandboxParser.parseRun(["--keep"]).harness, ["pi"])
        XCTAssertEqual(try KegSandboxParser.parseRun(["--harness"]).harness, ["pi"], "empty --harness falls back to pi")
    }

    func testParseRunCollectsOptions() throws {
        let options = try KegSandboxParser.parseRun([
            "--dir", "/repo", "--name", "mine", "--image", "alpine:3",
            "--env", "A=1", "-e", "B", "--keep",
        ])
        XCTAssertEqual(options.dir, "/repo")
        XCTAssertEqual(options.name, "mine")
        XCTAssertEqual(options.image, "alpine:3")
        XCTAssertEqual(options.envSpecs, ["A=1", "B"])
        XCTAssertTrue(options.keep)
    }

    func testParseRunRejectsUnknownAndStrayOperands() {
        XCTAssertThrowsError(try KegSandboxParser.parseRun(["--bogus"]))
        XCTAssertThrowsError(try KegSandboxParser.parseRun(["pi"]), "a bare harness without --harness must not silently work")
        XCTAssertThrowsError(try KegSandboxParser.parseRun(["--dir"]))
    }

    // MARK: - Create request contract (wire shape)

    func testCreateRequestWireShape() throws {
        let request = KegSandboxContainers.createRequest(
            image: KegSandboxConfig.defaultImage,
            name: "kegsandbox-todo",
            dir: "/Users/x/Code/todo",
            harness: ["pi"],
            env: ["A=1"]
        )
        XCTAssertEqual(request.cmd, ["sleep", "infinity"])
        XCTAssertEqual(request.env, ["A=1"])
        XCTAssertEqual(request.labels[KegSandboxConfig.sandboxLabel], "true")
        XCTAssertEqual(request.labels[KegSandboxConfig.dirLabel], "/Users/x/Code/todo")
        XCTAssertEqual(request.labels[KegSandboxConfig.harnessLabel], "pi")
        XCTAssertEqual(request.openStdin, true)
        XCTAssertEqual(request.stdinOnce, true)
        XCTAssertEqual(request.tty, true)
        XCTAssertEqual(request.platform, "linux/arm64")
        XCTAssertEqual(request.hostConfig.binds, ["/Users/x/Code/todo:/work"])
        XCTAssertTrue(request.hostConfig.portBindings.isEmpty, "sandboxes publish no ports")

        // The JSON must match what Keg's Docker API bridge decodes.
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["Image"] as? String, KegSandboxConfig.defaultImage)
        XCTAssertEqual(object["OpenStdin"] as? Bool, true)
        XCTAssertEqual(object["StdinOnce"] as? Bool, true)
        XCTAssertEqual(object["Tty"] as? Bool, true)
        XCTAssertEqual(object["Cmd"] as? [String], ["sleep", "infinity"])
        let labels = try XCTUnwrap(object["Labels"] as? [String: Any])
        XCTAssertEqual(labels["dev.rahult.keg.sandbox"] as? String, "true")
        let hostConfig = try XCTUnwrap(object["HostConfig"] as? [String: Any])
        XCTAssertEqual(hostConfig["Binds"] as? [String], ["/Users/x/Code/todo:/work"])
        let portBindings = try XCTUnwrap(hostConfig["PortBindings"] as? [String: Any])
        XCTAssertTrue(portBindings.isEmpty)
    }

    func testCreateRequestHarnessLabelJoinsArgs() {
        let request = KegSandboxContainers.createRequest(
            image: "x", name: "n", dir: "/d", harness: ["claude", "--model", "opus"], env: []
        )
        XCTAssertEqual(request.labels[KegSandboxConfig.harnessLabel], "claude --model opus")
    }

    // MARK: - Exec argv builder

    func testExecArgvTTY() {
        let argv = KegSandboxExec.argv(
            cli: "/opt/homebrew/bin/container",
            isTTY: true,
            env: ["A=1", "B=two"],
            name: "kegsandbox-todo",
            harness: ["pi"]
        )
        XCTAssertEqual(argv, [
            "/opt/homebrew/bin/container", "exec", "-it", "-w", "/work",
            "-e", "A=1", "-e", "B=two",
            "kegsandbox-todo", "pi",
        ])
    }

    func testExecArgvPiped() {
        let argv = KegSandboxExec.argv(
            cli: "/usr/local/bin/container",
            isTTY: false,
            env: [],
            name: "kegsandbox-todo",
            harness: ["sh", "-c", "echo hi"]
        )
        XCTAssertEqual(argv, [
            "/usr/local/bin/container", "exec", "-i", "-w", "/work",
            "kegsandbox-todo", "sh", "-c", "echo hi",
        ])
    }

    // MARK: - Swallow-proof create (known DockerHijackHTTPChannel issue)

    func testRecoveryDecisionAdoptsOnMatch() {
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .matching, attemptsMade: 0),
            .adopt
        )
        // Adoption wins even when the retry budget is spent.
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .matching, attemptsMade: 5),
            .adopt
        )
    }

    func testRecoveryDecisionRetriesMissingThenFails() {
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .missing, attemptsMade: 0),
            .retry,
            "first lost response retries once"
        )
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .missing, attemptsMade: 1),
            .fail,
            "retry budget spent — fail with the original error"
        )
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .missing, attemptsMade: 0, maxRetries: 2),
            .retry
        )
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .missing, attemptsMade: 2, maxRetries: 2),
            .fail
        )
    }

    func testRecoveryDecisionNeverAdoptsMismatched() {
        // A same-name container that isn't ours must not be adopted OR
        // blind-retried over — fail immediately.
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .mismatched(reason: "x"), attemptsMade: 0),
            .fail
        )
        XCTAssertEqual(
            KegSandboxRecoveredCreate.decision(verification: .mismatched(reason: "x"), attemptsMade: 0, maxRetries: 5),
            .fail
        )
    }

    func testVerifyMatchesLandedCreate() {
        let inspect = CLIContainerInspect(
            id: "abc",
            state: .init(status: "running", running: true),
            labels: [KegSandboxConfig.sandboxLabel: "true"],
            config: .init(image: KegSandboxConfig.defaultImage, labels: nil)
        )
        XCTAssertEqual(
            KegSandboxRecoveredCreate.verify(inspect: inspect, expectedImage: KegSandboxConfig.defaultImage),
            .matching
        )
    }

    func testVerifyRejectsForeignContainers() {
        // Same name, no sandbox label — refuse.
        let unlabeled = CLIContainerInspect(
            id: "abc",
            state: .init(status: "running", running: true),
            labels: [:],
            config: .init(image: KegSandboxConfig.defaultImage, labels: nil)
        )
        if case .mismatched = KegSandboxRecoveredCreate.verify(
            inspect: unlabeled, expectedImage: KegSandboxConfig.defaultImage
        ) {} else { XCTFail("unlabeled same-name container must be mismatched") }

        // Sandbox label but a different image — refuse.
        let wrongImage = CLIContainerInspect(
            id: "abc",
            state: .init(status: "running", running: true),
            labels: [KegSandboxConfig.sandboxLabel: "true"],
            config: .init(image: "alpine:3", labels: nil)
        )
        if case .mismatched = KegSandboxRecoveredCreate.verify(
            inspect: wrongImage, expectedImage: KegSandboxConfig.defaultImage
        ) {} else { XCTFail("different-image container must be mismatched") }

        // Label present but image unknown — refuse (strict adoption only).
        let unknownImage = CLIContainerInspect(
            id: "abc",
            state: .init(status: "running", running: true),
            labels: [KegSandboxConfig.sandboxLabel: "true"],
            config: .init(image: nil, labels: nil)
        )
        if case .mismatched = KegSandboxRecoveredCreate.verify(
            inspect: unknownImage, expectedImage: KegSandboxConfig.defaultImage
        ) {} else { XCTFail("unknown-image container must be mismatched") }

        // Absent (or unreachable inspect) — missing, so the caller retries.
        XCTAssertEqual(
            KegSandboxRecoveredCreate.verify(inspect: nil, expectedImage: KegSandboxConfig.defaultImage),
            .missing
        )
    }

    // MARK: - Re-exec attach helpers

    func testExecEnvironmentAppliesAppRootPin() {
        let pinned = KegSandboxRuntime.execEnvironment(
            processEnvironment: ["PATH": "/usr/bin", "HOME": "/Users/x"],
            pin: ("CONTAINER_APP_ROOT", "/Volumes/Atlas/Containers")
        )
        XCTAssertEqual(pinned["CONTAINER_APP_ROOT"], "/Volumes/Atlas/Containers")
        XCTAssertEqual(pinned["PATH"], "/usr/bin", "process env is preserved")
        XCTAssertEqual(pinned["HOME"], "/Users/x")

        let unpinned = KegSandboxRuntime.execEnvironment(
            processEnvironment: ["PATH": "/usr/bin"],
            pin: nil
        )
        XCTAssertEqual(unpinned, ["PATH": "/usr/bin"], "no pin → env unchanged")
    }

    func testEnvironmentPairsAreSortedKeyValueStrings() {
        XCTAssertEqual(
            KegSandboxRuntime.environmentPairs(["B": "2", "A": "1", "EMPTY": ""]),
            ["A=1", "B=2", "EMPTY="]
        )
    }

    // MARK: - Inspect labels (ls DIR column)

    func testInspectDecodesConfigLabelsWhenTopLevelLabelsAbsent() throws {
        // The bridge's inspect shape as seen live: labels under
        // Config.Labels only, no top-level Labels key.
        let json = """
        {
          "Id": "abc",
          "State": {"Status": "running", "Running": true},
          "Config": {
            "Image": "keg-sandbox:latest",
            "Labels": {"dev.rahult.keg.sandbox": "true", "dev.rahult.keg.sandbox.dir": "/Users/x/Code/todo"}
          }
        }
        """.data(using: .utf8)!
        let inspect = try JSONDecoder().decode(CLIContainerInspect.self, from: json)
        XCTAssertNil(inspect.labels)
        let labels = inspect.effectiveLabels
        XCTAssertEqual(labels[KegSandboxConfig.sandboxLabel], "true")
        XCTAssertEqual(labels[KegSandboxConfig.dirLabel], "/Users/x/Code/todo")
    }

    func testInspectEffectiveLabelsMergesWithTopLevelWinning() throws {
        let json = """
        {
          "Id": "abc",
          "State": {"Status": "running", "Running": true},
          "Labels": {"dev.rahult.keg.sandbox.dir": "/top-level", "top": "1"},
          "Config": {
            "Image": "keg-sandbox:latest",
            "Labels": {"dev.rahult.keg.sandbox.dir": "/config-level", "cfg": "2"}
          }
        }
        """.data(using: .utf8)!
        let inspect = try JSONDecoder().decode(CLIContainerInspect.self, from: json)
        let labels = inspect.effectiveLabels
        XCTAssertEqual(labels["dev.rahult.keg.sandbox.dir"], "/top-level", "top-level Labels wins")
        XCTAssertEqual(labels["top"], "1")
        XCTAssertEqual(labels["cfg"], "2", "Config.Labels fills the gaps")
    }

    // MARK: - Bundled Dockerfile

    func testBundledDockerfileIsFindable() throws {
        // In the test bundle the source-tree walk-up finds the repo file;
        // installed builds find it in Keg_KegCLICore.bundle. Either way the
        // lookup must succeed and pin the base image.
        let url = try XCTUnwrap(SandboxImageBuilder.dockerfileURL(), "sandbox Dockerfile must be locatable")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("FROM node:22-alpine"), text)
        XCTAssertTrue(text.contains("@mariozechner/pi-coding-agent"), text)
    }
}
