// swift-tools-version: 5.10

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let workspaceRoot = packageDirectory.deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment
let candidateCorePaths = [
    environment["BETR_CORE_DIR"],
    workspaceRoot.appendingPathComponent("betr-core-v3").standardizedFileURL.path(percentEncoded: false),
].compactMap { $0 }
let corePackagePath = candidateCorePaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    ?? workspaceRoot.appendingPathComponent("betr-core-v3").standardizedFileURL.path(percentEncoded: false)

let package = Package(
    name: "BETRRoomControlV4",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RoomControlApp", targets: ["RoomControlApp"]),
    ],
    dependencies: [
        .package(name: "BETRCoreV3", path: corePackagePath),
    ],
    targets: [
        // ── XPC contracts — re-exports BETRCoreXPC + app-specific extensions ──
        .target(
            name: "RoomControlXPCContracts",
            dependencies: [
                .product(name: "BETRCoreXPC", package: "BETRCoreV3"),
            ],
            path: "Sources/RoomControlXPCContracts"
        ),

        // ── Domain modules ──
        .target(
            name: "ClipPlayerDomain",
            dependencies: ["RoomControlXPCContracts"],
            path: "Sources/ClipPlayerDomain"
        ),
        .target(
            name: "TimerDomain",
            dependencies: ["RoomControlXPCContracts"],
            path: "Sources/TimerDomain"
        ),
        .target(
            name: "PresentationDomain",
            dependencies: [
                "RoomControlXPCContracts",
                .product(name: "BETRCoreObjC", package: "BETRCoreV3"),
            ],
            path: "Sources/PresentationDomain"
        ),
        .target(
            name: "PersistenceDomain",
            dependencies: [
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "RoomControlXPCContracts",
            ],
            path: "Sources/PersistenceDomain"
        ),
        .target(
            name: "RoutingDomain",
            dependencies: [
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "PersistenceDomain",
                "RoomControlXPCContracts",
            ],
            path: "Sources/RoutingDomain"
        ),

        // ── UI ──
        .target(
            name: "FeatureUI",
            dependencies: [
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "PersistenceDomain",
                "RoutingDomain",
                "RoomControlXPCContracts",
            ],
            path: "Sources/FeatureUI"
        ),

        // ── App executable ──
        .executableTarget(
            name: "RoomControlApp",
            dependencies: [
                "FeatureUI",
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "PersistenceDomain",
                "RoutingDomain",
                "RoomControlXPCContracts",
            ],
            path: "Sources/RoomControlApp"
        ),

        // ── Tests ──
        .testTarget(
            name: "RoomControlAppTests",
            dependencies: [
                "RoomControlApp",
                "FeatureUI",
                "RoutingDomain",
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "PersistenceDomain",
                "RoomControlXPCContracts",
            ],
            path: "Tests/RoomControlAppTests"
        ),
    ]
)
