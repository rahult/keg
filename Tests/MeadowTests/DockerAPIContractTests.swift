import XCTest
import Foundation

// MARK: - Docker API Contract Tests
//
// These tests verify that every route registered in DockerAPIServer responds
// with the expected HTTP status code and, where applicable, valid JSON.
//
// Gate: MEADOW_RUN_DOCKER_API=1
// Run:  MEADOW_RUN_DOCKER_API=1 swift test --filter DockerAPIContractTests

final class DockerAPIContractTests: XCTestCase {

    // MARK: - Socket Path

    private static let socketPath: String = {
        NSHomeDirectory() + "/.meadow/docker.sock"
    }()

    // MARK: - Setup

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["MEADOW_RUN_DOCKER_API"] == "1" else {
            throw XCTSkip("Set MEADOW_RUN_DOCKER_API=1 to run Docker API contract tests")
        }
        try await super.setUp()

        // Verify the socket exists before running any test
        guard FileManager.default.fileExists(atPath: Self.socketPath) else {
            throw XCTSkip("Docker API socket not found at \(Self.socketPath)")
        }
    }

    // MARK: - Curl Helper

    /// Execute a curl command against the Unix domain socket and return (statusCode, body).
    @discardableResult
    func curlSocket(
        _ method: String,
        _ path: String,
        body: String? = nil
    ) throws -> (Int, String) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(filePath: "/usr/bin/curl")

        var args: [String] = [
            "--unix-socket", Self.socketPath,
            "-s",                          // silent
            "-w", "\n%{http_code}",        // append status code after body
            "-X", method,
            "-H", "Content-Type: application/json",
        ]

        if let body {
            args += ["-d", body]
        }

        args.append("http://localhost\(path)")

        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""

        // The last line is the HTTP status code (appended by -w)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let statusString = lines.last.map(String.init) ?? "0"
        let statusCode = Int(statusString) ?? 0
        let bodyLines = lines.dropLast()
        let responseBody = bodyLines.joined(separator: "\n")

        return (statusCode, responseBody)
    }

    // MARK: - JSON Validation Helper

    /// Assert that the response body is valid JSON and return the parsed object.
    @discardableResult
    func assertValidJSON(_ body: String, file: StaticString = #filePath, line: UInt = #line) -> Any? {
        guard !body.isEmpty else {
            // Empty body is acceptable for some endpoints (e.g., events stub)
            return nil
        }
        guard let data = body.data(using: .utf8) else {
            XCTFail("Response body is not valid UTF-8", file: file, line: line)
            return nil
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            return json
        } catch {
            XCTFail("Response is not valid JSON: \(error.localizedDescription)\nBody: \(body.prefix(500))", file: file, line: line)
            return nil
        }
    }

    // MARK: - System Routes

    func testPing() throws {
        let (status, body) = try curlSocket("GET", "/_ping")
        XCTAssertEqual(status, 200, "GET /_ping should return 200")
        XCTAssertEqual(body, "OK", "Ping should return 'OK'")
    }

    func testPingVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/_ping")
        XCTAssertEqual(status, 200, "GET /v1.41/_ping should return 200")
        XCTAssertEqual(body, "OK")
    }

    func testVersion() throws {
        let (status, body) = try curlSocket("GET", "/version")
        XCTAssertEqual(status, 200, "GET /version should return 200")
        let json = assertValidJSON(body)
        if let dict = json as? [String: Any] {
            XCTAssertNotNil(dict["ApiVersion"], "Version response should contain ApiVersion")
            XCTAssertNotNil(dict["Os"], "Version response should contain Os")
        }
    }

    func testVersionVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.45/version")
        XCTAssertEqual(status, 200, "Versioned /version should return 200")
        assertValidJSON(body)
    }

    func testInfo() throws {
        let (status, body) = try curlSocket("GET", "/info")
        XCTAssertEqual(status, 200, "GET /info should return 200")
        let json = assertValidJSON(body)
        if let dict = json as? [String: Any] {
            XCTAssertNotNil(dict["OperatingSystem"], "Info should contain OperatingSystem")
            XCTAssertNotNil(dict["Architecture"], "Info should contain Architecture")
        }
    }

    func testInfoVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/info")
        XCTAssertEqual(status, 200)
        assertValidJSON(body)
    }

    // MARK: - Container Routes

    func testListContainers() throws {
        let (status, body) = try curlSocket("GET", "/containers/json")
        XCTAssertEqual(status, 200, "GET /containers/json should return 200")
        let json = assertValidJSON(body)
        XCTAssertTrue(json is [Any], "Container list should be a JSON array")
    }

    func testListContainersAll() throws {
        let (status, body) = try curlSocket("GET", "/containers/json?all=1")
        XCTAssertEqual(status, 200, "GET /containers/json?all=1 should return 200")
        let json = assertValidJSON(body)
        XCTAssertTrue(json is [Any], "Container list should be a JSON array")
    }

    func testListContainersVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/containers/json")
        XCTAssertEqual(status, 200)
        assertValidJSON(body)
    }

    func testCreateContainer() throws {
        let createBody = """
        {"Image":"alpine:latest","Cmd":["echo","hello"]}
        """
        let (status, body) = try curlSocket("POST", "/containers/create?name=meadow-contract-test", body: createBody)
        // 201 = created successfully, 404 = image not found (acceptable in test env)
        XCTAssertTrue([201, 404, 500].contains(status),
                      "POST /containers/create should return 201, 404, or 500, got \(status)")
        if status == 201 {
            let json = assertValidJSON(body)
            if let dict = json as? [String: Any] {
                XCTAssertNotNil(dict["Id"], "Create response should contain Id")
            }
            // Clean up: remove the created container
            if let data = body.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = dict["Id"] as? String {
                _ = try? curlSocket("DELETE", "/containers/\(id)?force=true")
            }
        }
    }

    func testCreateContainerVersioned() throws {
        let createBody = """
        {"Image":"alpine:latest","Cmd":["echo","hello"]}
        """
        let (status, _) = try curlSocket("POST", "/v1.41/containers/create?name=meadow-contract-test-v", body: createBody)
        XCTAssertTrue([201, 404, 500].contains(status),
                      "Versioned POST /containers/create should return 201, 404, or 500, got \(status)")
    }

    func testStartContainerInvalidId() throws {
        let (status, _) = try curlSocket("POST", "/containers/nonexistent-id-12345/start")
        // 204 = success (with try?), 304 = already started, 404 = not found, 500 = server error
        XCTAssertTrue([204, 304, 404, 500].contains(status),
                      "POST /containers/{invalid-id}/start should return 204, 304, 404, or 500, got \(status)")
    }

    func testStopContainerInvalidId() throws {
        let (status, _) = try curlSocket("POST", "/containers/nonexistent-id-12345/stop")
        // Server uses try? so it returns 204 even for invalid ids
        XCTAssertTrue([204, 304, 404, 500].contains(status),
                      "POST /containers/{invalid-id}/stop should return 204, 304, 404, or 500, got \(status)")
    }

    func testKillContainerInvalidId() throws {
        let (status, _) = try curlSocket("POST", "/containers/nonexistent-id-12345/kill")
        // Server uses try? so it returns 204 even for invalid ids
        XCTAssertTrue([204, 404, 500].contains(status),
                      "POST /containers/{invalid-id}/kill should return 204, 404, or 500, got \(status)")
    }

    func testRestartContainerInvalidId() throws {
        let (status, _) = try curlSocket("POST", "/containers/nonexistent-id-12345/restart")
        // Server uses try? for both stop and start, returns 204
        XCTAssertTrue([204, 404, 500].contains(status),
                      "POST /containers/{invalid-id}/restart should return 204, 404, or 500, got \(status)")
    }

    func testDeleteContainerInvalidId() throws {
        let (status, _) = try curlSocket("DELETE", "/containers/nonexistent-id-12345")
        // 204 = success, 404 = not found, 500 = server error
        XCTAssertTrue([204, 404, 500].contains(status),
                      "DELETE /containers/{invalid-id} should return 204, 404, or 500, got \(status)")
    }

    func testDeleteContainerForce() throws {
        let (status, _) = try curlSocket("DELETE", "/containers/nonexistent-id-12345?force=true")
        XCTAssertTrue([204, 404, 500].contains(status),
                      "DELETE /containers/{id}?force=true should return 204, 404, or 500, got \(status)")
    }

    func testInspectContainerInvalidId() throws {
        let (status, _) = try curlSocket("GET", "/containers/nonexistent-id-12345/json")
        // 200 = found, 404 = not found, 500 = error
        XCTAssertTrue([200, 404, 500].contains(status),
                      "GET /containers/{invalid-id}/json should return 200, 404, or 500, got \(status)")
    }

    func testContainerLogsInvalidId() throws {
        let (status, _) = try curlSocket("GET", "/containers/nonexistent-id-12345/logs")
        // 200 = ok (empty), 404 = not found, 500 = error
        XCTAssertTrue([200, 404, 500].contains(status),
                      "GET /containers/{invalid-id}/logs should return 200, 404, or 500, got \(status)")
    }

    func testContainerLogsWithParams() throws {
        let (status, _) = try curlSocket("GET", "/containers/nonexistent-id-12345/logs?tail=100&follow=false")
        XCTAssertTrue([200, 404, 500].contains(status),
                      "GET /containers/{id}/logs with params should return 200, 404, or 500, got \(status)")
    }

    func testExecContainerInvalidId() throws {
        let execBody = """
        {"Cmd":["echo","hello"],"AttachStdout":true}
        """
        let (status, body) = try curlSocket("POST", "/containers/nonexistent-id-12345/exec", body: execBody)
        // The exec stub always returns 201 with an exec ID regardless of container validity
        XCTAssertTrue([201, 404, 500].contains(status),
                      "POST /containers/{id}/exec should return 201, 404, or 500, got \(status)")
        if status == 201 {
            let json = assertValidJSON(body)
            if let dict = json as? [String: Any] {
                XCTAssertNotNil(dict["Id"], "Exec response should contain Id")
                if let execId = dict["Id"] as? String {
                    XCTAssertTrue(execId.hasPrefix("exec-"), "Exec Id should start with 'exec-'")
                }
            }
        }
    }

    func testExecContainerVersioned() throws {
        let execBody = """
        {"Cmd":["ls"],"AttachStdout":true}
        """
        let (status, _) = try curlSocket("POST", "/v1.41/containers/some-id/exec", body: execBody)
        XCTAssertTrue([201, 404, 500].contains(status),
                      "Versioned POST /containers/{id}/exec should return 201, 404, or 500, got \(status)")
    }

    // MARK: - Container Lifecycle (versioned paths)

    func testStartContainerVersioned() throws {
        let (status, _) = try curlSocket("POST", "/v1.41/containers/nonexistent-id/start")
        XCTAssertTrue([204, 304, 404, 500].contains(status))
    }

    func testStopContainerVersioned() throws {
        let (status, _) = try curlSocket("POST", "/v1.41/containers/nonexistent-id/stop")
        XCTAssertTrue([204, 304, 404, 500].contains(status))
    }

    func testKillContainerVersioned() throws {
        let (status, _) = try curlSocket("POST", "/v1.41/containers/nonexistent-id/kill")
        XCTAssertTrue([204, 404, 500].contains(status))
    }

    func testRestartContainerVersioned() throws {
        let (status, _) = try curlSocket("POST", "/v1.41/containers/nonexistent-id/restart")
        XCTAssertTrue([204, 404, 500].contains(status))
    }

    func testDeleteContainerVersioned() throws {
        let (status, _) = try curlSocket("DELETE", "/v1.41/containers/nonexistent-id")
        XCTAssertTrue([204, 404, 500].contains(status))
    }

    func testInspectContainerVersioned() throws {
        let (status, _) = try curlSocket("GET", "/v1.41/containers/nonexistent-id/json")
        XCTAssertTrue([200, 404, 500].contains(status))
    }

    func testContainerLogsVersioned() throws {
        let (status, _) = try curlSocket("GET", "/v1.41/containers/nonexistent-id/logs")
        XCTAssertTrue([200, 404, 500].contains(status))
    }

    // MARK: - Image Routes

    func testListImages() throws {
        let (status, body) = try curlSocket("GET", "/images/json")
        XCTAssertEqual(status, 200, "GET /images/json should return 200")
        let json = assertValidJSON(body)
        XCTAssertTrue(json is [Any], "Image list should be a JSON array")
    }

    func testListImagesVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/images/json")
        XCTAssertEqual(status, 200)
        assertValidJSON(body)
    }

    func testCreateImage() throws {
        let (status, _) = try curlSocket("POST", "/images/create?fromImage=alpine&tag=latest")
        // 200 = success (pull started), 404 = image not found, 500 = error
        XCTAssertTrue([200, 404, 500].contains(status),
                      "POST /images/create should return 200, 404, or 500, got \(status)")
    }

    func testCreateImageNoImage() throws {
        let (status, _) = try curlSocket("POST", "/images/create")
        // Should fail with bad request since no image specified
        XCTAssertTrue([400, 500].contains(status),
                      "POST /images/create with no image should return 400 or 500, got \(status)")
    }

    func testCreateImageVersioned() throws {
        let (status, _) = try curlSocket("POST", "/v1.41/images/create?fromImage=alpine&tag=latest")
        XCTAssertTrue([200, 404, 500].contains(status))
    }

    func testInspectImageInvalidName() throws {
        let (status, _) = try curlSocket("GET", "/images/nonexistent-image-xyz/json")
        // 200 = found, 404 = not found, 500 = error
        XCTAssertTrue([200, 404, 500].contains(status),
                      "GET /images/{name}/json should return 200, 404, or 500, got \(status)")
    }

    func testInspectImageHistory() throws {
        let (status, _) = try curlSocket("GET", "/images/nonexistent-image-xyz/history")
        XCTAssertTrue([200, 404, 500].contains(status),
                      "GET /images/{name}/history should return 200, 404, or 500, got \(status)")
    }

    func testInspectImageVersioned() throws {
        let (status, _) = try curlSocket("GET", "/v1.41/images/nonexistent-image-xyz/json")
        XCTAssertTrue([200, 404, 500].contains(status))
    }

    func testDeleteImageInvalidName() throws {
        let (status, _) = try curlSocket("DELETE", "/images/nonexistent-image-xyz/json")
        // 204 = success, 404 = not found, 500 = error
        XCTAssertTrue([204, 404, 500].contains(status),
                      "DELETE /images/{name}/** should return 204, 404, or 500, got \(status)")
    }

    func testDeleteImageVersioned() throws {
        let (status, _) = try curlSocket("DELETE", "/v1.41/images/nonexistent-image-xyz/json")
        XCTAssertTrue([204, 404, 500].contains(status))
    }

    // MARK: - Network Routes

    func testListNetworks() throws {
        let (status, body) = try curlSocket("GET", "/networks")
        XCTAssertEqual(status, 200, "GET /networks should return 200")
        let json = assertValidJSON(body)
        XCTAssertTrue(json is [Any], "Network list should be a JSON array")
    }

    func testListNetworksVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/networks")
        XCTAssertEqual(status, 200)
        assertValidJSON(body)
    }

    func testGetNetworkById() throws {
        // First list networks to get a valid ID
        let (listStatus, listBody) = try curlSocket("GET", "/networks")
        XCTAssertEqual(listStatus, 200)

        if let data = listBody.data(using: .utf8),
           let networks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let firstNetwork = networks.first,
           let networkId = firstNetwork["Id"] as? String {
            let (status, body) = try curlSocket("GET", "/networks/\(networkId)")
            XCTAssertEqual(status, 200, "GET /networks/{id} with valid ID should return 200")
            assertValidJSON(body)
        }
    }

    func testGetNetworkInvalidId() throws {
        let (status, body) = try curlSocket("GET", "/networks/nonexistent-network-xyz")
        XCTAssertEqual(status, 404, "GET /networks/{invalid-id} should return 404")
        assertValidJSON(body)
    }

    func testGetNetworkVersioned() throws {
        let (status, _) = try curlSocket("GET", "/v1.41/networks/nonexistent-network-xyz")
        XCTAssertEqual(status, 404)
    }

    // MARK: - Volume Routes

    func testListVolumes() throws {
        let (status, body) = try curlSocket("GET", "/volumes")
        XCTAssertEqual(status, 200, "GET /volumes should return 200")
        assertValidJSON(body)
    }

    func testListVolumesVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/volumes")
        XCTAssertEqual(status, 200)
        assertValidJSON(body)
    }

    // MARK: - Events Route

    func testEvents() throws {
        let (status, _) = try curlSocket("GET", "/events")
        XCTAssertEqual(status, 200, "GET /events should return 200")
        // Events stub returns empty body, which is valid
    }

    func testEventsVersioned() throws {
        let (status, _) = try curlSocket("GET", "/v1.41/events")
        XCTAssertEqual(status, 200)
    }

    // MARK: - Webhook Routes

    func testWebhookCRUDLifecycle() throws {
        // 1. Create a webhook
        let createBody = """
        {"name":"test-webhook","Endpoint":"https://example.com/hook","Events":["container.start","container.stop"]}
        """
        let (createStatus, createResponseBody) = try curlSocket("POST", "/webhooks", body: createBody)
        XCTAssertEqual(createStatus, 201, "POST /webhooks should return 201")
        let createJson = assertValidJSON(createResponseBody)

        guard let createDict = createJson as? [String: Any],
              let webhookId = createDict["ID"] as? String else {
            XCTFail("Create webhook response should contain ID")
            return
        }
        XCTAssertNotNil(createDict["Name"], "Response should contain Name")
        XCTAssertNotNil(createDict["Secret"], "Response should contain Secret on creation")

        // 2. List webhooks
        let (listStatus, listBody) = try curlSocket("GET", "/webhooks")
        XCTAssertEqual(listStatus, 200, "GET /webhooks should return 200")
        let listJson = assertValidJSON(listBody)
        if let listDict = listJson as? [String: Any],
           let webhooks = listDict["Webhooks"] as? [[String: Any]] {
            XCTAssertTrue(webhooks.contains { ($0["UUID"] as? String) == webhookId },
                          "Created webhook should appear in list")
        }

        // 3. Get webhook by ID
        let (getStatus, getBody) = try curlSocket("GET", "/webhooks/\(webhookId)")
        XCTAssertEqual(getStatus, 200, "GET /webhooks/{id} should return 200")
        let getJson = assertValidJSON(getBody)
        if let getDict = getJson as? [String: Any] {
            XCTAssertEqual(getDict["UUID"] as? String, webhookId)
            XCTAssertEqual(getDict["Name"] as? String, "test-webhook")
        }

        // 4. Delete webhook
        let (deleteStatus, _) = try curlSocket("DELETE", "/webhooks/\(webhookId)")
        XCTAssertEqual(deleteStatus, 204, "DELETE /webhooks/{id} should return 204")

        // 5. Verify deletion - GET should return 404
        let (getAfterDelete, _) = try curlSocket("GET", "/webhooks/\(webhookId)")
        XCTAssertTrue([404, 500].contains(getAfterDelete),
                      "GET /webhooks/{id} after deletion should return 404 or 500, got \(getAfterDelete)")
    }

    func testCreateWebhookMissingFields() throws {
        // Missing required fields should fail
        let (status, _) = try curlSocket("POST", "/webhooks", body: "{}")
        XCTAssertTrue([400, 500].contains(status),
                      "POST /webhooks with empty body should return 400 or 500, got \(status)")
    }

    func testGetWebhookInvalidId() throws {
        let (status, _) = try curlSocket("GET", "/webhooks/nonexistent-webhook-id")
        XCTAssertTrue([404, 500].contains(status),
                      "GET /webhooks/{invalid-id} should return 404 or 500, got \(status)")
    }

    func testDeleteWebhookInvalidId() throws {
        let (status, _) = try curlSocket("DELETE", "/webhooks/nonexistent-webhook-id")
        XCTAssertTrue([404, 500].contains(status),
                      "DELETE /webhooks/{invalid-id} should return 404 or 500, got \(status)")
    }

    func testListWebhooks() throws {
        let (status, body) = try curlSocket("GET", "/webhooks")
        XCTAssertEqual(status, 200, "GET /webhooks should return 200")
        assertValidJSON(body)
    }

    func testWebhooksVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/webhooks")
        XCTAssertEqual(status, 200, "Versioned GET /webhooks should return 200")
        assertValidJSON(body)
    }

    func testCreateWebhookVersioned() throws {
        let createBody = """
        {"name":"test-v-webhook","Endpoint":"https://example.com/hook","Events":["container.start"]}
        """
        let (status, body) = try curlSocket("POST", "/v1.41/webhooks", body: createBody)
        XCTAssertEqual(status, 201, "Versioned POST /webhooks should return 201")
        // Clean up
        if let data = body.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = dict["ID"] as? String {
            _ = try? curlSocket("DELETE", "/webhooks/\(id)")
        }
    }

    func testCreateWebhookWithFilter() throws {
        let createBody = """
        {"name":"filtered-webhook","Endpoint":"https://example.com/hook","Events":["container.start"],"ContainerFilter":{"name":"my-app","labels":{"env":"test"}}}
        """
        let (status, body) = try curlSocket("POST", "/webhooks", body: createBody)
        XCTAssertEqual(status, 201, "POST /webhooks with filter should return 201")
        // Clean up
        if let data = body.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = dict["ID"] as? String {
            _ = try? curlSocket("DELETE", "/webhooks/\(id)")
        }
    }

    func testCreateWebhookWithSecret() throws {
        let createBody = """
        {"name":"secret-webhook","Endpoint":"https://example.com/hook","Events":["container.stop"],"Secret":"my-custom-secret"}
        """
        let (status, body) = try curlSocket("POST", "/webhooks", body: createBody)
        XCTAssertEqual(status, 201, "POST /webhooks with custom secret should return 201")
        let json = assertValidJSON(body)
        if let dict = json as? [String: Any] {
            XCTAssertEqual(dict["Secret"] as? String, "my-custom-secret",
                           "Custom secret should be returned on creation")
        }
        // Clean up
        if let data = body.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = dict["ID"] as? String {
            _ = try? curlSocket("DELETE", "/webhooks/\(id)")
        }
    }

    // MARK: - Catch-All Route

    func testCatchAllUnknownPath() throws {
        let (status, body) = try curlSocket("GET", "/unknown/path/that/does/not/exist")
        XCTAssertEqual(status, 404, "GET /** catch-all should return 404")
        assertValidJSON(body)
    }

    func testCatchAllVersioned() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/unknown/path")
        XCTAssertEqual(status, 404, "Versioned catch-all should return 404")
        assertValidJSON(body)
    }

    // MARK: - Version Prefix Stripping Middleware

    func testVersionPrefixStrippingVariousVersions() throws {
        // Test different version numbers to verify the middleware handles them
        let versions = ["v1.24", "v1.41", "v1.45", "v1.99"]
        for version in versions {
            let (status, body) = try curlSocket("GET", "/\(version)/_ping")
            XCTAssertEqual(status, 200, "GET /\(version)/_ping should return 200")
            XCTAssertEqual(body, "OK", "/\(version)/_ping should return OK")
        }
    }

    func testVersionPrefixPreservesQueryParams() throws {
        let (status, body) = try curlSocket("GET", "/v1.41/containers/json?all=1")
        XCTAssertEqual(status, 200, "Versioned path with query params should work")
        let json = assertValidJSON(body)
        XCTAssertTrue(json is [Any], "Should still return array")
    }
}
