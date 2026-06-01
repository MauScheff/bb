// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TurboEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "TurboEngine", targets: ["TurboEngine"]),
        .library(name: "TurboEngineSimulation", targets: ["TurboEngineSimulation"]),
        .executable(name: "turbo-engine", targets: ["TurboEngineCLI"]),
    ],
    targets: [
        .target(name: "TurboEngine"),
        .target(
            name: "TurboEngineSimulation",
            dependencies: ["TurboEngine"]
        ),
        .executableTarget(
            name: "TurboEngineCLI",
            dependencies: ["TurboEngineSimulation"]
        ),
        .testTarget(
            name: "TurboEngineTests",
            dependencies: ["TurboEngine", "TurboEngineSimulation"]
        ),
    ]
)
