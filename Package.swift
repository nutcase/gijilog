// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Gijilog", platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Gijilog", targets: ["Gijilog"]),
        // The MCP bridge AI apps run; build.sh bundles it into ギジログ.app.
        .executable(name: "gijilog-mcp", targets: ["GijilogMCP"]),
    ],
    targets: [.executableTarget(name: "Gijilog"), .executableTarget(name: "GijilogMCP")])
