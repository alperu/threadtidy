// swift-tools-version: 5.9
//
// SwiftPM is the build system for both the headless kit (parser +
// renderer + CLI test driver) and the macOS .app bundle. The .app is
// produced by `script/build-app.sh`, which compiles the ThreadTidy
// executable target here and packages it into a Foundation .app bundle
// (Contents/MacOS, Contents/Resources, Contents/Frameworks).
//
// TPPDF is vendored locally at ../libs/TPPDF (cloned from
// https://github.com/techprimate/TPPDF) and added as a path dependency.
import PackageDescription

let package = Package(
    name: "ThreadTidy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ThreadTidyKit", targets: ["ThreadTidyKit"]),
        .executable(name: "threadtidy-test", targets: ["threadtidy-test"]),
        .executable(name: "ThreadTidy", targets: ["ThreadTidy"]),
    ],
    dependencies: [
        .package(path: "../libs/TPPDF"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.25.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.25.9"),
    ],
    targets: [
        .target(
            name: "ThreadTidyKit",
            dependencies: [
                .product(name: "TPPDF", package: "TPPDF"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ],
            path: ".",
            exclude: ["App", "Resources", "Tests"],
            sources: ["Parser", "Renderer"]
        ),
        .executableTarget(
            name: "threadtidy-test",
            dependencies: ["ThreadTidyKit"],
            path: "Tests/threadtidy-test"
        ),
        .executableTarget(
            name: "ThreadTidy",
            dependencies: ["ThreadTidyKit"],
            path: "App"
        ),
    ]
)
