// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MediaverseLogicContracts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MediaverseRouting", targets: ["MediaverseRouting"]),
        .library(name: "MediaverseSocialContracts", targets: ["MediaverseSocialContracts"]),
        .library(name: "MediaverseEventContracts", targets: ["MediaverseEventContracts"])
    ],
    targets: [
        .target(
            name: "MediaverseRouting",
            path: "Navigation",
            sources: ["AppRoute.swift"]
        ),
        .target(
            name: "MediaverseSocialContracts",
            path: "Social/Contracts"
        ),
        .target(
            name: "MediaverseEventContracts",
            path: "Social/Events",
            exclude: ["VibeEventsViews.swift", "EventLiveRoomView.swift"],
            sources: ["VibeEventModels.swift"]
        ),
        .testTarget(
            name: "MediaverseRoutingTests",
            dependencies: ["MediaverseRouting"],
            path: "LogicTests/MediaverseRoutingTests"
        ),
        .testTarget(
            name: "MediaverseSocialContractsTests",
            dependencies: ["MediaverseSocialContracts"],
            path: "LogicTests/MediaverseSocialContractsTests"
        ),
        .testTarget(
            name: "MediaverseEventContractsTests",
            dependencies: ["MediaverseEventContracts"],
            path: "LogicTests/MediaverseEventContractsTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
