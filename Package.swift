// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "e09_reverse",
    platforms: [
        .macOS(.v14) // Requires macOS 14+ for CoreBluetooth
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .executable(
            name: "e09_reverse",
            targets: ["e09_reverse"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", branch: "main"),
        .package(url: "https://github.com/alta/swift-opus.git", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .executableTarget(
            name: "e09_reverse",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Opus", package: "swift-opus"),  
            ],
            path: "Sources/e09_reverse",
            resources: [
                .copy("Resources/silero-vad.mlmodelc/"),
                .copy("Resources/silero_vad.onnx")
            ],
            swiftSettings: [
                // Enable Objective-C interop for CoreBluetooth
                .enableExperimentalFeature("ObjectiveCInterop")
            ]
        ),
        .testTarget(
            name: "VADTests",
            dependencies: [
                .target(name: "e09_reverse"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Opus", package: "swift-opus"),
            ],
            path: "Tests",
            resources: [
                .copy("Resources/passiveWakeWordListen.ogg"),
                .copy("Resources/silero-vad.mlmodelc/"),
                .copy("Resources/silero_vad.onnx")
            ]
        ),
    ]
)