// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "takometa",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TakometaCore"),
        .target(name: "TakometaFixtureSupport"),
        .executableTarget(
            name: "takometa-spike",
            dependencies: ["TakometaCore", "TakometaFixtureSupport"]),
        .executableTarget(name: "TakometaApp", dependencies: ["TakometaCore"]),
        .executableTarget(name: "takometa", dependencies: ["TakometaCore"]),
        .testTarget(
            name: "TakometaCoreTests",
            dependencies: ["TakometaCore"],
            resources: [
                .copy("Fixtures"),
                .copy("../../scripts/release-checks/codename-identifiers.txt"),
            ]
        ),
        .testTarget(
            name: "TakometaFixtureSupportTests",
            dependencies: ["TakometaFixtureSupport"],
            resources: [.copy("../TakometaCoreTests/Fixtures")]
        ),
    ]
)
