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
        notes.content.actions = [NoteItem(id: "task", text: "納期を確認する", evidence: ["after"])]
        let markdown = MinutesEngine.render(notes, segments: [before, after], transcript: "原文")
        let decisionSection = markdown.components(separatedBy: "## 決定事項と理由\n")[1]
            .components(separatedBy: "\n## 未決事項")[0]
        try Self.check(
            !decisionSection.contains("A案") && decisionSection.contains("費用が低いため"),
            "obsolete choices leave the current decisions")
        try Self.check(
            markdown.contains("次の確認: 納期を確認する") && markdown.contains("## 議論の経緯"),
            "reason, next check and history are exported")
        let lastSection = markdown.components(separatedBy: "\n## ").last ?? ""
        try Self.check(
            lastSection.hasPrefix("アクションアイテム") && lastSection.contains("担当者: 未定 / 期限: 未定"),
            "actions come last, without invented assignments")
        let old = Data(#"{"id":"legacy","text":"旧項目","evidence":["before"],"state":"open"}"#.utf8)
        let decoded = try JSONDecoder().decode(NoteItem.self, from: old)
        try Self.check(
            decoded.reason == nil && decoded.nextStep == nil && decoded.changeSummary == nil,
            "old saved notes remain readable")
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
        let result = MinutesEngine.merge(
            notes, delta: delta, batch: [before], segments: [before, after], reviewing: true)
        try Self.check(
            result.content.decisions[0].text == "B案" && result.rejectedItems == 1,
            "earlier evidence cannot overwrite a later decision")
        try Self.check(
            result.content.actions[0].owner == nil && result.content.actions[0].due == nil,
            "review can explicitly clear withdrawn assignments")
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
        let result = try await MinutesEngine.review(notes, segments: [speech], settings: SessionSettings(), key: "TEST")
        try Self.check(result.content.actions.count == 1, "review rereads already summarized speech")
        let body = StructuredMockProtocol.body
        let instructions = body["instructions"] as? String ?? ""
        try Self.check(
            instructions.contains("巻き戻さない") && instructions.contains("仕上げ"),
            "review-specific instructions reach the API")
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        let schema = format?["schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let decisions = properties?["decisions"] as? [String: Any]
        let item = decisions?["items"] as? [String: Any]
        let required = item?["required"] as? [String] ?? []
        try Self.check(
            ["reason", "nextStep", "changeSummary"].allSatisfy(required.contains),
            "quality fields are in the strict API contract")
        StructuredMockProtocol.reset(
            delta: NotesDelta(decisions: [NoteItem(id: "", text: "架空の決定", evidence: ["missing"])]))
        let reviewed = try await MinutesEngine.review(
            notes, segments: [speech], settings: SessionSettings(), key: "TEST")
        try Self.check(
            reviewed.content.decisions.isEmpty && reviewed.rejectedItems == 1,
            "an item with invalid evidence is dropped and counted, and the review still moves on")

        // The stall seen on a 41-minute meeting: reviewing early speech, the model restates a decision that later
        // speech changed, citing only the early utterance. The later conclusion stays and the review moves on.
        let early = Segment(id: "early", time: 30, source: "マイク", text: "A案にしましょう")
        let late = Segment(id: "late", time: 1800, source: "マイク", text: "やはりB案に変更します")
        var decided = MinutesState()
        decided.appliedSegmentIDs = ["early", "late"]
        decided.content.decisions = [NoteItem(id: "d1", text: "B案にする", evidence: ["late"])]
        StructuredMockProtocol.reset(
            delta: NotesDelta(decisions: [NoteItem(id: "d1", text: "A案にする", evidence: ["early"])]))
        let earlyPass = try await MinutesEngine.review(
            decided, segments: [early, late], settings: SessionSettings(), key: "TEST")
        try Self.check(
            earlyPass.content.decisions.map(\.text) == ["B案にする"] && earlyPass.rejectedItems == 1,
            "an early review batch cannot roll back a later decision, and it does not stall the review")
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
        meeting.segments = (0..<25).map { Segment(id: "s\($0)", time: Double($0), source: "マイク", text: "発言\($0)") }
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
            }, recognize: { _, _, _, _ in throw AppError.message("must not transcribe") })
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
            recognize: { _, _, _, _ in throw AppError.message("audio must not be sent") },
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
