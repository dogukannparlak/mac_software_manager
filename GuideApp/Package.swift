// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacUpdaterGuide",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacUpdaterGuide",
            path: "Sources/MacUpdaterGuide",
            // The shell engine, shipped inside the app rather than downloaded
            // at setup time. Kept in step with the repository root by
            // tools/sync_engine_resources.sh - see that script for why the
            // files are copies and not symlinks.
            resources: [.copy("EngineResources")]
        ),
        .testTarget(
            name: "MacUpdaterGuideTests",
            dependencies: ["MacUpdaterGuide"],
            path: "Tests/MacUpdaterGuideTests"
        )
    ]
)
