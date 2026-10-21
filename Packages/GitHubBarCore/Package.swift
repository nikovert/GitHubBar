// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GitHubBarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitHubBarCore", targets: ["GitHubBarCore"]),
        .executable(name: "GitHubBarCoreChecks", targets: ["GitHubBarCoreChecks"]),
        .executable(name: "GitHubBarWorkspaceCLI", targets: ["GitHubBarWorkspaceCLI"]),
    ],
    targets: [
        .target(name: "GitHubBarCore"),
        .executableTarget(
            name: "GitHubBarCoreChecks",
            dependencies: ["GitHubBarCore"],
            path: "Checks/GitHubBarCoreChecks"
        ),
        .executableTarget(
            name: "GitHubBarWorkspaceCLI",
            dependencies: ["GitHubBarCore"],
            path: "CLI/GitHubBarWorkspaceCLI"
        ),
        .testTarget(
            name: "GitHubBarCoreTests",
            dependencies: ["GitHubBarCore"]
        ),
    ]
)
