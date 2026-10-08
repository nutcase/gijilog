import Foundation

extension ProcessingTests {
    // Questions about the meetings: the AI reads them with the MCP tools, over every meeting, and answers with links.
    @MainActor func testQuestionsAreAnsweredFromEveryMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var weekly = Meeting(title: "週次定例")
        weekly.capture = .stopped
        weekly.segments = [
            Segment(id: "a", time: 754, source: "マイク", text: "QBの指摘は来週までに直します"),
            Segment(id: "b", time: 800, source: "マイク", text: "では次の話題です"),
        ]
        var interview = Meeting(title: "人事面談")
        interview.capture = .stopped
        interview.tags = ["人事"]
        interview.segments = [Segment(id: "h", time: 30, source: "マイク", text: "QBの担当を決めます")]
        store.meetings = [weekly, interview]
        store.mcpHiddenTags = ["人事"]
        store.mcpIncludesTranscript = false

        let names = Set(MeetingAgent.tools.compactMap { $0["name"] as? String })
        try Self.check(
            names == Set(MCPHandler.tools.compactMap { $0["name"] as? String })
                && MeetingAgent.tools.allSatisfy { $0["type"] as? String == "function" && $0["parameters"] != nil },
            "the AI is given the same tools AI apps get over MCP")

        // What the settings keep from AI apps outside ギジログ is not kept from the app's own questions.
        let inApp = MCPHandler(store: store, everything: true)
        let outside = MCPHandler(store: store)
        let everyMeeting = MeetingAgent.text(ofTool: inApp.callTool("search_meetings", arguments: ["query": "QB"]))
        let shown = MeetingAgent.text(ofTool: outside.callTool("search_meetings", arguments: ["query": "QB"]))
        try Self.check(
            everyMeeting.contains("週次定例") && everyMeeting.contains("人事面談") && !shown.contains("人事面談")
                && !shown.contains("週次定例"),
            "the app's questions read every meeting and its transcript; AI apps keep to the settings:\n\(everyMeeting)")
        let accesses = store.mcpAccesses.count
        _ = inApp.callTool("list_tags", arguments: [:])
        try Self.check(
            store.mcpAccesses.count == accesses
                && inApp.callTool("delete_meeting", arguments: [:])["isError"] as? Bool == true,
            "the app's own reading is not logged as an AI app's, and only the reading tools exist")

        // A tool call, then the answer: the call and the reasoning behind it go back with the tool's result.
        let link = "gijilog://meeting/\(weekly.id.uuidString)?t=754"
        let replies: [[String: Any]] = [
            [
                "status": "completed",
                "output": [
                    ["type": "reasoning", "id": "rs_1", "encrypted_content": "secret", "summary": []],
                    [
                        "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "search_meetings",
                        "arguments": "{\"query\":\"QB\"}",
                    ],
                ],
            ],
            [
                "status": "completed",
                "output": [
                    [
                        "type": "message", "role": "assistant",
                        "content": [["type": "output_text", "text": "来週までに直します（[10/7 週次定例 12:34](\(link))）。"]],
                    ]
                ],
            ],
        ]
        var requests: [[String: Any]] = []
        var steps: [String] = []
        let conversation = [
            AskMessage(role: .question, text: "前の質問"), AskMessage(role: .answer, text: "前の答え"),
            AskMessage(role: .failure, text: "通信できませんでした"), AskMessage(role: .question, text: "QBはどうなった？"),
        ]
        let answer = try await MeetingAgent.answer(
            conversation, instructions: "指示", model: "gpt-test",
            send: { body in
                requests.append(body)
                return replies[min(requests.count, replies.count) - 1]
            },
            run: { MeetingAgent.text(ofTool: inApp.callTool($0, arguments: $1)) },
            progress: { steps.append($0) })
        try Self.check(answer.hasPrefix("来週までに直します") && requests.count == 2, "the answer comes after the tool call")
        let first = requests[0]["input"] as? [[String: Any]] ?? []
        try Self.check(
            requests[0]["model"] as? String == "gpt-test" && requests[0]["store"] as? Bool == false
                && (requests[0]["include"] as? [String]) == ["reasoning.encrypted_content"]
                && first.map { $0["role"] as? String } == ["user", "assistant", "user"]
                && first.last?["content"] as? String == "QBはどうなった？",
            "earlier questions and answers are context, a failure is not: \(first)")
        let second = requests[1]["input"] as? [[String: Any]] ?? []
        let result = second.last ?? [:]
        try Self.check(
            second.count == 6 && second[3]["encrypted_content"] as? String == "secret"
                && second[4]["call_id"] as? String == "call_1" && result["type"] as? String == "function_call_output"
                && result["call_id"] as? String == "call_1" && (result["output"] as? String)?.contains("週次定例") == true,
            "the reasoning and the call go back with what the tool returned: \(second)")
        try Self.check(steps == ["「QB」で会議を探しています", "考えています"], "the tab says what is being read: \(steps)")

        // A model that keeps calling tools is made to answer in the last round.
        var choices: [String?] = []
        do {
            _ = try await MeetingAgent.answer(
                [AskMessage(role: .question, text: "全部調べて")], instructions: "", model: "m",
                send: { body in
                    choices.append(body["tool_choice"] as? String)
                    return replies[0]
                },
                run: { _, _ in "" })
            try Self.check(false, "an answer that never comes is an error")
        } catch {
            try Self.check(
                choices.count == MeetingAgent.maxRounds && choices.last == "none"
                    && choices.dropLast().allSatisfy { $0 == nil },
                "tool calls stop after \(MeetingAgent.maxRounds) rounds: \(choices)")
        }
        var refused = false
        do {
            _ = try MeetingAgent.text(of: [
                ["type": "message", "content": [["type": "refusal", "refusal": "答えられません"]]]
            ])
        } catch { refused = error.localizedDescription == "答えられません" }
        try Self.check(refused, "a refusal is shown as it is")

        // A link in an answer opens the meeting at the utterance it points to.
        let id = weekly.id
        let atSeconds = try Self.require(URL(string: link), "a link")
        let atClock = try Self.require(URL(string: "gijilog://meeting/\(id.uuidString)?t=12:40"), "a link with a clock")
        let whole = try Self.require(URL(string: "gijilog://meeting/\(id.uuidString)"), "a link to a meeting")
        let web = try Self.require(URL(string: "https://example.com/meeting/\(id.uuidString)"), "a web link")
        try Self.check(
            AskLink(atSeconds) == AskLink(meetingID: id, seconds: 754)
                && AskLink(atClock) == AskLink(meetingID: id, seconds: 760) && AskLink(whole) == AskLink(meetingID: id)
                && AskLink(web) == nil && AskSecondsCheck.ok,
            "links name a meeting, and a moment in seconds or as a clock")
        // The questions open in place of a meeting, and choosing a meeting, or following a link, leaves them.
        store.selected = interview.id
        store.openAsk()
        try Self.check(store.askOpen && store.selected == nil, "the questions take the place of the meeting shown")
        store.selected = weekly.id
        try Self.check(!store.askOpen, "choosing a meeting in the list leaves the questions")
        store.openAsk()
        try Self.check(
            store.openAskLink(atClock) && store.selected == id && !store.askOpen && store.revealed?.segmentID == "a"
                && !store.openAskLink(web),
            "a link opens its meeting and shows the utterance under way at that moment")
    }
}
private enum AskSecondsCheck {
    static var ok: Bool {
        AskLink.seconds("1:02:03") == 3723 && AskLink.seconds("90") == 90 && AskLink.seconds("-5") == nil
            && AskLink.seconds("12:ab") == nil && AskLink.seconds("1:2:3:4") == nil
    }
}
