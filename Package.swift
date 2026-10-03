// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minutes", platforms: [.macOS("15.0")], products: [.executable(name: "Minutes", targets: ["Minutes"])],
    targets: [.executableTarget(name: "Minutes")])
