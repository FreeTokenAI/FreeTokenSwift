// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FreeToken",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "FreeToken",
            targets: ["FreeToken"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.20"),
        .package(url: "https://github.com/FreeTokenAI/LocalLLMClient", revision: "a81d393"),
        .package(url: "https://github.com/LaunchDarkly/swift-eventsource.git", from: "3.3.0")
    ],
    targets: [
        .target(
            name: "FreeToken",
            dependencies: [
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "LocalLLMClient", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientLlama", package: "LocalLLMClient"),
                .product(name: "LocalLLMClientMLX", package: "LocalLLMClient"),
                .product(name: "LDSwiftEventSource", package: "swift-eventsource")
            ],
            path: "Sources/FreeToken"
        ),
        .testTarget(
            name: "FreeTokenTests",
            dependencies: ["FreeToken"]
        ),
    ]
)
