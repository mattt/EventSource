// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EventSource",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0"),
        .macCatalyst("15.0"),
        .watchOS("8.0"),
        .tvOS("15.0"),
        .visionOS("1.0"),
    ],
    products: [
        .library(
            name: "EventSource",
            targets: ["EventSource"]
        )
    ],
    targets: [
        .target(
            name: "EventSource"
        ),
        .testTarget(
            name: "EventSourceTests",
            dependencies: ["EventSource"]
        ),
    ]
)
