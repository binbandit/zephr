// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZephrCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZephrCore", targets: ["ZephrCore"])
    ],
    targets: [
        .target(name: "ZephrCore"),
        .testTarget(name: "ZephrCoreTests", dependencies: ["ZephrCore"]),
    ]
)
