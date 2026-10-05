import AppKit
import Foundation

// One-time registration of the MCP bridge with AI apps. After it, the AI app starts the bridge whenever it needs
// ギジログ, and the bridge starts ギジログ if it is not running.
@MainActor enum MCPSetup {
    static var bridgePath: String { MCPPaths.bridge.path }
    /// The Claude Code command, quoted for a shell.
    static var claudeCodeCommand: String {
        "claude mcp add --scope user gijilog -- '" + bridgePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// The entry for claude_desktop_config.json, for clients configured by hand.
    static var desktopConfig: String {
        let config = ["mcpServers": ["gijilog": ["command": bridgePath, "args": [String]()]]]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Registers ギジログ with Claude Code (user scope), replacing an earlier registration such as one for a moved
    /// app. Returns what to tell the user; without the claude command the command is copied instead.
    static func addToClaudeCode() async -> (title: String, message: String) {
        guard let claude = await claudeCommand() else {
            copy(claudeCodeCommand)
            return (
                "コマンドをコピーしました",
                "claude コマンドが見つかりませんでした。ターミナルに貼り付けて実行してください。\n\n" + claudeCodeCommand
            )
        }
        _ = await run(claude, ["mcp", "remove", "--scope", "user", "gijilog"])
        let (status, output) = await run(claude, ["mcp", "add", "--scope", "user", "gijilog", "--", bridgePath])
        if status == 0 {
            return ("Claude Code に追加しました", "次に起動する Claude Code のセッションから、ギジログの会議を読めます。")
        }
        copy(claudeCodeCommand)
        return ("追加できませんでした", output + "\n\nコマンドをコピーしたので、ターミナルで実行してください。")
    }
    /// The claude command: on the login shell's PATH, or in one of its usual install places.
    private static func claudeCommand() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let (status, output) = await run(URL(fileURLWithPath: shell), ["-l", "-c", "command -v claude"])
        if status == 0, let path = output.split(separator: "\n").last.map(String.init),
            FileManager.default.isExecutableFile(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ].first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
    private static func run(_ executable: URL, _ arguments: [String]) async -> (Int32, String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// A Claude Desktop extension (.mcpb) holding a copy of the bridge. Opening it shows Claude Desktop's install
    /// dialog. The copy finds ギジログ by its bundle ID, so moving the app does not break it.
    static func makeDesktopExtension() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("gijilog-mcpb-\(UUID().uuidString)")
        let content = work.appendingPathComponent("extension")
        let server = content.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: MCPPaths.bridge, to: server.appendingPathComponent("gijilog-mcp"))
        if let icon = iconPNG() { try icon.write(to: content.appendingPathComponent("icon.png")) }
        let manifest: [String: Any] = [
            "manifest_version": "0.3", "name": "gijilog", "display_name": "ギジログ", "version": "0.1.0",
            "description": "ギジログの会議（議事録・文字起こし・アクションアイテム・アジェンダ）を読み取ります。通信はこの Mac の中だけで行います。",
            "author": ["name": "nutcase"], "homepage": "https://github.com/nutcase/gijilog", "icon": "icon.png",
            "server": [
                "type": "binary", "entry_point": "server/gijilog-mcp",
                "mcp_config": ["command": "${__dirname}/server/gijilog-mcp", "args": [String]()],
            ],
            "tools": MCPHandler.tools.map { ["name": $0["name"] ?? "", "description": $0["description"] ?? ""] },
            "compatibility": ["platforms": ["darwin"]],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: content.appendingPathComponent("manifest.json"))
        let archive = work.appendingPathComponent("ギジログ.mcpb")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // Without these, macOS adds ._ files for extended attributes next to manifest.json in the archive.
        ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", content.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw AppError.message("拡張機能のファイルを作れませんでした。") }
        return archive
    }
    /// The extension icon: the bundled full-bleed artwork with rounded corners and no margin. The icon macOS
    /// renders has a transparent margin and a shadow, which shrink it to a dark speck in Claude's small lists.
    private static func iconPNG() -> Data? {
        let artwork =
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        let rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: rect, xRadius: 512 * 0.225, yRadius: 512 * 0.225).addClip()
        artwork.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
    /// Opens the extension in Claude Desktop, or shows it in Finder when nothing can open it.
    static func addToClaudeDesktop() -> (title: String, message: String) {
        do {
            let archive = try makeDesktopExtension()
            guard NSWorkspace.shared.urlForApplication(toOpen: archive) != nil else {
                NSWorkspace.shared.activateFileViewerSelecting([archive])
                return (
                    "Claude Desktop が見つかりません",
                    "拡張機能のファイル（ギジログ.mcpb）を Finder で表示しました。Claude Desktop をインストールしてから、このファイルを開いてください。"
                )
            }
            NSWorkspace.shared.open(archive)
            return ("Claude Desktop で開きました", "Claude Desktop に表示される画面で「インストール」を押してください。")
        } catch {
            return ("追加できませんでした", error.localizedDescription)
        }
    }
}
