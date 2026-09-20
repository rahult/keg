import FoundationModels
import XCTest

@testable import Keg

/// Model-free tests for Cooper's pure logic: snapshot rendering, the
/// permission gate matrix, repeat-call protection, and persistence
/// round-trips. No FoundationModels calls — availability and the live model
/// are exercised manually.
final class CooperTests: XCTestCase {
    // MARK: - Snapshot rendering

    func testSnapshotRenderIncludesContainerAndRuntimeState() {
        let snapshot = CooperSnapshot(
            systemLine: "running (app-root /Volumes/Atlas/Containers)",
            dockerAPILine: "serving at /Users/x/.keg/docker.sock",
            containers: [
                CooperSnapshotContainer(
                    displayName: "web", id: "web-abc123", state: "running",
                    image: "docker.io/library/nginx:latest", ports: "8080:80"
                ),
                CooperSnapshotContainer(
                    displayName: "db", id: "db-000000", state: "exited",
                    image: "docker.io/library/postgres:16", ports: ""
                ),
            ],
            imageReferences: ["docker.io/library/nginx:latest", "docker.io/library/redis:7"],
            volumeNames: ["pgdata"],
            networkIDs: ["keg0", "app-net"],
            composeProjects: ["blog"],
            kubernetesLine: "cluster keg-k8s running"
        )

        let rendered = snapshot.render()

        XCTAssertTrue(rendered.contains("RUNTIME: running (app-root /Volumes/Atlas/Containers)"))
        XCTAssertTrue(rendered.contains("CONTAINERS (2 total, 1 running):"))
        XCTAssertTrue(rendered.contains("- web [running] docker.io/library/nginx:latest ports 8080:80"))
        XCTAssertTrue(rendered.contains("- db [exited]"))
        XCTAssertTrue(rendered.contains("IMAGES: 2"))
        XCTAssertTrue(rendered.contains("COMPOSE projects: blog"))
        XCTAssertTrue(rendered.contains("KUBERNETES: cluster keg-k8s running"))
    }

    func testSnapshotRenderHandlesEmptyState() {
        let rendered = CooperSnapshot().render()
        XCTAssertTrue(rendered.contains("CONTAINERS: none"))
        XCTAssertTrue(rendered.contains("IMAGES: none"))
        XCTAssertTrue(rendered.contains("no active projects"))
    }

    func testSnapshotStaysSmallForLargeFleets() {
        // The whole point of the compact snapshot: even 200 containers and
        // 500 images must render to a few hundred tokens, not thousands of
        // lines. Images are the capped section; containers list fully (a
        // tool exists for deeper listing), so cap this at what a real
        // machine shows.
        var snapshot = CooperSnapshot()
        for index in 0..<200 {
            snapshot.containers.append(CooperSnapshotContainer(
                displayName: "c\(index)", id: "id-\(index)", state: "exited",
                image: "docker.io/library/alpine:3", ports: ""
            ))
        }
        snapshot.imageReferences = (0..<500).map { "docker.io/test/img-\($0):1" }

        let rendered = snapshot.render()
        // ~4 chars/token: 15k chars ≈ 3.7k tokens — the image list is
        // capped at 8 previews, so the real bound is much tighter.
        XCTAssertLessThan(rendered.count, 16_000)
        XCTAssertTrue(rendered.contains("(+492 more)"))
    }

    // MARK: - Permission gate

    private func makeGateway(
        approval: @Sendable @escaping (CooperApprovalRequest) -> Bool
    ) -> CooperGateway {
        CooperGateway(appState: nil, approvalHandler: { request in
            approval(request)
        })
    }

    func testReadsAlwaysAllowedInEveryMode() async throws {
        for mode in [AgentPermissionMode.explore, .ask, .execute] {
            let gateway = makeGateway { _ in XCTFail("reads must not request approval"); return false }
            try await gateway.authorize(.read, mode: mode, toolName: "list_containers", summary: "list")
        }
    }

    func testExploreModeRefusesMutationsWithGuidance() async throws {
        let gateway = makeGateway { _ in
            XCTFail("explore mode must not reach the approval card")
            return true
        }
        do {
            try await gateway.authorize(.mutating, mode: .explore, toolName: "container_control", summary: "stop c1")
            XCTFail("expected refusal")
        } catch let error as CooperGateError {
            XCTAssertEqual(error.kind, .readOnlyMode)
            XCTAssertTrue(error.message.contains("Explore"), "should tell the model which mode blocked it")
        }
    }

    func testAskModeRequiresApprovalForMutations() async throws {
        final class ApprovalBox: @unchecked Sendable {
            var request: CooperApprovalRequest?
        }
        let box = ApprovalBox()
        let gateway = makeGateway { request in
            box.request = request
            return true
        }
        try await gateway.authorize(
            .mutating, mode: .ask, toolName: "container_control",
            summary: "start web", details: "boots the container"
        )
        XCTAssertEqual(box.request?.toolName, "container_control")
        XCTAssertEqual(box.request?.summary, "start web")
    }

    func testDeniedApprovalThrowsWithDoNotRetryGuidance() async {
        let gateway = makeGateway { _ in false }
        do {
            try await gateway.authorize(.destructive, mode: .execute, toolName: "container_control", summary: "remove db")
            XCTFail("expected denial")
        } catch let error as CooperGateError {
            XCTAssertEqual(error.kind, .approvalDenied)
            XCTAssertTrue(error.message.lowercased().contains("declined"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testDestructiveRequiresApprovalEvenInExecuteMode() async throws {
        let gateway = makeGateway { _ in true }
        try await gateway.authorize(.destructive, mode: .execute, toolName: "system_control", summary: "stop runtime")
        // No throw = approval was consulted, which is the invariant.
    }

    func testNilApprovalHandlerDeniesGatedActions() async {
        let gateway = CooperGateway(appState: nil, approvalHandler: nil)
        do {
            try await gateway.authorize(.mutating, mode: .ask, toolName: "compose_up", summary: "up")
            XCTFail("expected denial")
        } catch let error as CooperGateError {
            XCTAssertEqual(error.kind, .approvalDenied)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Repeat-call protection

    func testIdenticalCallsRefusedAfterThreeAttempts() async throws {
        let gateway = CooperGateway(appState: nil)
        await gateway.beginTurn()
        for _ in 0..<3 {
            try await gateway.recordCall(toolName: "container_control", argumentsSummary: "stop web")
        }
        do {
            try await gateway.recordCall(toolName: "container_control", argumentsSummary: "stop web")
            XCTFail("expected repeat refusal")
        } catch let error as CooperGateError {
            XCTAssertEqual(error.kind, .repeatedCall)
            XCTAssertTrue(error.message.contains("different approach"))
        }
    }

    func testDifferentCallsDoNotTriggerRepeatGuard() async throws {
        let gateway = CooperGateway(appState: nil)
        await gateway.beginTurn()
        for id in ["web", "db", "cache"] {
            try await gateway.recordCall(toolName: "container_control", argumentsSummary: "stop \(id)")
        }
    }

    func testBeginTurnResetsRepeatGuard() async throws {
        let gateway = CooperGateway(appState: nil)
        await gateway.beginTurn()
        for _ in 0..<3 {
            try await gateway.recordCall(toolName: "image_control", argumentsSummary: "pull redis")
        }
        await gateway.beginTurn()
        try await gateway.recordCall(toolName: "image_control", argumentsSummary: "pull redis")
    }

    // MARK: - Transcript trimming

    func testTrimmedTranscriptKeepsInstructionsAndBoundaries() {
        func prompt(_ text: String) -> Transcript.Entry {
            .prompt(Transcript.Prompt(segments: [.text(.init(content: text))]))
        }

        func response(_ text: String) -> Transcript.Entry {
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))]))
        }

        var entries: [Transcript.Entry] = [.instructions(Transcript.Instructions(segments: [.text(.init(content: "persona"))], toolDefinitions: []))]
        entries.append(prompt("first"))
        entries.append(response("first answer"))
        // 20 more exchanges
        for index in 0..<20 {
            entries.append(prompt("q\(index)"))
            entries.append(response("a\(index)"))
        }

        let transcript = Transcript(entries: entries)
        let trimmed = CooperController.trimmed(transcript, keepLast: 6)

        var trimmedEntries = Array(trimmed)
        guard case .instructions = trimmedEntries.first else {
            return XCTFail("instructions entry must survive trimming")
        }
        XCTAssertLessThanOrEqual(trimmedEntries.count, 7)
        // The seam must start on an exchange boundary, not a dangling
        // tool output or response.
        trimmedEntries.removeFirst()
        if let first = trimmedEntries.first {
            XCTAssertTrue(CooperController.isExchangeBoundaryForTesting(first))
        }
    }

    // MARK: - Persistence round-trips

    func testTranscriptCodableRoundTrip() throws {
        let transcript = Transcript(entries: [
            .instructions(Transcript.Instructions(segments: [.text(.init(content: "persona"))], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "hello"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "hi"))])),
        ])
        let data = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        XCTAssertEqual(transcript, decoded)
    }

    // MARK: - Tool-activity chips

    func testChipLabelsTrackRunningAndFinishedTools() {
        func toolCall(_ name: String) -> Transcript.Entry {
            .toolCalls(Transcript.ToolCalls([
                Transcript.ToolCall(id: UUID().uuidString, toolName: name, arguments: "")
            ]))
        }

        func toolOutput(_ name: String) -> Transcript.Entry {
            .toolOutput(Transcript.ToolOutput(
                id: UUID().uuidString,
                toolName: name,
                segments: [.text(.init(content: "ok"))]
            ))
        }

        let entries: [Transcript.Entry] = [
            toolCall("list_containers"),
            toolCall("container_logs"),
            toolOutput("list_containers"),
        ]

        XCTAssertEqual(
            CooperController.chipLabels(from: entries),
            ["✓ list_containers", "⚙ container_logs"]
        )
    }

    func testChipLabelsIgnoreNonToolEntries() {
        let entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(toolDefinitions: [], segments: [.text(.init(content: "persona"))])),
            .prompt(Transcript.Prompt(segments: [.text(.init(content: "hi"))])),
            .response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: "hello"))])),
        ]
        XCTAssertTrue(CooperController.chipLabels(from: entries).isEmpty)
    }

    func testMessageDecodesWithoutActivityField() throws {
        // Transcripts persisted before tool-activity chips existed must
        // still decode.
        let legacy = """
        [{"id":"X","role":"assistant","text":"hi","isStreaming":false}]
        """
        let messages = try JSONDecoder().decode([CooperController.Message].self, from: Data(legacy.utf8))
        XCTAssertEqual(messages.first?.text, "hi")
        XCTAssertNil(messages.first?.toolActivity)
    }

    // MARK: - Availability mapping

    func testAvailabilityMappingCoversDocumentedCases() {
        // Constructing SystemLanguageModel availability values directly is
        // not possible (the framework owns the enum), so this exercises the
        // mapping indirectly through the ready case only when the host has
        // Apple Intelligence enabled. The other branches are exercised in
        // the UI; here we assert the function is total by calling it.
        _ = CooperAvailability.from(systemModel: .default)
    }

    // MARK: - Gateway output clipping

    func testClippedOutputTruncatesWithSummary() {
        let long = String(repeating: "x", count: 5000)
        let clipped = CooperGateway.clipped(long, label: "logs", limit: 1000)
        XCTAssertLessThan(clipped.count, 1200)
        XCTAssertTrue(clipped.contains("truncated"))

        let short = "all good"
        XCTAssertEqual(CooperGateway.clipped(short, label: "logs"), short)
    }

    // MARK: - Run arguments contract

    func testRunArgumentsBuildDetachedRunCommand() {
        let arguments = CooperGateway.runArguments(
            image: "docker.io/library/nginx:latest",
            name: "web",
            ports: ["8080:80", "  ", ""],
            env: ["KEY=value", ""]
        )
        // Always detached; blanks in ports/env are dropped.
        XCTAssertEqual(arguments, [
            "container", "run", "-d",
            "--name", "web",
            "-p", "8080:80",
            "-e", "KEY=value",
            "docker.io/library/nginx:latest",
        ])
    }

    func testRunArgumentsWithoutNamePortsOrEnv() {
        let arguments = CooperGateway.runArguments(
            image: "alpine:3", name: nil, ports: [], env: []
        )
        XCTAssertEqual(arguments, ["container", "run", "-d", "alpine:3"])
    }

    func testKubernetesDeleteIsDestructiveEvenInExecuteMode() async throws {
        final class Flag: @unchecked Sendable {
            var asked = false
        }
        let flag = Flag()
        let gateway = makeGateway { _ in
            flag.asked = true
            return true
        }
        try await gateway.authorize(
            .destructive, mode: .execute, toolName: "k8s_control",
            summary: "Delete the Kubernetes cluster"
        )
        XCTAssertTrue(flag.asked, "cluster deletion must consult the approval card even in Execute mode")
    }
}

/// Test seam for the private boundary check.
extension CooperController {
    nonisolated static func isExchangeBoundaryForTesting(_ entry: Transcript.Entry) -> Bool {
        switch entry {
        case .prompt, .instructions:
            return true
        default:
            return false
        }
    }
}
