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
        // Narrowed to tags, the questions read only the meetings with any of them.
        let narrowed = MCPHandler(store: store, everything: true, tags: ["人事"])
        let inScope = MeetingAgent.text(ofTool: narrowed.callTool("search_meetings", arguments: ["query": "QB"]))
        let listed = MeetingAgent.text(ofTool: narrowed.callTool("list_meetings", arguments: [:]))
        try Self.check(
            inScope.contains("人事面談") && !inScope.contains("週次定例") && !listed.contains("週次定例"),
            "questions narrowed to a tag read only its meetings:\n\(inScope)\n\(listed)")
        store.askTags = ["人事", "消えたタグ"]
        try Self.check(
            store.askScope == ["人事"] && store.askScopeCount == 1
                && MeetingAgent.instructions(today: Date(), open: nil, recording: nil, tags: store.askScope)
                    .contains("タグ「人事」のどれかが付いた会議だけ"),
            "a tag no meeting has any more does not count, and the AI is told what it reads")
        store.toggleAskTag("人事")
        store.toggleAskTag("消えたタグ")
        try Self.check(store.askTags.isEmpty && store.askScopeCount == 2, "with no tags chosen, every meeting is read")
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
        var drafts: [String] = []
        let conversation = [
            AskMessage(role: .question, text: "前の質問"), AskMessage(role: .answer, text: "前の答え"),
            AskMessage(role: .failure, text: "通信できませんでした"), AskMessage(role: .question, text: "QBはどうなった？"),
        ]
        let answer = try await MeetingAgent.answer(
            conversation, instructions: "指示", model: "gpt-test",
            send: { body, text in
                requests.append(body)
                // Text before a tool call, then the answer in pieces as it streams.
                if requests.count == 1 {
                    text("調べます")
                } else {
                    text("来週までに")
                    text("直します")
                }
                return replies[min(requests.count, replies.count) - 1]
            },
            run: { MeetingAgent.text(ofTool: inApp.callTool($0, arguments: $1)) },
            progress: { steps.append($0) }, writing: { drafts.append($0) })
        try Self.check(answer.hasPrefix("来週までに直します") && requests.count == 2, "the answer comes after the tool call")
        try Self.check(
            drafts == ["調べます", "", "来週までに", "来週までに直します"],
            "the answer is shown as it is written, and text before a tool call goes again: \(drafts)")
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
                send: { body, _ in
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
        // A streamed response, line by line: pieces of the answer, then the whole response once it is finished.
        var pieces: [String] = []
        let lines = [
            "event: response.output_text.delta", #"data: {"type":"response.output_text.delta","delta":"来週"}"#, "",
            #"data: {"type":"response.output_text.delta","delta":"まで"}"#, "data: not json",
            #"data: {"type":"response.created","response":{"status":"in_progress"}}"#,
            #"data: {"type":"response.completed","response":{"status":"completed","output":[]}}"#,
        ]
        var finished: [String: Any]?
        for line in lines where finished == nil { finished = try MeetingAgent.read(line) { pieces.append($0) } }
        try Self.check(
            pieces == ["来週", "まで"] && finished?["status"] as? String == "completed",
            "a streamed answer arrives in pieces, and the whole response at the end: \(pieces)")
        var failures: [String] = []
        for line in [
            #"data: {"type":"response.failed","response":{"error":{"message":"上限に達しました"}}}"#,
            #"data: {"type":"error","message":"混み合っています"}"#,
        ] {
            do { _ = try MeetingAgent.read(line) { _ in } } catch { failures.append(error.localizedDescription) }
        }
        try Self.check(failures == ["上限に達しました", "混み合っています"], "a failed stream says why: \(failures)")
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
        store.selected = interview.id
        let leftThatMeeting = store.revealed == nil
        _ = store.openAskLink(atClock)
        _ = store.openAskLink(whole)
        try Self.check(
            leftThatMeeting && store.revealed == nil,
            "the utterance is marked only until another meeting is shown, and a link to a whole meeting marks none")
        // Only a web page opens outside the app: a link to a file or another app's scheme can only come from text in a
        // meeting telling the AI to write it.
        let file = try Self.require(URL(string: "file:///Applications/Calculator.app"), "a file link")
        let scheme = try Self.require(URL(string: "x-apple.systempreferences:com.apple.preference"), "an app link")
        try Self.check(
            AskLink.opensOnTheWeb(web) && !AskLink.opensOnTheWeb(file) && !AskLink.opensOnTheWeb(scheme),
            "only web links in an answer open outside the app")

        // An answer cut short by the length limit says so; a tool call with no ID cannot be answered, so it fails.
        let cut = try await MeetingAgent.answer(
            [AskMessage(role: .question, text: "まとめて")], instructions: "", model: "m",
            send: { _, _ in
                [
                    "status": "incomplete",
                    "output": [["type": "message", "content": [["type": "output_text", "text": "途中まで"]]]],
                ]
            },
            run: { _, _ in "" })
        var unanswerable = false
        do {
            _ = try await MeetingAgent.answer(
                [AskMessage(role: .question, text: "探して")], instructions: "", model: "m",
                send: { _, _ in ["status": "completed", "output": [["type": "function_call", "name": "list_tags"]]] },
                run: { _, _ in "" })
        } catch { unanswerable = true }
        try Self.check(
            cut.hasPrefix("途中まで") && cut.contains("打ち切られました") && unanswerable,
            "a cut-off answer is marked, and a call with no ID ends the answer: \(cut)")

        // A new conversation started while an answer is on its way gets nothing from it, and can be asked at once.
        try Self.check(URLProtocol.registerClass(SilentResponsesProtocol.self), "register the silent server")
        defer { URLProtocol.unregisterClass(SilentResponsesProtocol.self) }
        store.key = "TEST"
        store.asked = []
        store.ask("QBはどうなった？")
        try await Task.sleep(nanoseconds: 100_000_000)
        try Self.check(store.askStream.progress != nil, "the answer is on its way")
        store.clearAsked()
        store.ask("次の質問")
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterClearing = store.asked.map(\.text)
        store.clearAsked()
        try await Task.sleep(nanoseconds: 100_000_000)
        try Self.check(
            afterClearing == ["次の質問"] && store.asked.isEmpty && store.askStream.progress == nil,
            "the stopped answer leaves nothing in the new conversation: \(afterClearing)")
    }
}
/// Takes a request to the Responses API and never answers, like a model still thinking.
final class SilentResponsesProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path == "/v1/responses" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
private enum AskSecondsCheck {
    static var ok: Bool {
        AskLink.seconds("1:02:03") == 3723 && AskLink.seconds("90") == 90 && AskLink.seconds("-5") == nil
            && AskLink.seconds("12:ab") == nil && AskLink.seconds("1:2:3:4") == nil
    }
}
