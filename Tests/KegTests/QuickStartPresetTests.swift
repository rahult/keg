import XCTest
@testable import Keg

/// Quick-start presets + the volume field validation that backs them.
final class QuickStartPresetTests: XCTestCase {

    // MARK: - Preset matching

    func testHelloWorldMatchesBareTaggedAndRegistryRefs() {
        for ref in ["hello-world", "hello-world:latest", "docker.io/library/hello-world:latest"] {
            XCTAssertEqual(ContainerRunPreset.matching(image: ref), .helloWorld, "expected helloWorld preset for \(ref)")
        }
    }

    func testNginxMatchesBareTaggedAndRegistryRefs() {
        for ref in ["nginx", "nginx:1.27", "docker.io/library/nginx:latest", "registry.example.com/nginx"] {
            XCTAssertEqual(ContainerRunPreset.matching(image: ref), .webServer, "expected webServer preset for \(ref)")
        }
    }

    func testUnknownImageHasNoPreset() {
        XCTAssertNil(ContainerRunPreset.matching(image: "postgres:16"))
        XCTAssertNil(ContainerRunPreset.matching(image: ""))
    }

    func testHelloWorldPresetRunsForegroundAndShowsOutput() {
        let preset = ContainerRunPreset.helloWorld
        XCTAssertFalse(preset.detached, "hello-world must run foreground so its greeting is visible")
        XCTAssertNil(preset.successURL)
        XCTAssertFalse(preset.name.isEmpty)
    }

    func testWebServerPresetPublishesPort8080() {
        let preset = ContainerRunPreset.webServer
        XCTAssertTrue(preset.ports.contains("8080:80"))
        XCTAssertTrue(preset.detached)
        XCTAssertEqual(preset.successURL, "http://localhost:8080")
    }

    // MARK: - Volume validation

    func testValidAbsoluteMountPasses() {
        XCTAssertTrue(ContainerRunArguments.volumeMountProblems("/Users/me/site:/usr/share/nginx/html").isEmpty)
    }

    func testTildeMountPasses() {
        XCTAssertTrue(ContainerRunArguments.volumeMountProblems("~/websites:/usr/share/nginx/html").isEmpty)
    }

    func testEmptyFieldPasses() {
        XCTAssertTrue(ContainerRunArguments.volumeMountProblems("").isEmpty)
        XCTAssertTrue(ContainerRunArguments.volumeMountProblems("   ").isEmpty)
    }

    func testNamedVolumeIsCalledOut() {
        let problems = ContainerRunArguments.volumeMountProblems("mydata:/data")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("named volume"), problems[0])
    }

    func testRelativeHostPathIsCalledOut() {
        let problems = ContainerRunArguments.volumeMountProblems("./site:/site")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("absolute"), problems[0])
    }

    func testMissingContainerPathIsCalledOut() {
        let problems = ContainerRunArguments.volumeMountProblems("/Users/me/site")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("two paths"), problems[0])
    }

    func testRelativeContainerPathIsCalledOut() {
        let problems = ContainerRunArguments.volumeMountProblems("/Users/me/site:data")
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("absolute"), problems[0])
    }

    func testReadOnlyOptionMountPasses() {
        XCTAssertTrue(ContainerRunArguments.volumeMountProblems("/Users/me/site:/usr/share/nginx/html:ro").isEmpty)
    }

    func testProblemsReportEachBadEntry() {
        let problems = ContainerRunArguments.volumeMountProblems("mydata:/data, /ok:/fine")
        XCTAssertEqual(problems.count, 1, "only the named volume should be flagged")
    }

    // MARK: - Volume splitting

    func testSplitVolumesExpandsTilde() {
        let expanded = ContainerRunArguments.splitVolumes("~/site:/site")
        XCTAssertEqual(expanded, ["\(NSHomeDirectory())/site:/site"])
    }

    func testSplitVolumesTrimsAndDropsEmpties() {
        let expanded = ContainerRunArguments.splitVolumes(" /a:/a , , ~/b:/b ")
        XCTAssertEqual(expanded, ["/a:/a", "\(NSHomeDirectory())/b:/b"])
    }

    // MARK: - Built args use expanded volumes

    func testBuildRunArgsReceivesExpandedVolumeEntries() {
        let args = ContainerRunArguments.build(
            name: nil,
            env: [],
            ports: [],
            volumes: ContainerRunArguments.splitVolumes("~/site:/site"),
            cpus: nil,
            memory: nil,
            detached: false,
            image: "nginx",
            command: ""
        )
        XCTAssertTrue(args.contains("-v"))
        if let index = args.firstIndex(of: "-v") {
            XCTAssertEqual(args[args.index(after: index)], "\(NSHomeDirectory())/site:/site")
        }
        XCTAssertFalse(args.contains("-d"), "foreground demo run should not detach")
    }
}
