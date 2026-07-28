// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MediaverseLogicContracts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MediaverseRouting", targets: ["MediaverseRouting"]),
        .library(name: "MediaverseSocialContracts", targets: ["MediaverseSocialContracts"])
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
        .testTarget(
            name: "MediaverseRoutingTests",
            dependencies: ["MediaverseRouting"],
            path: "LogicTests/MediaverseRoutingTests"
        ),
        .testTarget(
            name: "MediaverseSocialContractsTests",
            dependencies: ["MediaverseSocialContracts"],
            path: "LogicTests/MediaverseSocialContractsTests"
        )
    ]
)
