// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneMCP",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "OneMCP",
            targets: ["OneMCP"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.9.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "OneMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "OneMCP/Sources"
        ),
        .testTarget(
            name: "OneMCPTests",
            dependencies: ["OneMCP"],
            path: "OneMCP/Tests"
        ),
    ]
)