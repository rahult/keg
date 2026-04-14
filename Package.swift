// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Keg",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Keg", targets: ["Keg"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", exact: "0.11.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Keg",
            dependencies: [
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/Keg",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "KegTests",
            dependencies: [
                .target(name: "Keg"),
                .product(name: "ContainerAPIClient", package: "container"),
                .product(name: "ContainerResource", package: "container"),
            ],
            path: "Tests/KegTests"
        ),
    ]
)
