// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TrueMetalShader",
    // SwiftUI 的 Shader / ShaderLibrary / layerEffect 需要以下系统版本。
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "TrueMetalShader",
            targets: ["TrueMetalShader"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // 目录下的 .metal 会被 SwiftPM 自动编译进本 target 的资源包(default.metallib)，
        // 因此可通过 ShaderLibrary.bundle(.module) 访问。
        .target(
            name: "TrueMetalShader",
            resources: [
                .process("Effects/Metaball/Metaball.metal"),
                .process("Effects/PaperBurn/PaperBurn.metal"),
                .process("Effects/Particle/Particle.metal"),
                .process("Effects/RainbowDisplacement/RainbowDisplacement.metal"),
                .process("Effects/RainbowRipple/RainbowRipple.metal"),
                .process("Effects/Water/Water.metal"),
            ]
        ),

    ],
    swiftLanguageModes: [.v6]
)
