// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "rejig",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "TileCore"),
    .target(name: "CVirtualDisplay"),
    .executableTarget(name: "rejig", dependencies: ["TileCore", "CVirtualDisplay"]),
    .testTarget(name: "TileCoreTests", dependencies: ["TileCore"]),
  ]
)
