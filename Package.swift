// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceTree",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SpaceTree", targets: ["SpaceTree"])],
    targets: [
        .executableTarget(name: "SpaceTree"),
        .testTarget(name: "SpaceTreeTests", dependencies: ["SpaceTree"])
    ]
)
