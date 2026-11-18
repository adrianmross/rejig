// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "rejig",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "TileCore"),
    .executableTarget(name: "rejig", dependencies: ["TileCore"]),
    .testTarget(name: "TileCoreTests", dependencies: ["TileCore"]),
  ]
)
