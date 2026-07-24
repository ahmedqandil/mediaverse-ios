// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MediaverseLogicContracts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MediaverseRouting", targets: ["MediaverseRouting"])
    ],
    targets: [
        .target(
            name: "MediaverseRouting",
            path: "Navigation",
            sources: ["AppRoute.swift"]
        ),
        .testTarget(
            name: "MediaverseRoutingTests",
            dependencies: ["MediaverseRouting"],
            path: "LogicTests/MediaverseRoutingTests"
        )
    ]
)
