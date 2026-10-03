// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gijilog", platforms: [.macOS("15.0")], products: [.executable(name: "Gijilog", targets: ["Gijilog"])],
    targets: [.executableTarget(name: "Gijilog")])
