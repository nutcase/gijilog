import Foundation

extension ProcessingTests {
    func testOnlyTheActiveInputStopsRecording() throws {
        try Self.check(
            Store.isCaptureInputLost("mic-1", isAudio: true, inUse: "mic-1"),
            "losing the microphone in use stops recording"
        )
        try Self.check(
            !Store.isCaptureInputLost("camera", isAudio: false, inUse: "mic-1")
                && !Store.isCaptureInputLost("headset", isAudio: true, inUse: "mic-1")
                && !Store.isCaptureInputLost(nil, isAudio: true, inUse: nil),
            "cameras and unused microphones can disconnect during a meeting")
    }
    @MainActor func testLiveSummaryRecoversAfterFailure() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        let meter = SummaryMeter()
        var meeting = Meeting(title: "live")  // Still recording.
        meeting.settings = SessionSettings()
        meeting.segments = [Segment(id: "first", time: 0, source: "マイク", text: "資料を確認します")]
        store.meetings = [meeting]
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            summarize: { state, segments, _, _ in
                let batch = MinutesEngine.batch(segments, state: state)
                if await meter.add(batch.map(\.id)) == 1 { throw AppError.message("injected summary failure") }
                return MinutesEngine.merge(state, delta: MinutesEngine.extract(batch), batch: batch, segments: segments)
            })
        store.pipeline.resume(meeting.id, key: "")
        store.pipeline.requestSummary(meeting.id)
        try await store.waitUntilIdle()
        try Self.check(
            store.pipeline.summaryFailed(meeting.id) && store.pipeline.summaryError(meeting.id) != nil
                && store.error == nil,
            "a failed live summary is shown with its reason on the meeting, without an alert pulling windows forward")
        store.error = nil
        store.pipeline.requestSummary(meeting.id)
        try await store.waitUntilIdle()
        let calls = await meter.batches.count
        try Self.check(calls == 1 && store.error == nil, "the live timer backs off quietly after a failure")
        store.pipeline.requestSummary(meeting.id, force: true)
        try await store.waitUntilIdle()
        try Self.check(
            !store.pipeline.summaryFailed(meeting.id) && store.pipeline.summaryError(meeting.id) == nil
                && store.meetings[0].notes?.appliedSegmentIDs == ["first"],
            "a later request recovers live minutes without restarting the recording")
    }
    func testCloudErrorDetailAndRetryAfter() throws {
        let url = try Self.require(URL(string: "https://api.openai.com/v1/responses"), "API URL")
        let seconds = try Self.require(
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7"]), "response"
        )
        let milliseconds = try Self.require(
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["retry-after-ms": "1500"]),
            "response")
        try Self.check(
            Processor.retryAfter(seconds) == 7 && Processor.retryAfter(milliseconds) == 1.5, "Retry-After is read")
        let body = Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-abc123XYZ. Check it."}}"#.utf8)
        let message = try Self.require(Processor.serverMessage(body), "API error message")
        try Self.check(
            message.contains("Incorrect API key") && !message.contains("abc123"),
            "API errors explain the cause without echoing the key")
        try Self.check(
            Processor.serverMessage(Data(#"{"error":"model 'x' not found"}"#.utf8)) == "model 'x' not found",
            "Ollama error strings are shown too")
        let limited = CloudFailure(code: 429, message: "Rate limit reached", retryAfter: 30)
        try Self.check(limited.localizedDescription.contains("Rate limit reached"), "the cause reaches the UI")
        try Self.check(
            Processor.retryDelay(after: limited, attempt: 1, base: { _ in 2 }) == 30
                && Processor.retryDelay(after: CloudFailure(code: 503, retryAfter: 600), attempt: 1, base: { _ in 2 })
                    == 120
                && Processor.retryDelay(after: CloudFailure(code: 503), attempt: 2, base: { _ in 4 }) == 4,
            "retries wait for the server, but never longer than two minutes")
    }
    @MainActor func testCheckpointsCoalesceAndSkipCleanMeetings() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        let busy = Meeting(title: "busy")
        let idle = Meeting(title: "idle")
        store.meetings = [busy, idle]
        try await store.checkpoint(busy.id)
        try await store.checkpoint(idle.id)
        for i in 0..<20 {
            store.change(busy.id) {
                $0.segments.append(Segment(id: "s\(i)", time: Double(i), source: "マイク", text: "発言"))
            }
        }
        let beforeFlush = try store.savedMeeting(busy.id)
        try Self.check(
            store.hasPendingWrites && beforeFlush.segments.isEmpty, "progress is not written on every change")
        await store.prepareForTermination()
        let busySaved = try store.savedMeeting(busy.id)
        let idleSaved = try store.savedMeeting(idle.id)
        try Self.check(
            busySaved.segments.count == 20 && busySaved.revision == 2, "twenty changes are written as one checkpoint")
        try Self.check(idleSaved.revision == 1, "quitting does not rewrite unchanged meetings")
        try Self.check(store.meetings[0].revision == 0, "saving does not republish the meeting list")
    }
    @MainActor func testRecoverySkipsSettledMeetings() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "settled")
        meeting.settings = SessionSettings()
        meeting.capture = .stopped
        meeting.hasAudio = false
        meeting.status = "録音なし"
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        let restarted = Store(root: root, loadSettings: false)  // No API key.
        await restarted.recover()
        try await restarted.waitUntilIdle()
        let saved = try restarted.savedMeeting(meeting.id)
        try Self.check(
            restarted.meetings[0].status == "録音なし" && saved.revision == 1,
            "a finished meeting without minutes is not recovered or rewritten on every launch")
    }
    func testExportHasOneTitleHeading() throws {
        var meeting = Meeting(title: "週次定例\n10/3")
        meeting.segments = [Segment(id: "a", time: 0, source: "マイク", text: "資料を確認します")]
        var notes = MinutesState()
        notes.appliedSegmentIDs = ["a"]
        notes.content.actions = [NoteItem(id: "x", text: "資料を確認", evidence: ["a"])]
        meeting.notes = notes
        let headings = (MinutesEngine.document(meeting) ?? "").components(separatedBy: "\n").filter {
            $0.hasPrefix("# ")
        }
        try Self.check(headings == ["# 週次定例 10/3"], "export has a single top-level heading: the title")
        meeting.notes = nil
        meeting.minutes = "# 議事録\n- 旧形式"
        let legacy = (MinutesEngine.document(meeting) ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        try Self.check(legacy.count == 1, "legacy minutes are demoted below the title")
        try Self.check(
            Store.exportFilename("週次: 定例/10月") == "週次- 定例-10月.md" && Store.exportFilename("  ") == "議事録.md",
            "the export filename comes from the title")
    }
    @MainActor func testDeleteMovesFolderAndBlocksLateWrites() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        // Tests remove the folder instead of filling the user's Trash.
        let store = Store(
            root: root, loadSettings: false, discardFolder: { try FileManager.default.removeItem(at: $0) })
        var kept = Meeting(title: "kept")
        var removed = Meeting(title: "removed")
        kept.capture = .stopped
        removed.capture = .stopped
        store.meetings = [removed, kept]
        store.selected = removed.id
        try await store.checkpoint(kept.id)
        try await store.checkpoint(removed.id)
        store.change(removed.id) { $0.title = "late change" }  // A coalesced write is still pending.
        let snapshot = store.meetings[0]
        let removedFolder = store.folder(removed.id)
        try Self.check(
            FileManager.default.fileExists(atPath: removedFolder.path), "the meeting folder exists before deletion")
        await store.delete(removed.id)
        await store.flushCheckpoints()
        try await store.repository.save(snapshot)
        try Self.check(
            !FileManager.default.fileExists(atPath: removedFolder.path),
            "a deleted meeting cannot be recreated by a late write")
        try Self.check(
            store.meetings.map(\.id) == [kept.id] && store.selected == kept.id,
            "deletion keeps the other meetings and moves the selection")
        store.activeID = kept.id
        await store.delete(kept.id)
        try Self.check(store.meetings.count == 1, "the recording meeting cannot be deleted")
    }
}
