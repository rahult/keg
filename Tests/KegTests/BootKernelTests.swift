import XCTest
@testable import Keg

/// Boot-kernel registration detection (container 1.4+) and the Run sheet's
/// translation of the raw "no kernel" failure.
final class BootKernelTests: XCTestCase {

    // MARK: - Registration TOML parsing

    /// Real shape of `container system property list --format toml` on a
    /// 1.4.1 runtime with a registered recommended kernel.
    func testParsesRegisteredKernelSection() {
        let toml = """
        [build]
        cpus = 2
        image = "ghcr.io/apple/container-builder-shim/builder:0.13.1"
        memory = "2048mb"

        [kernel]
        binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
        digest = "sha256:8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
        url = "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"

        [machine]
        cpus = 5

        [vminit]
        image = "ghcr.io/apple/containerization/vminit:0.45.0"
        """
        let registration = BootKernel.parseRegistration(toml)
        XCTAssertEqual(registration.binaryPath, "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug")
        XCTAssertEqual(registration.url, "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst")
    }

    /// A runtime with no `[kernel]` section at all (unregistered 1.4, or a
    /// pre-1.4 config) reads as empty strings, not a crash.
    func testMissingKernelSectionReadsAsEmpty() {
        let toml = """
        [container]
        cpus = 4

        [registry]
        domain = "docker.io"
        """
        let registration = BootKernel.parseRegistration(toml)
        XCTAssertEqual(registration.binaryPath, "")
        XCTAssertEqual(registration.url, "")
    }

    /// A `binaryPath` key outside `[kernel]` (e.g. a future `[machine]`
    /// field) must not be mistaken for the kernel registration.
    func testIgnoresSameNamedKeysInOtherSections() {
        let toml = """
        [machine]
        binaryPath = "decoy"

        [kernel]
        url = "https://example.com/kernel.tar.zst"
        """
        let registration = BootKernel.parseRegistration(toml)
        XCTAssertEqual(registration.binaryPath, "")
        XCTAssertEqual(registration.url, "https://example.com/kernel.tar.zst")
    }

    // MARK: - Status classification

    func testPre14RuntimeClassifiesAsLegacy() {
        XCTAssertEqual(
            BootKernel.status(registrationSupported: false, binaryPath: ""),
            .legacyRuntime)
        // Even an odd non-empty path can't mean "missing" on a runtime that
        // has no registration concept.
        XCTAssertEqual(
            BootKernel.status(registrationSupported: false, binaryPath: "somewhere"),
            .legacyRuntime)
    }

    func testRegisteredAndMissingStates() {
        XCTAssertEqual(
            BootKernel.status(registrationSupported: true, binaryPath: ""),
            .missing)
        XCTAssertEqual(
            BootKernel.status(registrationSupported: true, binaryPath: "opt/kata/share/kata-containers/vmlinux"),
            .ok(binaryPath: "opt/kata/share/kata-containers/vmlinux"))
    }

    // MARK: - Run failure translation

    /// The exact failure a 1.4 runtime emits without registration — the
    /// user-facing message must point at the repair, not quote the CLI.
    func testKernelFailureBecomesActionableMessage() {
        let raw = """
        [0/6] [0s]
        [1/6] Fetching image [0s]
        [3/6] Fetching kernel [0s]
        Error: default kernel not configured for architecture arm64, please use the `container system kernel set` command to configure it
        """
        let message = RunContainerView.runFailureMessage(output: raw, image: "nginx:alpine")
        XCTAssertTrue(message.contains("no boot kernel registered"), "expected kernel guidance, got: \(message)")
        XCTAssertTrue(message.contains("nginx:alpine"))
        XCTAssertFalse(message.contains("Error: default kernel not configured"))
    }

    func testOtherFailuresPassThroughUnchanged() {
        XCTAssertEqual(
            RunContainerView.runFailureMessage(output: "Error: pull access denied", image: "nginx"),
            "Error: pull access denied")
        XCTAssertEqual(
            RunContainerView.runFailureMessage(output: "", image: "nginx"),
            "Failed to run nginx")
    }
}
