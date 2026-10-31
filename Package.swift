// swift-tools-version: 6.0
import PackageDescription

// Isolated updater tests: running them never launches the Minecraft app or JVM.
let package = Package(
    name: "MCUIUpdateCore",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "MCUIUpdateCore", dependencies: ["ZIPFoundation"],
                path: "SwiftCraftLauncher/GameFeature/Services/Updates"),
        .target(name: "SharedSetupCore", path: "SwiftCraftLauncher/GameFeature/Services/SharedSetup"),
        .testTarget(name: "MCUIUpdateCoreTests", dependencies: ["MCUIUpdateCore", "ZIPFoundation", "SharedSetupCore"],
                    path: "distribution/tests")
    ]
)
