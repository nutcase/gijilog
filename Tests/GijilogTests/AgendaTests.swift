import Foundation

extension ProcessingTests {
    func testAgendaParsesPastedText() throws {
        let pasted = """
            1. 先週のアクションの確認（5分）
            2) 来月のリリース範囲 15 min

            ・問い合わせ対応の分担 10分
            ① 料金ページの文言
            (3) 採用の進め方（１０分）
            - 2026年計画
            * 3分間スピーチ
            """
        let items = MeetingAgenda.parse(pasted)
        try Self.check(
            items.map(\.title) == [
                "先週のアクションの確認", "来月のリリース範囲", "問い合わせ対応の分担", "料金ページの文言", "採用の進め方", "2026年計画",
                "3分間スピーチ",
            ], "bullets and numbering are dropped and blank lines skipped: \(items.map(\.title))")
        try Self.check(
            items.map(\.minutes) == [5, 15, 10, nil, 10, nil, nil],
            "a trailing length becomes the planned minutes: \(items.map(\.minutes))")
        try Self.check(MeetingAgenda.parse(" \n・\n ").isEmpty, "lines without a topic add nothing")
    }
    func testAgendaFollowsTheMeeting() throws {
        func spans(_ items: [AgendaItem]) -> [[Double?]] { items.map { $0.spans.flatMap { [$0.start, $0.end] } } }
        func topic(_ index: Int, _ since: Double) -> AgendaTopic { AgendaTopic(item: agenda[index].id, since: since) }
        var agenda = MeetingAgenda.parse("確認\n範囲\n分担")
        try Self.check(MeetingAgenda.currentIndex(agenda) == nil, "no topic is under way until the talk reaches one")
        agenda = MeetingAgenda.follow(agenda, topic(0, 45))
        try Self.check(spans(agenda) == [[45, nil], [], []], "a topic starts when its talk began, not at recording")
        agenda = MeetingAgenda.follow(agenda, topic(1, 240))
        try Self.check(spans(agenda) == [[45, 240], [240, nil], []], "a new topic takes over when its talk began")
        agenda = MeetingAgenda.follow(agenda, topic(0, 255))
        try Self.check(spans(agenda) == [[45, nil], [], []], "a judgment reversed within moments leaves no trace")
        agenda = MeetingAgenda.follow(agenda, topic(1, 300))
        agenda = MeetingAgenda.follow(agenda, topic(2, 700))
        agenda = MeetingAgenda.follow(agenda, topic(0, 1000))
        try Self.check(
            spans(agenda) == [[45, 300, 1000, nil], [300, 700], [700, 1000]],
            "a topic the meeting returns to gets another span: \(spans(agenda))")
        try Self.check(agenda[0].spent(now: 1060) == 315, "time on a topic adds up its spans")
        agenda = MeetingAgenda.follow(agenda, topic(0, 1100))
        try Self.check(spans(agenda)[0] == [45, 300, 1000, nil], "the topic under way stays as it is")
        agenda = MeetingAgenda.follow(agenda, topic(1, 900))
        try Self.check(spans(agenda)[0].last == 1000, "a switch never reaches back before the current topic began")
        agenda = MeetingAgenda.finish(agenda, at: 1600)
        try Self.check(
            MeetingAgenda.currentIndex(agenda) == nil && agenda[1].spans.last?.end == 1600,
            "stopping the recording ends the topic under way")
        try Self.check(
            MeetingAgenda.duration(20) == "1分未満" && MeetingAgenda.duration(290) == "5分", "durations read naturally")
    }
    func testMinutesModelJudgesTheTopic() throws {
        let agenda = MeetingAgenda.parse("確認\n範囲")
        let batch = [
            Segment(id: "a", time: 120, source: "マイク", text: "では範囲の話に移ります"),
            Segment(id: "b", time: 132, source: "Mac音声", text: "書き出しまでにしましょう"),
        ]
        var state = MinutesState()
        state.agenda = MeetingAgenda.follow(agenda, AgendaTopic(item: agenda[0].id, since: 0))
        let input = try MinutesEngine.input(state, batch: batch)
        try Self.check(
            input.contains(agenda[1].id.uuidString) && input.contains("currentAgendaTopic"),
            "the live update is told the agenda and the topic under way")
        let plainInput = try MinutesEngine.input(MinutesState(), batch: batch)
        try Self.check(!plainInput.contains("agenda"), "a meeting without an agenda sends none")
        let answer = #"{"agendaTopic":"\#(agenda[1].id.uuidString)","agendaSince":"a"}"#
        try Self.check(
            MinutesEngine.topic(in: answer, agenda: agenda, batch: batch)
                == AgendaTopic(item: agenda[1].id, since: 120),
            "the named topic starts at the utterance the model named")
        let unknownStart = #"{"agendaTopic":"\#(agenda[1].id.uuidString)","agendaSince":"zzz"}"#
        try Self.check(
            MinutesEngine.topic(in: unknownStart, agenda: agenda, batch: batch)?.since == 120,
            "an unknown start falls back to the first new utterance")
        try Self.check(
            MinutesEngine.topic(in: #"{"agendaTopic":null,"agendaSince":null}"#, agenda: agenda, batch: batch) == nil
                && MinutesEngine.topic(
                    in: #"{"agendaTopic":"\#(UUID().uuidString)","agendaSince":"a"}"#, agenda: agenda, batch: batch)
                    == nil,
            "no topic, or one not on the agenda, changes nothing")
        let schema = MinutesEngine.schema
        let required = schema["required"] as? [String] ?? []
        try Self.check(
            required.contains("agendaTopic") && required.contains("agendaSince"), "the answer always carries the topic")
    }
    @MainActor func testPreparedMeetingWaitsWithItsAgenda() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        store.key = "TEST"
        store.title = "週次定例"
        store.planMeeting()
        let id = try Self.require(store.selected, "the prepared meeting is selected")
        try Self.check(
            store.meetings[0].capture == .planned && store.meetings[0].status == "準備中" && store.title.isEmpty
                && store.addingAgenda == id,
            "preparing a meeting lists it as 準備中 with the agenda field open")
        store.addAgenda("1. 確認（5分）\n2. 範囲", to: id)
        store.renamePlannedMeeting(id, to: "週次プロダクト定例")
        store.refreshCompletion(id, summaryFailed: false)
        await store.process(id)
        await store.flushCheckpoints()
        try Self.check(
            store.meetings[0].status == "準備中" && store.meetings[0].jobs.isEmpty,
            "a prepared meeting is never completed or processed")

        let reopened = Store(root: root, loadSettings: false)
        await reopened.recover()
        let saved = try Self.require(reopened.meetings.first { $0.id == id }, "prepared meeting after restart")
        try Self.check(
            saved.capture == .planned && saved.status == "準備中" && saved.title == "週次プロダクト定例"
                && saved.agenda.map(\.title) == ["確認", "範囲"],
            "a restart leaves a prepared meeting and its agenda alone")
        let document = try String(
            contentsOf: reopened.folder(id).appendingPathComponent(MeetingRepository.documentName), encoding: .utf8)
        try Self.check(
            document == "# 週次プロダクト定例\n\n## アジェンダ\n1. 確認（予定5分）\n2. 範囲\n",
            "議事録.md holds the agenda before the meeting: \(document)")
    }
    @MainActor func testAgendaRecordsWhereTheTimeWent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "定例")
        meeting.agenda = MeetingAgenda.parse("確認（5分）\n範囲\n分担")
        meeting.segments = [Segment(id: "s1", time: 3, source: "マイク", text: "始めます")]
        store.meetings = [meeting]
        let items = meeting.agenda
        store.followAgenda(meeting.id, AgendaTopic(item: items[0].id, since: 0))
        try Self.check(store.meetings[0].agenda[0].progress == .pending, "only the meeting being recorded follows")
        store.activeID = meeting.id
        store.recording = true
        store.followAgenda(meeting.id, AgendaTopic(item: items[0].id, since: 0))
        store.followAgenda(meeting.id, AgendaTopic(item: items[1].id, since: 400))
        store.addAgenda("追加の議題", to: meeting.id)
        try Self.check(
            store.meetings[0].agenda.count == 4 && MeetingAgenda.currentIndex(store.meetings[0].agenda) == 1,
            "a topic added mid-meeting waits until the talk reaches it")
        let document = try Self.require(MinutesEngine.document(store.meetings[0]), "document")
        try Self.check(
            document.contains("## アジェンダ\n1. 確認（予定5分・実際7分・済み）\n2. 範囲（途中）\n3. 分担（未着手）\n4. 追加の議題（未着手）\n"),
            "議事録.md shows planned and actual time and where each topic got to: \(document)")
        try Self.check(
            MeetingSearch.search(store.meetings[0], terms: ["分担"])?.place == .agenda, "the agenda is searched")

        // The live minutes update carries the agenda and applies the topic the model judged.
        let third = store.meetings[0].agenda[2].id
        var sent: [AgendaItem] = []
        store.key = "TEST"
        store.meetings[0].capture = .recording
        store.meetings[0].settings = SessionSettings()
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            recognize: { _, offset, source, _, _ in [Segment(time: offset, source: source, text: "分担を決めます")] },
            summarize: { previous, segments, settings, key in
                sent = previous.agenda
                var result = try await MinutesEngine.stubSummary(previous, segments, settings, key)
                result.topic = AgendaTopic(item: third, since: 900)
                return result
            })
        store.pipeline.resume(meeting.id, key: "TEST")
        store.pipeline.requestSummary(meeting.id, force: true)
        try await store.waitUntilIdle()
        let agenda = store.meetings[0].agenda
        try Self.check(sent.count == 4, "the update is told the agenda")
        try Self.check(
            MeetingAgenda.currentIndex(agenda) == 2 && agenda[2].spans.first?.start == 900
                && agenda[1].spans.last?.end == 900,
            "the topic the model judged takes over from when that talk began")
        try Self.check(store.meetings[0].notes?.topic == nil, "the judgment itself is not kept with the notes")

        var plain = Meeting(title: "定例")
        plain.segments = meeting.segments
        try Self.check(
            MinutesEngine.document(plain) == "# 定例\n\n## 文字起こし\n\n[00:03 / マイク] 始めます",
            "a meeting without an agenda is written exactly as before")
    }
}
