// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "GroupAutoSave",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(
            name: "GroupAutoSave",
            targets: ["MessageInspector", "PeerLinkResolver", "MediaArchiver", "MessageWalker", "MCPServer"]
        ),
    ],
    dependencies: [
        .package(name: "SSignalKit", path: "../../submodules/telegram-ios/submodules/SSignalKit"),
        .package(name: "Postbox", path: "../../submodules/telegram-ios/submodules/Postbox"),
        .package(name: "TelegramCore", path: "../../submodules/telegram-ios/submodules/TelegramCore"),
    ],
    targets: [
        .target(
            name: "MessageInspector",
            dependencies: [
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "TelegramCore", package: "TelegramCore"),
            ]
        ),
        .target(
            name: "PeerLinkResolver",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "TelegramCore", package: "TelegramCore"),
            ]
        ),
        .target(
            name: "MediaArchiver",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "TelegramCore", package: "TelegramCore"),
            ]
        ),
        .target(
            name: "MessageWalker",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
                .product(name: "Postbox", package: "Postbox"),
                .product(name: "TelegramCore", package: "TelegramCore"),
            ]
        ),
        .target(
            name: "MCPServer",
            dependencies: [
                .product(name: "SwiftSignalKit", package: "SSignalKit"),
            ]
        ),
        .testTarget(
            name: "MessageInspectorTests",
            dependencies: ["MessageInspector"]
        ),
        .testTarget(
            name: "PeerLinkResolverTests",
            dependencies: ["PeerLinkResolver"]
        ),
        .testTarget(
            name: "MediaArchiverTests",
            dependencies: ["MediaArchiver"]
        ),
        .testTarget(
            name: "MessageWalkerTests",
            dependencies: ["MessageWalker"]
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: ["MCPServer"]
        ),
    ]
)
