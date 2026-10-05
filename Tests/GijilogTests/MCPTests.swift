import Darwin
import Foundation

extension ProcessingTests {
    @MainActor private func mcpStore() throws -> (Store, URL, [Meeting]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Store(root: root, loadSettings: false)
        var weekly = Meeting(title: "週次定例")
        weekly.date = Date(timeIntervalSince1970: 1_790_000_000)
        weekly.tags = ["定例"]
        weekly.capture = .stopped
        weekly.status = "完了"
        weekly.segments = (0..<40).map {
            Segment(id: "s\($0)", time: Double($0 * 12), source: "マイク", text: "発言\($0) 予算と範囲の話をします")
        }
        var notes = MinutesState()
        notes.content.decisions = [
            NoteItem(id: "d1", text: "書き出しまでを範囲にする", evidence: ["s1"], reason: "精度の検証が済んでいない")
        ]
        notes.content.actions = [
            NoteItem(id: "a1", text: "FAQを更新する", owner: "佐藤さん", due: "10月10日", evidence: ["s2"]),
            NoteItem(id: "a2", text: "環境を更新する", evidence: ["s3"], state: .done),
        ]
        weekly.notes = notes
        weekly.agenda = MeetingAgenda.parse("確認（5分）\n範囲")
        var secret = Meeting(title: "人事の相談")
        secret.tags = ["非公開"]
        secret.notes = MinutesState()
        secret.notes?.content.actions = [NoteItem(id: "x1", text: "評価を見直す", owner: "佐藤さん", evidence: ["t1"])]
        store.meetings = [weekly, secret]
        return (store, root, [weekly, secret])
    }
    @MainActor private func rpc(
        _ handler: MCPHandler, _ method: String, _ params: [String: Any] = [:], modern: String? = nil
    ) throws -> [String: Any] {
        var params = params
        if let modern {
            params["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": modern,
                "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "1"],
            ]
        }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method, "params": params]
        let reply = try Self.require(
            handler.handle(try JSONSerialization.data(withJSONObject: request)), "a reply to \(method)")
        return try Self.require(try JSONSerialization.jsonObject(with: reply) as? [String: Any], "JSON reply")
    }
    @MainActor private func callTool(_ handler: MCPHandler, _ name: String, _ arguments: [String: Any] = [:]) throws
        -> (text: String, structured: [String: Any], isError: Bool)
    {
        let reply = try rpc(handler, "tools/call", ["name": name, "arguments": arguments], modern: "2026-07-28")
        let result = try Self.require(reply["result"] as? [String: Any], "\(name) result: \(reply)")
        let content = result["content"] as? [[String: Any]] ?? []
        return (
            content.first?["text"] as? String ?? "", result["structuredContent"] as? [String: Any] ?? [:],
            result["isError"] as? Bool ?? false
        )
    }

    @MainActor func testMCPSpeaksBothProtocolEras() throws {
        let (store, root, _) = try mcpStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = MCPHandler(store: store)
        let legacy = try rpc(
            handler, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"]])
        let initialized = try Self.require(legacy["result"] as? [String: Any], "initialize result")
        try Self.check(
            initialized["protocolVersion"] as? String == "2025-06-18" && initialized["resultType"] == nil
                && (initialized["capabilities"] as? [String: Any])?["tools"] != nil && handler.client == "claude-code",
            "a legacy client gets its version back with the tools capability: \(initialized)")
        let newer = try rpc(handler, "initialize", ["protocolVersion": "1999-01-01"])
        try Self.check(
            (newer["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25",
            "an unknown legacy version is answered with the newest legacy one")
        let discover = try Self.require(
            try rpc(handler, "server/discover", modern: "2026-07-28")["result"] as? [String: Any], "discover")
        try Self.check(
            (discover["supportedVersions"] as? [String])?.first == "2026-07-28"
                && discover["resultType"] as? String == "complete" && handler.client == "test-client",
            "server/discover lists the supported versions: \(discover)")
        let unsupported = try Self.require(
            try rpc(handler, "tools/list", modern: "2099-01-01")["error"] as? [String: Any], "version error")
        try Self.check(
            unsupported["code"] as? Int == -32022
                && ((unsupported["data"] as? [String: Any])?["supported"] as? [String])?.contains("2026-07-28") == true,
            "an unsupported version is refused with the supported list")
        let tools = try Self.require(
            (try rpc(handler, "tools/list", modern: "2026-07-28")["result"] as? [String: Any])?["tools"]
                as? [[String: Any]], "tools")
        try Self.check(
            tools.compactMap { $0["name"] as? String } == [
                "list_meetings", "search_meetings", "get_meeting", "get_transcript", "list_action_items",
                "get_current_meeting", "list_tags",
            ]
                && tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true },
            "the tools are listed in a fixed order and all only read")
        let unknownMethod = try rpc(handler, "nope")["error"] as? [String: Any]
        let unknownTool = try rpc(handler, "tools/call", ["name": "delete_everything"])["error"] as? [String: Any]
        try Self.check(
            unknownMethod?["code"] as? Int == -32601 && unknownTool?["code"] as? Int == -32602,
            "unknown methods and tools are protocol errors")
        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        try Self.check(handler.handle(notification) == nil, "notifications get no reply")
        let broken = try Self.require(handler.handle(Data("{oops".utf8)), "parse error reply")
        try Self.check(String(decoding: broken, as: UTF8.self).contains("-32700"), "malformed JSON is a parse error")
    }
    @MainActor func testMCPToolsReadMeetings() throws {
        let (store, root, meetings) = try mcpStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = MCPHandler(store: store)
        let id = meetings[0].id.uuidString

        let found = try callTool(handler, "list_meetings", ["query": "予算", "tag": "定例"])
        let listed = found.structured["meetings"] as? [[String: Any]] ?? []
        try Self.check(
            listed.count == 1 && listed[0]["id"] as? String == id
                && (listed[0]["snippet"] as? String)?.contains("予算") == true
                && found.text.contains("週次定例"),
            "list_meetings searches and filters by tag: \(found.text)")
        let meeting = try callTool(handler, "get_meeting", ["meeting_id": id])
        try Self.check(
            meeting.text.contains("## アジェンダ") && meeting.text.contains("書き出しまでを範囲にする")
                && meeting.text.contains("理由: 精度の検証が済んでいない")
                && (meeting.structured["actions"] as? [[String: Any]])?.count == 2,
            "get_meeting returns the minutes with reasons and the agenda: \(meeting.text)")
        let missing = try callTool(handler, "get_meeting", ["meeting_id": UUID().uuidString])
        try Self.check(missing.isError, "an unknown meeting is a tool error the model can act on")

        var transcript = try callTool(handler, "get_transcript", ["meeting_id": id, "max_characters": 1000])
        var pages = 1
        var seen = (transcript.structured["segments"] as? [Any])?.count ?? 0
        while let cursor = transcript.structured["next_cursor"] as? String {
            transcript = try callTool(
                handler, "get_transcript", ["meeting_id": id, "max_characters": 1000, "cursor": cursor])
            seen += (transcript.structured["segments"] as? [Any])?.count ?? 0
            pages += 1
        }
        try Self.check(pages > 1 && seen == 40, "a long transcript comes in pages that add up: \(pages) pages, \(seen)")
        let range = try callTool(handler, "get_transcript", ["meeting_id": id, "from_seconds": 120, "to_seconds": 144])
        try Self.check(
            (range.structured["segments"] as? [Any])?.count == 3 && range.text.hasPrefix("[02:00 マイク]"),
            "a time range returns only those utterances: \(range.text)")

        let open = try callTool(handler, "list_action_items", ["owner": "佐藤"])
        try Self.check(
            (open.structured["actions"] as? [[String: Any]])?.count == 2 && open.text.contains("FAQを更新する"),
            "open actions are listed across meetings with their owner: \(open.text)")
        let done = try callTool(handler, "list_action_items", ["status": "done"])
        try Self.check((done.structured["actions"] as? [Any])?.count == 1, "done actions can be listed")
        let idle = try callTool(handler, "get_current_meeting")
        try Self.check(idle.text == "録音中の会議はありません。", "nothing is being recorded")
        store.activeID = meetings[0].id
        store.recording = true
        store.meetings[0].capture = .recording
        store.meetings[0].agenda = MeetingAgenda.follow(
            store.meetings[0].agenda, AgendaTopic(item: store.meetings[0].agenda[1].id, since: 0))
        let current = try callTool(handler, "get_current_meeting")
        try Self.check(
            current.text.contains("今の議題: 2/2 範囲") && current.structured["recording"] as? Bool == true,
            "the meeting being recorded shows its current topic: \(current.text)")
        try Self.check(
            store.mcpAccesses.first?.tool == "get_current_meeting" && store.mcpAccesses.first?.client == "test-client",
            "each tool call is recorded for Settings")
    }
    @MainActor func testMCPSearchReturnsEveryMatchingPassage() throws {
        let (store, root, meetings) = try mcpStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = MCPHandler(store: store)
        let found = try callTool(handler, "search_meetings", ["query": "ＦＡＱ　佐藤", "passages_per_meeting": 3])
        let results = found.structured["results"] as? [[String: Any]] ?? []
        let passages = results.first?["passages"] as? [[String: Any]] ?? []
        try Self.check(
            results.count == 1 && results.first?["meeting_id"] as? String == meetings[0].id.uuidString
                && passages.map { $0["text"] as? String ?? "" } == ["FAQを更新する", "佐藤さん"],
            "every keyword is required, width and case are ignored, and matching items are returned: \(found.text)")
        let spoken = try callTool(handler, "search_meetings", ["query": "予算 範囲", "passages_per_meeting": 2])
        let utterances =
            (spoken.structured["results"] as? [[String: Any]])?.first?["passages"] as? [[String: Any]] ?? []
        try Self.check(
            utterances.count == 2 && utterances.allSatisfy { $0["source"] as? String == "マイク" }
                && utterances.first?["time_seconds"] as? Double == 0
                && spoken.text.contains("[文字起こし 00:00 マイク]"),
            "transcript passages carry their time and source, most keywords first: \(spoken.text)")
        let none = try callTool(handler, "search_meetings", ["query": "FAQ 存在しない"])
        try Self.check(
            (none.structured["results"] as? [Any])?.isEmpty == true && none.text.contains("すべて含む会議はありません"),
            "a keyword missing from every meeting finds nothing")
        let empty = try callTool(handler, "search_meetings", ["query": "  "])
        try Self.check(empty.isError, "a search without keywords asks for them")
        store.mcpIncludesTranscript = false
        store.toggleMCPHiddenTag("定例")
        let withheld = try callTool(handler, "search_meetings", ["query": "予算"])
        try Self.check(
            (withheld.structured["results"] as? [Any])?.isEmpty == true,
            "search honors the withheld transcript and tags")
    }
    @MainActor func testMCPKeepsWhatTheUserWithholds() throws {
        let (store, root, meetings) = try mcpStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = MCPHandler(store: store)
        let tagsBefore = try callTool(handler, "list_tags")
        try Self.check(tagsBefore.text.contains("非公開"), "before withholding, every tag is listed")
        store.toggleMCPHiddenTag("非公開")
        let listed = try callTool(handler, "list_meetings").structured["meetings"] as? [Any]
        let actions = try callTool(handler, "list_action_items", ["owner": "佐藤"]).structured["actions"] as? [Any]
        let tagsAfter = try callTool(handler, "list_tags")
        let hidden = try callTool(handler, "get_meeting", ["meeting_id": meetings[1].id.uuidString])
        try Self.check(
            listed?.count == 1 && actions?.count == 1 && !tagsAfter.text.contains("非公開") && hidden.isError,
            "a meeting with a withheld tag is invisible to every tool")
        store.mcpIncludesTranscript = false
        let transcript = try callTool(handler, "get_transcript", ["meeting_id": meetings[0].id.uuidString])
        let searched = try callTool(handler, "list_meetings", ["query": "発言39"]).structured["meetings"] as? [Any]
        try Self.check(
            transcript.isError && searched?.isEmpty == true,
            "without the transcript setting, neither the transcript nor a search of it reaches the AI app")
    }
    @MainActor func testMCPAnswersOverItsSocket() async throws {
        let (store, root, _) = try mcpStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcp-\(UUID().uuidString.prefix(8)).sock"
        ).path
        let server = MCPSocketServer(path: path) { MCPHandler(store: store) }
        var connections = 0
        server.onConnectionsChanged = { connections = $0 }
        try server.start()
        defer { server.stop() }
        var info = stat()
        try Self.check(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600, "only this user can open the socket")

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try Self.check(connected == 0, "the bridge can connect")
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let request =
            Data(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#.utf8) + Data([0x0A])
            + Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8) + Data([0x0A])
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, request.count) }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let deadline = Date().addingTimeInterval(5)
        while received.filter({ $0 == 0x0A }).count < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 { received.append(contentsOf: chunk[0..<count]) }
        }
        let lines = received.split(separator: 0x0A).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        try Self.check(
            lines.count == 2 && lines[0]["id"] as? String == "a"
                && (lines[1]["result"] as? [String: Any])?["tools"] != nil,
            "newline-delimited requests on the socket get their replies in order: \(lines)")
        try Self.check(connections == 1, "the open connection is counted for Settings")
        server.stop()
        try Self.check(access(path, F_OK) != 0, "stopping removes the socket")
    }
}
