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
        .package(url: "https://github.com/LaunchDarkly/swift-eventsource.git", from: "3.3.0")
    ],
    targets: [
        .target(
            name: "FreeTokenCBridge",
            dependencies: ["LlamaFramework"], // Keep dependency for linking
            path: "Sources/FreeTokenCBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/LlamaHeaders"),
                .define("SWIFT_PACKAGE"),
                .define("LLAMA_HEADERS_DIRECT")
            ]
        ),
        .target(
            name: "FreeToken",
            dependencies: [
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "LDSwiftEventSource", package: "swift-eventsource"),
                "LlamaFramework",
                "FreeTokenCBridge"
            ],
            path: "Sources/FreeToken"
        ),
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b6265/llama-b6265-xcframework.zip",
            checksum: "4378b890f78931c7ecdedae3f9f13f7ab540fcff2370d274f42290c200f5c10e"
        ),
        .testTarget(
            name: "FreeTokenTests",
            dependencies: ["FreeToken"]
        ),
    ]
)
