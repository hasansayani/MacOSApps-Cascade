// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cascade",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure layout / grouping logic — no AppKit, fully unit-checkable.
        .target(name: "CascadeCore"),
        // The menu bar app.
        .executableTarget(name: "Cascade", dependencies: ["CascadeCore"]),
        // `swift run CascadeSelfTest` — assertion checks for CascadeCore (works without Xcode).
        .executableTarget(name: "CascadeSelfTest", dependencies: ["CascadeCore"]),
    ]
)
