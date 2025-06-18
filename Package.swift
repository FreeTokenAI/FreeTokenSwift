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
    ],
    targets: [
        .target(
            name: "FreeToken",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "Gzip", package: "GzipSwift"),
                .target(name: "llama")
            ],
            path: "Sources/FreeToken"
        ),
        .binaryTarget(name: "llama", url: "https://github.com/ggml-org/llama.cpp/releases/download/b5699/llama-b5699-xcframework.zip", checksum: "19062d343f991ced0317aa56b23417fbfba537fa18e5a911d37f57ed326b3cb0"),
        .testTarget(
            name: "FreeTokenTests",
            dependencies: ["FreeToken"]
        ),
    ]
)
