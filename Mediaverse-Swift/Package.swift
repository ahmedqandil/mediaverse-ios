// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MediaverseLogicContracts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MediaverseRouting", targets: ["MediaverseRouting"]),
        .library(name: "MediaverseSocialContracts", targets: ["MediaverseSocialContracts"]),
        .library(name: "MediaverseEventContracts", targets: ["MediaverseEventContracts"]),
        .library(name: "MediaversePlatformContracts", targets: ["MediaversePlatformContracts"])
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
            exclude: [
                "VibeEventsViews.swift",
                "EventLiveRoomView.swift",
                "AffiliationReviewView.swift"
            ],
            sources: ["VibeEventModels.swift"]
        ),
        .target(
            name: "MediaversePlatformContracts",
            path: "Models",
            exclude: [
                "Models.swift",
                "StoriesModels.swift",
                "StoryEffectCatalog.swift",
                "StoryProjectModel.swift",
                "StoryViewers.swift"
            ],
            sources: ["PlatformConfig.swift"]
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
        ),
        .testTarget(
            name: "MediaversePlatformContractsTests",
            dependencies: ["MediaversePlatformContracts"],
            path: "LogicTests/MediaversePlatformContractsTests"
        )
    ]
)
