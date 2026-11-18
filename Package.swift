// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "tilespace",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "TileCore"),
    .executableTarget(name: "tilespace", dependencies: ["TileCore"]),
    .testTarget(name: "TileCoreTests", dependencies: ["TileCore"]),
  ]
)
