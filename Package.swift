// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keg",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Keg", targets: ["Keg"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "1.3.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Keg",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Sparkle", package: "Sparkle"),
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
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "ContainerPersistence", package: "container"),
            ],
            path: "Tests/KegTests"
        ),
    ]
)
