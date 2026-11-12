// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scrim",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ScrimCore", targets: ["ScrimCore"]),
        .executable(name: "ScrimMac", targets: ["ScrimMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", from: "16.1.1")
    ],
    targets: [
        .target(name: "ScrimCore"),
        .executableTarget(
            name: "ScrimMac",
            dependencies: [
                "ScrimCore",
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ]
        ),
        .testTarget(name: "ScrimMacTests", dependencies: ["ScrimMac"]),
        .testTarget(
            name: "ScrimCoreTests",
            dependencies: ["ScrimCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
