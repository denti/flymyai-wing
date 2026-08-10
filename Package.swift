// swift-tools-version:5.9
import PackageDescription

// Lidwing is developed on Linux and shipped on macOS.
//
// `LidwingCore` is Foundation-only: no AppKit, no IOKit, no Darwin-only API. It holds the
// state machine, the safety policy, the ledger, the config patchers and the presentation
// model, so all of that builds and unit-tests on Linux in seconds on every change.
//
// The Darwin-only targets (IOKit, CoreAudio, AppKit) are added to the manifest only when the
// manifest itself is being compiled on macOS. On Linux `swift build` / `swift test` therefore
// build exactly the portable half, with no flags and no excluded-target bookkeeping.

// Warnings are promoted to errors by the CI gate (`-Xswiftc -warnings-as-errors`), not here:
// `unsafeFlags` in a manifest makes the package unusable as a dependency and is not worth it.

var products: [Product] = [
    .library(name: "LidwingCore", targets: ["LidwingCore"])
]

var targets: [Target] = [
    .target(name: "LidwingCore"),
    .testTarget(
        name: "LidwingCoreTests",
        dependencies: ["LidwingCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products += [
    .executable(name: "Lidwing", targets: ["LidwingApp"]),
    .executable(name: "lidwingd", targets: ["lidwingd"]),
    .executable(name: "lidwing-notify", targets: ["lidwing-notify"]),
]

targets += [
    .target(name: "LidwingSystem", dependencies: ["LidwingCore"]),
    .executableTarget(name: "LidwingApp", dependencies: ["LidwingCore", "LidwingSystem"]),
    .executableTarget(name: "lidwingd", dependencies: ["LidwingCore", "LidwingSystem"]),
    .executableTarget(name: "lidwing-notify"),
    .testTarget(name: "LidwingSystemTests", dependencies: ["LidwingSystem", "LidwingCore"]),
]
#endif

let package = Package(
    name: "Lidwing",
    // Verified in DESIGN.md §6.1: at .v12 SwiftPM hard-links libswift_Concurrency on both
    // slices. At .v11 it emits a weak link with an rpath the OS does not carry, and the app
    // dies with EXC_BAD_ACCESS on the first `await` — on exactly the old OS versions a low
    // floor exists to reach.
    platforms: [.macOS(.v12)],
    products: products,
    targets: targets
)
