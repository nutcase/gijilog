import Darwin
import Foundation

// gijilog-mcp: the command an AI app (Claude Code, Claude Desktop, …) runs to reach ギジログ over MCP.
// It relays newline-delimited JSON-RPC between stdio and the Unix socket ギジログ serves to this user only,
// starts ギジログ, hidden, when it is not running, and reconnects after it quits, so the AI app never loses the
// server.
// Nothing here listens on the network. Logs go to stderr; stdout carries only MCP messages.

let bundleID = "io.github.nutcase.gijilog"
// For development, GIJILOG_MCP_SOCKET points at another socket and GIJILOG_MCP_NO_LAUNCH=1 never starts ギジログ.
let environment = ProcessInfo.processInfo.environment
let socketPath =
    environment["GIJILOG_MCP_SOCKET"]
    ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
    .appendingPathComponent("Gijilog/mcp.sock").path
let launches = environment["GIJILOG_MCP_NO_LAUNCH"] != "1"
let unreachable = "ギジログに接続できません。ギジログを起動し、設定の「AI 連携」で MCP が有効になっているか確認してください。"

final class Bridge: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: Int32 = -1
    private var pending: [String: Any] = [:]  // Requests waiting for ギジログ's reply, by id.

    func log(_ text: String) { FileHandle.standardError.write(Data(("gijilog-mcp: " + text + "\n").utf8)) }

    /// Writes one message to the AI app.
    func emit(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(line + Data([0x0A]))
    }
    func fail(id: Any, _ message: String) {
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: reply) { emit(data) }
    }
    private static func key(_ id: Any) -> String { "\(type(of: id)):\(id)" }

    /// Sends one line from the AI app, connecting (and starting ギジログ) first if needed.
    func forward(_ line: Data) {
        let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        let id = message?["method"] != nil ? message?["id"] : nil
        setPending(id, id)
        for _ in 1...2 {
            guard let fd = connected() else { break }
            if send(line + Data([0x0A]), to: fd) { return }
            // ギジログ quit since the last message, before this one went out: reconnect and send it once more.
            setPending(id, nil)
            drop(fd)
            setPending(id, id)
        }
        if let id {
            setPending(id, nil)
            fail(id: id, unreachable)
        }
    }
    private func setPending(_ id: Any?, _ value: Any?) {
        guard let id else { return }
        lock.lock()
        pending[Self.key(id)] = value
        lock.unlock()
    }
    private func connected() -> Int32? {
        lock.lock()
        let current = socket
        lock.unlock()
        if current >= 0 { return current }
        var fd = connect()
        if fd == nil && launches {
            launch()
            let deadline = Date().addingTimeInterval(20)
            while fd == nil && Date() < deadline {
                usleep(250_000)
                fd = connect()
            }
        }
        guard let fd else { return nil }
        lock.lock()
        socket = fd
        lock.unlock()
        let reader = Thread { [weak self] in self?.read(fd) }
        reader.start()
        return fd
    }
    private func connect() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
    /// Starts ギジログ in the background and hidden: the app this bridge is bundled in, or else the one Launch
    /// Services knows. Nobody asked to see it, so its window stays out of the way until they open it themselves;
    /// launched only in the background, the window came up over the other apps' windows.
    private func launch() {
        log("ギジログを起動します")
        let bundle = Bundle.main.bundleURL
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments =
            bundle.pathExtension == "app" ? ["-g", "-j", "-a", bundle.path] : ["-g", "-j", "-b", bundleID]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            log("起動できませんでした: \(error.localizedDescription)")
        }
    }
    private func send(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let written = write(fd, base + sent, data.count - sent)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                sent += written
            }
            return true
        }
    }
    /// Relays ギジログ's replies until it closes the connection.
    private func read(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                if let reply = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    reply["method"] == nil, let id = reply["id"]
                {
                    setPending(id, nil)
                }
                emit(Data(line))
            }
        }
        drop(fd)
    }
    /// ギジログ went away: requests still waiting get an error instead of hanging, and the next one reconnects.
    private func drop(_ fd: Int32) {
        lock.lock()
        guard socket == fd else {
            lock.unlock()
            return
        }
        socket = -1
        let waiting = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        close(fd)
        for id in waiting { fail(id: id, "ギジログとの接続が切れました。もう一度試してください。") }
    }
}

signal(SIGPIPE, SIG_IGN)
let bridge = Bridge()
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    bridge.forward(Data(line.utf8))
}
