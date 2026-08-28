// swift-tools-version:6.2
import PackageDescription

// Pin the language mode explicitly: the app target builds in Swift 6 strict
// concurrency and the package must never drift from it silently.
//
// Warnings-as-errors deliberately lives in `just ci-core`, not here. This
// package is referenced by the Xcode project, so a manifest-level setting
// also governs `just run` — and since local development is a toolchain
// ahead of CI, any warning a newer Swift introduces would hard-fail the
// developer build rather than the lane that is supposed to catch it.
let coreSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "ZephrCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZephrCore", targets: ["ZephrCore"])
    ],
    targets: [
        .target(name: "ZephrCore", swiftSettings: coreSwiftSettings),
        .testTarget(
            name: "ZephrCoreTests",
            dependencies: ["ZephrCore"],
            swiftSettings: coreSwiftSettings
        ),
    ]
)
