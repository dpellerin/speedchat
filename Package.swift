// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SpeedChat", platforms: [.macOS(.v14)], products: [.executable(name: "SpeedChat", targets: ["SpeedChat"])], targets: [.target(name: "ChatCore"), .executableTarget(name: "SpeedChat", dependencies: ["ChatCore"]), .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]), .testTarget(name:"NativeBridgeTests", dependencies:["SpeedChat","ChatCore"])])
