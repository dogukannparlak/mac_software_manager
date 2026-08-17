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
            path: "Sources/MacUpdaterGuide"
        ),
        .testTarget(
            name: "MacUpdaterGuideTests",
            dependencies: ["MacUpdaterGuide"],
            path: "Tests/MacUpdaterGuideTests"
        )
    ]
)
