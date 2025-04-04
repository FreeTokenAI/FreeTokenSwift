// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FreeToken",
    platforms: [
        .macOS(.v15),
        .iOS(.v16),
        .watchOS(.v11),
        .tvOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "FreeToken",
            targets: ["FreeToken"]),
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.18"),
        .package(url: "https://github.com/1024jp/GzipSwift", from: "6.1.0"),
        .package(url: "https://github.com/FreeTokenAI/LlamaCppSwift", branch: "main")
    ],
    targets: [
        .target(
            name: "FreeToken",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Gzip", package: "GzipSwift"),
                .product(name: "LlamaCppSwift", package: "LlamaCppSwift"),
            ],
            path: "Sources/FreeToken"
        ),
        .testTarget(
            name: "FreeTokenTests",
            dependencies: ["FreeToken"]
        ),
    ]
)
