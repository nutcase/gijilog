import Foundation

extension ProcessingTests {
    func testMinutesExplainDecisionsAndSeparateHistory() throws {
        let before = Segment(id: "before", time: 0, source: "Mac音声", text: "A案を検討します")
        let after = Segment(id: "after", time: 30, source: "マイク", text: "費用が低いB案に決定。納期を確認してから日程を決めます")
        var notes = MinutesState()
        notes.content.decisions = [
            NoteItem(
                id: "a", text: "A案", evidence: ["before", "after"], state: .cancelled, changeSummary: "A案からB案へ変更"),
            NoteItem(id: "b", text: "B案を採用", evidence: ["after"], reason: "費用が低いため"),
        ]
        notes.content.unresolved = [
            NoteItem(id: "u", text: "実施日程", evidence: ["after"], nextStep: "納期を確認する")
        ]
        notes.content.actions = [
            NoteItem(id: "task", text: "納期を確認する", evidence: ["after"]),
            NoteItem(id: "quote", text: "見積もりを送る", owner: "田中", due: "金曜", evidence: ["after"]),
        ]
        notes.content.summary = [
            NoteItem(
                id: "s1", text: "案の比較：費用が低いB案に決まった", evidence: ["after"], points: ["A案とB案のどちらにするか"],
                opinions: ["費用を優先すべき", "納期も確かめたい"]),
            NoteItem(id: "s2", text: "日程は納期の確認後に決める", evidence: ["after"]),
        ]
        let markdown = MinutesEngine.render(notes, segments: [before, after], transcript: "原文")
        try Self.check(
            markdown.contains(
                "## 要約\n\n### 要約1：案の比較\n\n**概要**\n- 費用が低いB案に決まった\n\n**主な論点**\n- A案とB案のどちらにするか"
                    + "\n\n**主な意見**\n- 費用を優先すべき\n- 納期も確かめたい\n\n### 要約2\n\n**概要**\n- 日程は納期の確認後に決める\n\n## ")
                && MinutesEngine.summaryTopic("比較：") == nil
                && MinutesEngine.summaryTopic(String(repeating: "長", count: 31) + "：結論") == nil,
            "each summary topic has its heading, overview, points and opinions; text without a short topic is all overview"
        )
        let decisionSection = markdown.components(separatedBy: "## 決定事項と理由\n")[1]
            .components(separatedBy: "\n## ")[0]
        try Self.check(
            !decisionSection.contains("A案") && decisionSection.contains("費用が低いため"),
            "obsolete choices leave the current decisions")
        try Self.check(
            markdown.contains("**次の確認**: 納期を確認する") && markdown.contains("## 議論の経緯"),
            "reason, next check and history are exported")
        let actions = markdown.components(separatedBy: "\n## アクションアイテム\n")[1].components(separatedBy: "\n## ")[0]
        try Self.check(
            actions.contains("担当者: 未定 / 期限: 未定") && actions.contains("担当者: **田中** / 期限: **金曜**")
                && !markdown.contains("変更の経緯")
                && markdown.components(separatedBy: "\n## ").last == "文字起こし\n原文",
            "actions carry no invented assignments, the change history stays in the app, the transcript comes last")
        let old = Data(#"{"id":"legacy","text":"旧項目","evidence":["before"],"state":"open"}"#.utf8)
        let decoded = try JSONDecoder().decode(NoteItem.self, from: old)
        try Self.check(
            decoded.reason == nil && decoded.nextStep == nil && decoded.changeSummary == nil,
            "old saved notes remain readable")
    }
    @MainActor func testSummaryTopicsKeepTheirPointsAndOpinions() async throws {
        let first = Segment(id: "a", time: 0, source: "マイク", text: "森バスの価格をどうするか。高すぎるという声もあります")
        let second = Segment(id: "b", time: 30, source: "Mac音声", text: "価格は据え置きにしましょう")
        var state = MinutesState()
        state.appliedSegmentIDs = ["a"]
        state.content.summary = [
            NoteItem(
                id: "summary-1", text: "価格：検討中", evidence: ["a"], points: ["森バスの価格をどうするか"], opinions: ["高すぎる"])
        ]
        let delta = NotesDelta(
            summary: [NoteItem(id: "summary-1", text: "価格：据え置きにする", evidence: ["b"], points: [" ", ""])],
            decisions: [NoteItem(id: "", text: "価格を据え置く", evidence: ["b"], points: ["論点"], opinions: ["意見"])])
        let merged = MinutesEngine.merge(state, delta: delta, batch: [second], segments: [first, second])
        try Self.check(
            merged.content.summary[0].text == "価格：据え置きにする" && merged.content.summary[0].points == ["森バスの価格をどうするか"]
                && merged.content.summary[0].opinions == ["高すぎる"] && merged.content.decisions[0].points == nil
                && merged.content.decisions[0].opinions == nil,
            "an update without points keeps the topic's, and only summary topics carry points and opinions")
        let many = MinutesEngine.grounded(
            NoteItem(id: "", text: "t", evidence: [], points: ["1", "2", "3", "4"]), known: [:], summary: true)
        try Self.check(many.points == ["1", "2", "3"], "at most three points are kept")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "定例")
        meeting.capture = .stopped
        meeting.status = "完了"
        meeting.segments = [first, second]
        meeting.notes = merged
        store.meetings = [meeting]
        try Self.check(
            MeetingSearch.items(meeting, terms: ["高すぎる"]) == ["summary-1"]
                && MeetingSearch.search(meeting, terms: ["高すぎる"])?.place == .minutes,
            "find in the meeting and the meeting search look in points and opinions")
        store.updateNoteItem(meeting.id, part: .summary, id: "summary-1") { $0[.points] = "モリバスの価格をどうするか\n\n値上げの時期" }
        let offer = try Self.require(store.correctionOffer, "an offer to fix the word elsewhere")
        try Self.check(
            store.meetings[0].notes?.content.summary[0].points == ["モリバスの価格をどうするか", "値上げの時期"]
                && store.meetings[0].notes?.content.summary[0].edited == true && offer.from == "森バス",
            "points are edited one per line, and a fixed word is offered for fixing elsewhere")
        store.applyOfferedCorrection()
        try Self.check(
            store.meetings[0].segments[0].text.hasPrefix("モリバス")
                && store.meetings[0].corrected(merged).content.summary[0].points?.first == "モリバスの価格をどうするか",
            "a correction reaches the transcript and the points")
        let saved = MinutesEngine.document(store.meetings[0], includesTranscript: false) ?? ""
        try Self.check(saved.contains("**主な論点**\n- モリバスの価格をどうするか\n- 値上げの時期"), "the edit is in 議事録.md")
    }
    // Actions are listed under the summary topic they came from: the one the AI named, or for older minutes the one
    // whose talk their evidence falls in; the rest come last under その他.
    func testActionsAreListedUnderTheirTopics() throws {
        let segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "SES案件の扱いを決めます"),
            Segment(id: "b", time: 120, source: "マイク", text: "SESは要領がわかる人も入れましょう"),
            Segment(id: "c", time: 300, source: "マイク", text: "資生堂の案件は渡辺さんと話します"),
            Segment(id: "d", time: 420, source: "マイク", text: "資生堂は来週もう一度"),
            Segment(id: "e", time: 2000, source: "マイク", text: "ところで別件です"),
        ]
        var notes = MinutesState()
        notes.content.summary = [
            NoteItem(id: "s1", text: "SES案件の扱い：受注候補を検討する", evidence: ["a", "b"]),
            NoteItem(id: "s2", text: "資生堂の案件：渡辺さんを交えて再検討する", evidence: ["c", "d"]),
        ]
        notes.content.actions = [
            NoteItem(id: "x1", text: "資生堂の案件について渡辺さんと話し合う", evidence: ["c"], topic: "資生堂の案件"),
            NoteItem(id: "x2", text: "SES案件の候補に要領がわかる人を加える", evidence: ["b"]),
            NoteItem(id: "x3", text: "別件を確認する", evidence: ["e"]),
            NoteItem(id: "x4", text: "SES案件の意見を聞く", evidence: ["e"], topic: "SES案件"),
        ]
        let known = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let groups = MinutesEngine.groupedByTopic(notes.content.actions, summary: notes.content.summary, known: known)
        try Self.check(
            groups.map(\.topic) == [0, 1, nil] && groups.map { $0.items.map(\.id) } == [["x2", "x4"], ["x1"], ["x3"]],
            "a named topic, or the talk an action's evidence falls in, places it; the rest come last: \(groups)")
        let markdown = MinutesEngine.render(notes, segments: segments)
        let actions = markdown.components(separatedBy: "## アクションアイテム\n")[1].components(separatedBy: "\n## ")[0]
        try Self.check(
            actions.hasPrefix("**1. SES案件の扱い**\n- [ ] SES案件の候補に")
                && actions.contains("\n\n**2. 資生堂の案件**\n- [ ] 資生堂の案件について")
                && actions.contains("\n\n**その他**\n- [ ] 別件を確認する"),
            "議事録.md lists the actions under their topics")
        let ungrouped = MinutesEngine.groupedByTopic(
            [NoteItem(id: "u", text: "手で足した作業", evidence: [])], summary: notes.content.summary, known: known)
        try Self.check(ungrouped.map(\.topic) == [nil], "an action with no evidence and no topic is in その他")
        let kept = MinutesEngine.grounded(
            NoteItem(id: "", text: "t", evidence: [], topic: " 資生堂の案件 "), known: known, summary: false)
        let dropped = MinutesEngine.grounded(
            NoteItem(id: "", text: "t", evidence: [], topic: "話題"), known: known, summary: true)
        try Self.check(
            kept.topic == "資生堂の案件" && dropped.topic == nil, "an item's topic is kept trimmed, not on a summary")
    }
    func testReviewCannotRollBackLaterEvidence() throws {
        let before = Segment(id: "before", time: 0, source: "マイク", text: "A案にします")
        let after = Segment(id: "after", time: 30, source: "マイク", text: "費用のためB案に変更。担当の田中さんと金曜の期限は取り消しです")
        var notes = MinutesState()
        notes.content.decisions = [NoteItem(id: "decision", text: "B案", evidence: ["after"], reason: "費用のため")]
        notes.content.actions = [NoteItem(id: "action", text: "納期を確認", owner: "田中", due: "金曜", evidence: ["before"])]
        let delta = NotesDelta(
            decisions: [NoteItem(id: "decision", text: "A案", evidence: ["before"])],
            actions: [NoteItem(id: "action", text: "納期を確認", evidence: ["after"])])
        let result = MinutesEngine.merge(notes, delta: delta, batch: [before], segments: [before, after])
        try Self.check(
            result.content.decisions[0].text == "B案" && result.rejectedItems == 2,
            "earlier evidence cannot overwrite a later decision, and an update needs new speech")
        let latest = Segment(id: "latest", time: 60, source: "マイク", text: "やはりC案に変更します")
        let changed = MinutesEngine.merge(
            notes, delta: NotesDelta(decisions: [NoteItem(id: "decision", text: "C案", evidence: ["latest"])]),
            batch: [latest], segments: [before, after, latest])
        try Self.check(
            changed.content.decisions[0].reason == nil, "a changed conclusion must not inherit an obsolete reason")
        let input = try MinutesEngine.input(notes, batch: [before], segments: [before, after])
        try Self.check(
            input.contains("supportingUtterances") && input.contains("B案に変更"),
            "review sees later supporting speech while inspecting an early batch")
    }
    func testReviewUsesStructuredQualityContract() async throws {
        try Self.check(URLProtocol.registerClass(StructuredMockProtocol.self), "register review mock")
        defer { URLProtocol.unregisterClass(StructuredMockProtocol.self) }
        StructuredMockProtocol.reset()
        let speech = Segment(id: "s", time: 0, source: "マイク", text: "納期を確認します")
        var notes = MinutesState()
        notes.appliedSegmentIDs = ["s"]
        notes.content.summary = [NoteItem(id: "draft", text: "会議中の下書き", evidence: ["s"])]
        let result = try await MinutesEngine.review(notes, segments: [speech], settings: SessionSettings(), key: "TEST")
        try Self.check(
            result.content.actions.count == 1 && result.content.summary.isEmpty,
            "the review rewrites the minutes from the whole transcript, replacing the live draft")
        let body = StructuredMockProtocol.body
        let instructions = body["instructions"] as? String ?? ""
        try Self.check(
            instructions.contains("書き直す") && instructions.contains("全項目を返す")
                && instructions.contains("発言の報告にせず") && (body["input"] as? String ?? "").contains("会議中の下書き"),
            "review-specific instructions and the draft reach the API")
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        let schema = format?["schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let decisions = properties?["decisions"] as? [String: Any]
        let item = decisions?["items"] as? [String: Any]
        let required = item?["required"] as? [String] ?? []
        try Self.check(
            ["reason", "nextStep", "changeSummary", "points", "opinions", "topic"].allSatisfy(required.contains)
                && instructions.contains("それだけ読んで何の件か分かるように")
                && properties?["agendaTopic"] == nil && instructions.contains("主な論点") && instructions.contains("主な意見"),
            "quality fields and a topic's points and opinions are in the strict API contract, without the live agenda fields"
        )
        StructuredMockProtocol.reset(
            delta: NotesDelta(decisions: [NoteItem(id: "", text: "架空の決定", evidence: ["missing"])]))
        // Its only item cites speech that does not exist.
        var emptied = true
        do {
            _ = try await MinutesEngine.review(notes, segments: [speech], settings: SessionSettings(), key: "TEST")
        } catch { emptied = false }
        try Self.check(!emptied, "a review that keeps nothing fails and leaves the live draft in place")
        StructuredMockProtocol.reset(
            delta: NotesDelta(
                summary: [NoteItem(id: "", text: "納期：確認する", evidence: ["s"])],
                actions: [
                    NoteItem(id: "x", text: "納期を確認", owner: "田中", due: "金曜", evidence: ["s"], changeSummary: "経緯")
                ]))
        let written = try await MinutesEngine.review(
            notes, segments: [speech], settings: SessionSettings(), key: "TEST")
        let action = try Self.require(written.content.actions.first, "rewritten action")
        try Self.check(
            written.content.summary.map(\.text) == ["納期：確認する"] && action.owner == nil && action.due == nil
                && action.changeSummary == nil && action.id.hasPrefix("action-") && written.rejectedItems == nil,
            "rewritten items are checked like live ones: no unspoken owner or deadline, no change history")
    }
    @MainActor func testFinalReviewDiscardsOutdatedResponse() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "遅れて到着した発言")
        meeting.capture = .stopped
        meeting.hasAudio = true
        meeting.finalReviewPending = true
        meeting.settings = SessionSettings()
        meeting.segments = [Segment(id: "first", time: 0, source: "マイク", text: "A案です")]
        var notes = MinutesState()
        notes.appliedSegmentIDs = ["first"]
        meeting.notes = notes
        store.meetings = [meeting]
        var reviews = 0
        store.pipeline = ProcessingPipeline(
            store: store,
            review: { state, _, _, _ in
                reviews += 1
                var result = state
                if reviews == 1 {
                    store.change(meeting.id) {
                        $0.segments.append(Segment(id: "late", time: 30, source: "マイク", text: "B案に変更です"))
                        $0.notes?.reviewedSegmentIDs = nil
                    }
                    result.content.summary = [NoteItem(id: "bad", text: "古い結果", evidence: ["first"])]
                } else {
                    result.content.summary = [NoteItem(id: "good", text: "B案に変更", evidence: ["late"])]
                }
                return result
            }, summarize: MinutesEngine.stubSummary)
        store.pipeline.resume(meeting.id, key: "TEST")
        try await store.waitUntilIdle()
        let result = try Self.require(store.meetings[0].notes, "reviewed notes")
        try Self.check(
            reviews == 2 && result.content.summary[0].text == "B案に変更",
            "an in-flight result cannot overwrite newer speech")
        try Self.check(
            result.reviewedSegmentIDs == ["first", "late"] && result.finalizedAt != nil,
            "the restarted review covers the new speech too")
    }
    @MainActor func testFinalReviewCheckpointsAndResumesWithoutAudio() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("save"), loadSettings: false)
        store.key = "TEST"
        var meeting = Meeting(title: "複数バッチの仕上げ")
        meeting.capture = .stopped
        meeting.hasAudio = true
        meeting.settings = SessionSettings()
        meeting.finalReviewPending = true
        // 25 long utterances: more than one request holds, so the review goes in two parts (20, then 5).
        let long = String(repeating: "あ", count: MinutesEngine.maxReviewCharacters / 20)
        meeting.segments = (0..<25).map { Segment(id: "s\($0)", time: Double($0), source: "マイク", text: long) }
        var notes = MinutesState()
        notes.appliedSegmentIDs = Set(meeting.segments.map(\.id))
        notes.content.summary = [NoteItem(id: "summary", text: "途中の議事録", evidence: ["s0"])]
        meeting.notes = notes
        store.meetings = [meeting]
        var calls = 0
        store.pipeline = ProcessingPipeline(
            store: store,
            review: { state, _, _, _ in
                calls += 1
                if calls == 2 { throw AppError.message("synthetic review failure") }
                return state
            })
        try await store.checkpoint(meeting.id)
        store.pipeline.resume(meeting.id, key: "TEST")
        try await store.waitUntilIdle()
        let saved = try store.savedMeeting(meeting.id)
        try Self.check(
            calls == 2 && saved.notes?.reviewedSegmentIDs?.count == 20 && saved.finalReviewPending == true,
            "successful review batches survive a later failure")
        try Self.check(
            saved.notes?.finalizedAt == nil && saved.notes?.content.summary[0].text == "途中の議事録",
            "failure preserves the draft, not a false completion")
        let restarted = Store(root: store.root, loadSettings: false)
        restarted.key = "TEST"
        var reviewed: [String] = []
        restarted.pipeline = ProcessingPipeline(
            store: restarted,
            review: { state, segments, _, _ in
                reviewed += MinutesEngine.reviewBatch(segments, state: state).map(\.id)
                return state
            }, recognize: { _, _, _, _, _ in throw AppError.message("must not transcribe") })
        await restarted.recover()
        try await restarted.waitUntilIdle()
        await restarted.waitForBackgroundWork()
        let completed = try restarted.savedMeeting(meeting.id)
        try Self.check(
            reviewed == (20..<25).map { "s\($0)" },
            "restart resumes at the remaining five utterances, even without working audio")
        try Self.check(
            completed.finalReviewPending == false && completed.notes?.finalizedAt != nil && completed.status == "完了",
            "only the completed sweep marks minutes finished")
    }
    @MainActor func testReviewWaitsForRecordingAndPendingTranscription() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "録音中")
        meeting.settings = SessionSettings()
        meeting.finalReviewPending = true
        meeting.hasAudio = true
        meeting.segments = [Segment(id: "s", time: 0, source: "マイク", text: "確認します")]
        var notes = MinutesState()
        notes.appliedSegmentIDs = ["s"]
        meeting.notes = notes
        store.meetings = [meeting]
        var reviews = 0
        store.pipeline = ProcessingPipeline(
            store: store,
            review: { state, _, _, _ in
                reviews += 1
                return state
            })
        store.pipeline.resume(meeting.id, key: "TEST")
        store.pipeline.requestSummary(meeting.id)
        try await store.waitUntilIdle()
        try Self.check(reviews == 0 && !store.isComplete(store.meetings[0]), "no final review during recording")
        store.change(meeting.id) {
            $0.capture = .stopped
            $0.jobs = [
                TranscriptionJob(
                    id: "pending", filename: "absent", offset: 12, source: "マイク",
                    retryAfter: Date().addingTimeInterval(60))
            ]
        }
        store.pipeline.pump()
        try Self.check(
            reviews == 0 && !store.isComplete(store.meetings[0]),
            "pending transcription and review block completion and audio cleanup")
        store.pipeline.pause(terminal: true)
        await store.flushCheckpoints()
    }
    @MainActor func testRefineSavedTranscriptWithoutRetranscription() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        store.key = "TEST"
        var attempts = 0
        var meeting = Meeting(title: "保存済み")
        meeting.capture = .stopped
        meeting.hasAudio = true
        meeting.segments = [Segment(id: "s", time: 0, source: "マイク", text: "資料を確認します")]
        store.meetings = [meeting]
        store.pipeline = ProcessingPipeline(
            store: store,
            review: { state, _, _, _ in
                attempts += 1
                if attempts == 1 { throw AppError.message("synthetic failure") }
                return state
            },
            recognize: { _, _, _, _, _ in throw AppError.message("audio must not be sent") },
            summarize: MinutesEngine.stubSummary)
        await store.refineMinutes(meeting.id)
        try await store.waitUntilIdle()
        try Self.check(store.pipeline.summaryFailed(meeting.id), "failed refinement remains resumable")
        await store.process(meeting.id)
        try await store.waitUntilIdle()
        try Self.check(attempts == 2, "resume retries final review without looking for audio")
        let saved = try store.savedMeeting(meeting.id)
        try Self.check(
            saved.jobs.isEmpty && saved.segments == meeting.segments && saved.notes?.finalizedAt != nil,
            "refining an archive only uses its saved transcript")
    }
}
