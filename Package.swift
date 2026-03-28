// swift-tools-version: 5.10

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let workspaceRoot = packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment
let candidateCorePaths = [
    environment["BETR_CORE_DIR"],
    workspaceRoot.appendingPathComponent("macos-apps/betr-core-v3").standardizedFileURL.path(percentEncoded: false),
].compactMap { $0 }
let corePackagePath = candidateCorePaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    ?? workspaceRoot.appendingPathComponent("macos-apps/betr-core-v3").standardizedFileURL.path(percentEncoded: false)

let package = Package(
    name: "BETRRoomControlV4",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RoomControlApp", targets: ["RoomControlApp"]),
    ],
    dependencies: [
        .package(name: "betr-core-v3", path: corePackagePath),
    ],
    targets: [
        .target(
            name: "RoomControlUIContracts",
            dependencies: [
                "TimerDomain",
                .product(name: "CoreNDIHost", package: "betr-core-v3"),
            ],
            path: "Sources/RoomControlUIContracts"
        ),
        .target(
            name: "ClipPlayerDomain",
            dependencies: [
                .product(name: "CoreNDIOutput", package: "betr-core-v3"),
            ],
            path: "Sources/ClipPlayerDomain"
        ),
        .target(
            name: "TimerDomain",
            path: "Sources/TimerDomain"
        ),
        .target(
            name: "PresentationDomain",
            path: "Sources/PresentationDomain"
        ),
        .target(
            name: "PersistenceDomain",
            dependencies: [
                "ClipPlayerDomain",
                "RoomControlUIContracts",
                "TimerDomain",
            ],
            path: "Sources/PersistenceDomain"
        ),
        .target(
            name: "HostWizardDomain",
            dependencies: [
                "RoomControlUIContracts",
                .product(name: "CoreNDIHost", package: "betr-core-v3"),
            ],
            path: "Sources/HostWizardDomain"
        ),
        .target(
            name: "RoutingDomain",
            dependencies: [
                "ClipPlayerDomain",
                "HostWizardDomain",
                "RoomControlUIContracts",
                "TimerDomain",
                .product(name: "BETRCoreXPC", package: "betr-core-v3"),
                .product(name: "CoreNDIHost", package: "betr-core-v3"),
                .product(name: "CoreNDIOutput", package: "betr-core-v3"),
                .product(name: "CoreNDIPlatform", package: "betr-core-v3"),
            ],
            path: "Sources/RoutingDomain"
        ),
        .target(
            name: "FeatureUI",
            dependencies: [
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "PersistenceDomain",
                "HostWizardDomain",
                "RoutingDomain",
                "RoomControlUIContracts",
                .product(name: "CoreNDIHost", package: "betr-core-v3"),
            ],
            path: "Sources/FeatureUI"
        ),
        .executableTarget(
            name: "RoomControlApp",
            dependencies: [
                "FeatureUI",
                "ClipPlayerDomain",
                "TimerDomain",
                "PresentationDomain",
                "PersistenceDomain",
                "HostWizardDomain",
                "RoutingDomain",
                "RoomControlUIContracts",
            ],
            path: "Sources/RoomControlApp"
        ),
        .testTarget(
            name: "RoomControlScaffoldTests",
            dependencies: [
                "FeatureUI",
                "HostWizardDomain",
                "RoutingDomain",
                "RoomControlUIContracts",
                .product(name: "BETRCoreXPC", package: "betr-core-v3"),
                .product(name: "CoreNDIDiscovery", package: "betr-core-v3"),
                .product(name: "CoreNDIHost", package: "betr-core-v3"),
                .product(name: "CoreNDIOutput", package: "betr-core-v3"),
                .product(name: "CoreNDIPlatform", package: "betr-core-v3"),
            ],
            path: "Tests/RoomControlScaffoldTests"
        ),
    ]
)
