// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sprekr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SprekrCore", targets: ["SprekrCore"]),
        .executable(name: "sprekr-spike", targets: ["SprekrSpike"]),
        .executable(name: "sprekr-test-runner", targets: ["SprekrTestRunner"]),
        .executable(name: "Sprekr", targets: ["SprekrApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        .target(
            name: "SprekrCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SprekrSpike",
            dependencies: ["SprekrCore"]
        ),
        .executableTarget(
            name: "SprekrTestRunner",
            dependencies: ["SprekrCore"]
        ),
        .executableTarget(
            name: "SprekrApp",
            dependencies: ["SprekrCore"]
        ),
        .testTarget(
            name: "SprekrAppTests",
            dependencies: ["SprekrApp", "SprekrCore"]
        ),
    ]
)
