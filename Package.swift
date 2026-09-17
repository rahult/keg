// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keg",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Keg", targets: ["Keg"]),
        // Built as `kegcli` because the build directory lives on a
        // case-insensitive filesystem: a `keg` artifact would collide with
        // the app's `Keg` binary. The Makefile installs it as `keg` inside
        // the app bundle, and PATH installs symlink it as `keg`.
        .executable(name: "kegcli", targets: ["kegcli"]),
        .library(name: "KegCLICore", targets: ["KegCLICore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.3.1"),
        // Pinned to the exact revision apple/container 1.3.1 requires, so the
        // Terminal.Size used by ClientProcess.resize resolves to one module.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.42.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
        // Pinned pre-GPU-backend: 1.12+ ships Metal shaders that don't
        // compile under SwiftPM's bare `metal` invocation.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
        // NIOHTTPTypesHTTP1 hosts HTTP1ToHTTPServerCodec, needed by the
        // Docker hijack channel to convert classic HTTP parts to HTTPTypes.
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.33.0"),
    ],
    targets: [
        // Shared logic for the `keg` companion CLI and the app's CLI
        // installer. Foundation-only so the CLI starts fast and the app can
        // reuse the install-location rules without linking GUI code.
        .target(
            name: "KegCLICore",
            path: "Sources/KegCLICore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "kegcli",
            dependencies: [
                .target(name: "KegCLICore"),
            ],
            path: "Sources/KegCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Keg",
            dependencies: [
                .target(name: "KegCLICore"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Keg",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            // Sparkle ships as a framework that the Makefile copies into
            // Contents/Frameworks. SwiftPM builds a bare executable and has no
            // concept of an app bundle, so the runtime search path that lets
            // the binary find it there has to be set by hand.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "KegTests",
            dependencies: [
                .target(name: "Keg"),
                .target(name: "KegCLICore"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
            ],
            path: "Tests/KegTests"
        ),
    ]
)
