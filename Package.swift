// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeBudgetRings",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeBudgetRings",
            path: "Sources/ClaudeBudgetRings"
        ),
        .testTarget(
            name: "ClaudeBudgetRingsTests",
            dependencies: ["ClaudeBudgetRings"],
            path: "Tests/ClaudeBudgetRingsTests"
        ),
    ]
)
