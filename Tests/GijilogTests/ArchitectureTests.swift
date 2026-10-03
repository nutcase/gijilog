import AVFoundation
import Foundation
import ScreenCaptureKit

extension ProcessingTests {
    actor SummaryMeter {
        var batches: [[String]] = []
        func add(_ batch: [String]) -> Int {
            batches.append(batch)
            return batches.count
        }
    }
    @MainActor func testSummaryCoalescesLatestUtterances() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        let gate = Gate()
        let meter = SummaryMeter()
        var meeting = Meeting(title: "coalesce")
        meeting.settings = SessionSettings()
        meeting.segments = [Segment(id: "first", time: 0, source: "マイク", text: "資料を確認します")]
        store.meetings = [meeting]
        store.pipeline = ProcessingPipeline(
            store: store,
            summarize: { state, segments, _, _ in
                let batch = MinutesEngine.batch(segments, state: state)
                let count = await meter.add(batch.map(\.id))
                if count == 1 { await gate.wait() }
                return MinutesEngine.merge(
                    state, delta: MinutesEngine.extract(batch), batch: batch, segments: segments)
            })
        store.pipeline.resume(meeting.id, key: "")
        store.pipeline.requestSummary(meeting.id)
        while await meter.batches.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        store.change(meeting.id) {
            $0.segments.append(Segment(id: "second", time: 30, source: "マイク", text: "次の内容も確認します"))
        }
        store.pipeline.requestSummary(meeting.id)
        store.pipeline.requestSummary(meeting.id)
        await gate.release()
        try await store.waitUntilIdle()
        let batches = await meter.batches
        try Self.check(
            batches == [["first"], ["second"]],
            "in-flight updates coalesce and process the latest delta without resending old speech")
        try Self.check(
            store.meetings[0].notes?.appliedSegmentIDs == ["first", "second"], "busy summaries do not lose newer speech"
        )
    }
    @MainActor func testFullReprocessBacksUpAndReplacesOldNotes() async throws {
        let (root, audio) = try fixture(seconds: 1, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("meetings"), loadSettings: false)
        store.key = "TEST"
        var meeting = Meeting(title: "rebuild")
        meeting.settings = SessionSettings()
        meeting.capture = .stopped
        let jobID = stableID("system.caf")
        meeting.jobs = [
            TranscriptionJob(id: jobID, filename: "system.caf", offset: 0, source: "Mac音声", state: .completed)
        ]
        meeting.segments = [Segment(id: jobID + ":0", time: 0, source: "Mac音声", text: "古い内容を確認します")]
        var notes = MinutesState()
        notes.appliedSegmentIDs = [jobID + ":0"]
        notes.content.actions = [NoteItem(id: "old-action", text: "古い内容を確認", evidence: [jobID + ":0"])]
        meeting.notes = notes
        meeting.minutes = MinutesEngine.render(notes, segments: meeting.segments)
        store.meetings = [meeting]
        store.selected = meeting.id
        try await store.checkpoint(meeting.id)
        try FileManager.default.copyItem(at: audio, to: store.folder(meeting.id).appendingPathComponent("system.caf"))
        store.pipeline = ProcessingPipeline(
            store: store,
            recognize: { _, offset, source, _ in
                [Segment(time: offset, source: source, text: "新しい内容を確認します")]
            }, summarize: MinutesEngine.stubSummary)
        await store.process(rebuild: true)
        try await store.waitUntilIdle()
        let updated = store.meetings[0]
        try Self.check(
            updated.segments.count == 1 && updated.minutes.contains("新しい内容") && !updated.minutes.contains("古い内容"),
            "full replay cannot retain old transcript or stale summary cursor")
        let backup = try JSONDecoder().decode(
            Meeting.self,
            from: Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.before-reprocess.json")))
        try Self.check(
            backup.minutes == meeting.minutes && backup.segments[0].text == meeting.segments[0].text,
            "previous transcript and notes survive in a backup")
    }
    @MainActor func testRetryBudgetAndMissingChunkIsolation() async throws {
        let (root, audio) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("budget"), loadSettings: false)
        let meter = QueueMeter()
        var meeting = Meeting(title: "budget")
        meeting.settings = SessionSettings()
        meeting.jobs = [
            TranscriptionJob(id: "transient", filename: "transient.caf", offset: 0, source: "マイク"),
            TranscriptionJob(id: "auth", filename: "auth.caf", offset: 1, source: "マイク"),
        ]
        store.meetings = [meeting]
        store.pipeline = ProcessingPipeline(
            store: store,
            recognize: { url, _, _, _ in
                _ = await meter.begin(url.lastPathComponent)
                await meter.end()
                throw CloudFailure(code: url.lastPathComponent == "auth.caf" ? 401 : 503)
            }, retryDelay: { _ in 0.01 })
        store.pipeline.resume(meeting.id, key: "TEST")
        try await store.waitUntilIdle()
        let calls = await meter.calls
        try Self.check(
            calls["transient.caf"] == 3 && calls["auth.caf"] == 1,
            "retry budget is bounded and authentication errors are not retried")
        try Self.check(
            store.meetings[0].jobs.allSatisfy { $0.state == .failed }, "exhausted work remains visible and resumable")

        let restored = Store(root: root.appendingPathComponent("missing"), loadSettings: false)
        restored.key = "TEST"  // Recovery resumes cloud work only when a key is saved.
        var interrupted = Meeting(title: "missing")
        interrupted.settings = SessionSettings()
        restored.meetings = [interrupted]
        try await restored.checkpoint(interrupted.id)
        let folder = restored.folder(interrupted.id)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audio, to: folder.appendingPathComponent("chunks/valid.caf"))
        let manifest = RecordingManifest(chunks: [
            RecordedChunk(filename: "missing.caf", offset: 0, source: "マイク"),
            RecordedChunk(filename: "valid.caf", offset: 1, source: "マイク"),
        ])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("recording.json"))
        restored.pipeline = ProcessingPipeline(
            store: restored,
            recognize: { url, _, _, _ in
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileReadNoSuchFile) }
                return []  // Silent fixture, no Apple permission or real API is involved.
            })
        await restored.recover()
        try await restored.waitUntilIdle()
        let jobs = restored.meetings[0].jobs
        try Self.check(
            jobs.count == 2 && jobs.filter { $0.state == .failed }.count == 1
                && jobs.filter { $0.state == .completed }.count == 1,
            "one missing chunk does not block recovery of other audio")
    }
    func testIncrementalNotesAndEvidenceValidation() throws {
        let old = Segment(id: "old", time: 0, source: "Mac音声", text: "佐藤さんが金曜日までに資料を確認します。OLD_TRANSCRIPT_ONLY")
        let new = Segment(id: "new", time: 30, source: "マイク", text: "資料の確認が完了しました")
        var state = MinutesState()
        state.appliedSegmentIDs = [old.id]
        state.content.actions = [NoteItem(id: "task-1", text: "資料を確認", owner: "佐藤", due: "金曜日", evidence: [old.id])]
        let batch = MinutesEngine.batch([old, new], state: state)
        try Self.check(batch.map(\.id) == ["new"], "only new utterances enter the summary batch")
        let input = try MinutesEngine.input(state, batch: batch)
        try Self.check(!input.contains("OLD_TRANSCRIPT_ONLY"), "old transcript must not be resent")
        let change = NotesDelta(actions: [NoteItem(id: "task-1", text: "資料を確認", evidence: [new.id], state: .done)])
        let merged = MinutesEngine.merge(state, delta: change, batch: batch, segments: [old, new])
        try Self.check(
            merged.content.actions.count == 1 && merged.content.actions[0].id == "task-1", "task IDs survive updates")
        try Self.check(
            merged.content.actions[0].owner == "佐藤" && merged.content.actions[0].due == "金曜日",
            "omitted fields preserve known owner and deadline")
        try Self.check(
            Set(merged.content.actions[0].evidence) == ["old", "new"], "original and completion evidence both survive")
        let omitted = MinutesEngine.merge(state, delta: NotesDelta(), batch: batch, segments: [old, new])
        try Self.check(omitted.content.actions.count == 1, "an omitted action is not deleted")
        let ungrounded = NotesDelta(actions: [
            NoteItem(id: "", text: "追加の確認", owner: "田中", due: "来週", evidence: [new.id])
        ])
        let cleared = MinutesEngine.merge(state, delta: ungrounded, batch: batch, segments: [old, new])
        try Self.check(
            cleared.content.actions.count == 2 && cleared.content.actions[1].owner == nil
                && cleared.content.actions[1].due == nil && cleared.rejectedItems == nil,
            "an owner or deadline missing from the evidence is cleared, never invented")
        let unknown = NotesDelta(actions: [
            NoteItem(id: "", text: "不正な根拠", evidence: ["invented"]),
            NoteItem(id: "task-1", text: "資料を確認", evidence: [old.id], state: .cancelled),
            NoteItem(id: "", text: "正しい根拠", evidence: [new.id]),
        ])
        let partial = MinutesEngine.merge(state, delta: unknown, batch: batch, segments: [old, new])
        try Self.check(
            partial.rejectedItems == 2 && partial.content.actions.map(\.text) == ["資料を確認", "正しい根拠"]
                && partial.content.actions[0].state == .open && partial.appliedSegmentIDs.contains(new.id),
            "ungrounded items (unknown or only old evidence) are dropped without discarding valid ones")
        let rendered = MinutesEngine.render(merged, segments: [old, new])
        try Self.check(
            rendered.components(separatedBy: "\n## ").last?.hasPrefix("アクションアイテム\n- [x]") == true,
            "actions remain the last section")
        let exported = MinutesEngine.render(merged, segments: [old, new], transcript: "原文")
        try Self.check(
            exported.components(separatedBy: "\n## ").last?.hasPrefix("アクションアイテム\n- [x]") == true,
            "export also keeps actions after the transcript")
        let long = (0..<100).map {
            Segment(id: String($0), time: Double($0), source: "マイク", text: String(repeating: "あ", count: 1000))
        }
        try Self.check(
            MinutesEngine.batch(long, state: MinutesState()).count == 12,
            "summary input remains bounded for a large backlog")
    }
    func testLateArrivingTranscriptAndEchoInput() throws {
        let late = Segment(id: "late", time: 12, source: "Mac音声", text: "次回の会議までに資料を確認します")
        let early = Segment(id: "early", time: 0, source: "マイク", text: "先に届かなかった発言")
        var state = MinutesState()
        state.appliedSegmentIDs = [late.id]
        try Self.check(
            MinutesEngine.batch([late, early], state: state).map(\.id) == [early.id],
            "late arrivals are tracked by ID rather than count")
        let echo = Segment(id: "echo", time: 13, source: "マイク", text: late.text)
        let groups = MinutesEngine.evidenceInput([late, echo, early])
        try Self.check(
            groups.count == 2 && (groups[0]["ids"] as? [String]) == ["late", "echo"],
            "echo candidate keeps both evidence IDs")
        let repeatLater = Segment(id: "repeat", time: 50, source: "マイク", text: late.text)
        try Self.check(
            MinutesEngine.evidenceInput([late, repeatLater]).count == 2,
            "separate later statements must not be treated as acoustic echo")
    }
    func testLegacyMeetingMigration() throws {
        var meeting = Meeting(title: "legacy")
        meeting.segments = [Segment(time: 4, source: "Mac音声", text: "旧録音")]
        var json = try Self.require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any], "legacy meeting JSON")
        for name in ["capture", "jobs", "notes", "settings", "revision", "hasAudio"] { json.removeValue(forKey: name) }
        var segments = try Self.require(json["segments"] as? [[String: Any]], "legacy segment JSON")
        segments[0].removeValue(forKey: "id")
        json["segments"] = segments
        let data = try JSONSerialization.data(withJSONObject: json)
        let first = try JSONDecoder().decode(Meeting.self, from: data)
        let second = try JSONDecoder().decode(Meeting.self, from: data)
        try Self.check(
            first.segments[0].id == second.segments[0].id && first.jobs.isEmpty,
            "old recordings migrate without changing evidence IDs")
        try Self.check(
            first.minutes == meeting.minutes && first.id == meeting.id, "existing meeting content survives migration")
    }
    func testCloudStructuredContractAndRefusal() async throws {
        try Self.check(URLProtocol.registerClass(StructuredMockProtocol.self), "register summary mock")
        defer { URLProtocol.unregisterClass(StructuredMockProtocol.self) }
        StructuredMockProtocol.reset()
        let segment = Segment(id: "evidence-1", time: 3, source: "マイク", text: "資料を確認します")
        let result = try await MinutesEngine.update(
            MinutesState(), segments: [segment], settings: SessionSettings(), key: "TEST")
        let body = StructuredMockProtocol.body
        try Self.check(body["model"] as? String == "gpt-6-sol", "requested summary model is preserved")
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        try Self.check(
            format?["type"] as? String == "json_schema" && format?["strict"] as? Bool == true,
            "structured response contract")
        try Self.check(
            body["store"] as? Bool == false && result.content.actions.count == 1, "valid structured response is parsed")
        StructuredMockProtocol.reset(status: "incomplete")
        var failed = false
        do {
            _ = try await MinutesEngine.update(
                MinutesState(), segments: [segment], settings: SessionSettings(), key: "TEST")
        } catch { failed = true }
        try Self.check(failed, "incomplete response cannot replace minutes")
        StructuredMockProtocol.reset(refusal: true)
        failed = false
        do {
            _ = try await MinutesEngine.update(
                MinutesState(), segments: [segment], settings: SessionSettings(), key: "TEST")
        } catch { failed = true }
        try Self.check(failed, "refusal cannot advance summary state")
    }
    actor QueueMeter {
        var active = 0
        var peak = 0
        var calls: [String: Int] = [:]
        func begin(_ name: String) -> Int {
            active += 1
            peak = max(peak, active)
            let count = calls[name, default: 0] + 1
            calls[name] = count
            return count
        }
        func end() { active -= 1 }
    }
    @MainActor func testBoundedWorkerPool() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        let meter = QueueMeter()
        store.pipeline = ProcessingPipeline(
            store: store,
            recognize: { url, offset, source, _ in
                _ = await meter.begin(url.lastPathComponent)
                try await Task.sleep(nanoseconds: 30_000_000)
                await meter.end()
                return [Segment(time: offset, source: source, text: "確認します")]
            })
        for name in ["first", "second"] {
            var meeting = Meeting(title: name)
            meeting.settings = SessionSettings()
            meeting.jobs = (0..<10).map {
                TranscriptionJob(
                    id: name + String($0), filename: name + String($0) + ".caf", offset: Double($0), source: "マイク")
            }
            store.meetings.append(meeting)
            store.pipeline.resume(meeting.id, key: "TEST")
        }
        try await store.waitUntilIdle()
        let peak = await meter.peak
        try Self.check(peak == 2, "two transcription requests at most across meetings")
        try Self.check(
            store.meetings.allSatisfy { $0.jobs.allSatisfy { $0.state == .completed } && $0.segments.count == 10 },
            "bounded pool does not lose or duplicate jobs")
    }
    @MainActor func testSelectiveRetryAndRestartRecovery() async throws {
        let (root, audio) = try fixture(seconds: 1, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("meetings"), loadSettings: false)
        var meeting = Meeting(title: "recover")
        meeting.settings = SessionSettings()
        meeting.capture = .stopped
        meeting.jobs = [
            TranscriptionJob(id: "done", filename: "chunks/done.caf", offset: 0, source: "マイク", state: .completed),
            TranscriptionJob(
                id: "retry", filename: "chunks/retry.caf", offset: 5, source: "Mac音声", state: .running, attempts: 1),
        ]
        meeting.segments = [Segment(id: "done:0", time: 0, source: "マイク", text: "資料を確認します")]
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        try FileManager.default.createDirectory(
            at: store.folder(meeting.id).appendingPathComponent("chunks"), withIntermediateDirectories: true)
        for name in ["done.caf", "retry.caf"] {
            try FileManager.default.copyItem(
                at: audio, to: store.folder(meeting.id).appendingPathComponent("chunks/" + name))
        }
        let manifest = RecordingManifest(chunks: [
            RecordedChunk(filename: "done.caf", offset: 0, source: "マイク"),
            RecordedChunk(filename: "retry.caf", offset: 5, source: "Mac音声"),
        ])
        try JSONEncoder().encode(manifest).write(to: store.folder(meeting.id).appendingPathComponent("recording.json"))
        let restarted = Store(root: store.root, loadSettings: false)
        restarted.key = "TEST"
        let meter = QueueMeter()
        restarted.pipeline = ProcessingPipeline(
            store: restarted,
            recognize: { url, offset, source, _ in
                let count = await meter.begin(url.lastPathComponent)
                await meter.end()
                if count == 1 { throw CloudFailure(code: 503) }
                return [Segment(time: offset, source: source, text: "内容を確認します")]
            },
            summarize: { state, segments, _, _ in
                let batch = MinutesEngine.batch(segments, state: state)
                return MinutesEngine.merge(
                    state, delta: MinutesEngine.extract(batch), batch: batch, segments: segments)
            }, retryDelay: { _ in 0.01 })
        await restarted.recover()
        try await restarted.waitUntilIdle()
        let calls = await meter.calls
        try Self.check(
            calls["done.caf"] == nil && calls["retry.caf"] == 2,
            "completed audio is not reprocessed; interrupted work retries selectively")
        let restored = restarted.meetings[0]
        try Self.check(
            restored.jobs.allSatisfy { $0.state == .completed } && restored.segments.count == 2,
            "restart and retry cannot duplicate transcript")
        try Self.check(
            restored.hasAudio == true && restored.status.hasPrefix("完了"),
            "recovered audio and summary must have a truthful completion state")
        let saved = try JSONDecoder().decode(
            Meeting.self, from: Data(contentsOf: restarted.folder(meeting.id).appendingPathComponent("meeting.json")))
        try Self.check(
            saved.notes?.appliedSegmentIDs.count == 2 && saved.jobs[1].state == .completed,
            "results and cursor are checkpointed together")
        try Self.check(
            !Processor.isRetryable(CloudFailure(code: 401)) && Processor.isRetryable(CloudFailure(code: 429)),
            "retry transient errors only")
    }
    actor Gate {
        var released = false
        func release() { released = true }
        func wait() async { while !released { try? await Task.sleep(nanoseconds: 5_000_000) } }
    }
    @MainActor func testStopDoesNotBlockNextMeeting() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("meetings"), loadSettings: false)
        let gate = Gate()
        store.pipeline = ProcessingPipeline(
            store: store,
            recognize: { _, offset, source, _ in
                await gate.wait()
                return [Segment(time: offset, source: source, text: "資料を確認します")]
            },
            summarize: { state, segments, _, _ in
                let batch = MinutesEngine.batch(segments, state: state)
                return MinutesEngine.merge(
                    state, delta: MinutesEngine.extract(batch), batch: batch, segments: segments)
            })
        var first = Meeting(title: "first")
        first.settings = SessionSettings()
        store.meetings = [first]
        store.activeID = first.id
        store.recording = true
        store.pipeline.resume(first.id, key: "")
        try store.recorder.prepareFiles(in: store.folder(first.id))
        store.recorder.consume(try audioSample(at: 0), of: .audio)
        await store.stop()
        try Self.check(
            !store.recording && !store.busy && store.pendingChunks == 1,
            "stop releases capture while transcription is delayed")
        var second = Meeting(title: "second")
        second.settings = SessionSettings()
        store.meetings.insert(second, at: 0)
        store.activeID = second.id
        store.recording = true
        store.pipeline.resume(second.id, key: "")
        try store.recorder.prepareFiles(in: store.folder(second.id))
        store.recorder.consume(try audioSample(at: 40), of: .microphone)
        await store.stop()
        await gate.release()
        try await store.waitUntilIdle()
        try Self.check(
            store.meetings.allSatisfy { $0.segments.count == 1 && $0.segments[0].time == 0 },
            "overlapping background work remains bound to its meeting")
        try Self.check(
            store.meetings.first { $0.id == first.id }?.segments.first?.source == "Mac音声"
                && store.meetings.first { $0.id == second.id }?.segments.first?.source == "マイク",
            "next meeting cannot overwrite previous session settings or source")
    }
    @MainActor func testTerminationLeavesRecoverableJobs() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "quit")
        meeting.settings = SessionSettings()
        store.meetings = [meeting]
        store.activeID = meeting.id
        store.recording = true
        try store.recorder.prepareFiles(in: store.folder(meeting.id))
        store.recorder.consume(try audioSample(at: 0), of: .microphone)
        await store.prepareForTermination()
        let saved = try JSONDecoder().decode(
            Meeting.self, from: Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json")))
        try Self.check(
            saved.capture == .stopped && saved.jobs.count == 1 && saved.jobs[0].state == .pending,
            "quit flushes tail and persists pending work without waiting for AI")
        let input = try Processor.recordingInputs(folder: store.folder(meeting.id))
        let frames = try AVAudioFile(forReading: input[0].url).length
        try Self.check(frames == 16000, "quit closes the tail audio file")
    }
    func testRepositoryRejectsStaleSnapshot() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        var latest = Meeting(title: "latest")
        latest.revision = 2
        var old = latest
        old.title = "old"
        old.revision = 1
        try await repository.save(latest)
        try await repository.save(old)
        let (saved, _) = try await repository.load()
        try Self.check(saved[0].title == "latest", "a delayed older snapshot cannot overwrite a newer checkpoint")
    }
    final class Warnings: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ message: String) {
            lock.lock()
            items.append(message)
            lock.unlock()
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return items.count
        }
    }
    func testDeviceFormatChangeAndInputWatchdog() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let warnings = Warnings()
        recorder.onError = { warnings.append($0) }
        try recorder.prepareFiles(in: root)
        recorder.consume(try audioSample(at: 0), of: .audio)
        recorder.consume(try audioSample(at: 1, sampleRate: 48000), of: .audio)
        recorder.checkInput(now: Date().addingTimeInterval(20))
        recorder.checkInput(now: Date().addingTimeInterval(25))
        try Self.check(warnings.count == 1, "missing microphone input raises one actionable interruption")
        try await recorder.stop()
        let inputs = try Processor.recordingInputs(folder: root)
        let lengths = try inputs.map { try AVAudioFile(forReading: $0.url).length }
        try Self.check(
            lengths == [16000, 48000] && inputs.map(\.offset) == [0, 1],
            "format changes preserve both segments and the common clock")
        let first = try AVAudioFile(forReading: root.appendingPathComponent("system.caf")).length
        let second = try AVAudioFile(forReading: root.appendingPathComponent("system-1.caf")).length
        try Self.check(first == 16000 && second == 48000, "format changes never overwrite the previous raw track")
    }
}

final class StructuredMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured: [String: Any] = [:]
    private static var status = "completed"
    private static var refusal = false
    static var body: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
    static func reset(status: String = "completed", refusal: Bool = false) {
        lock.lock()
        captured = [:]
        Self.status = status
        Self.refusal = refusal
        lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.path == "/v1/responses" else { throw AppError.message("unexpected network request") }
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try ProcessingTests.require(
                JSONSerialization.jsonObject(with: data) as? [String: Any], "summary request JSON")
            Self.lock.lock()
            Self.captured = body
            let status = Self.status
            let refusal = Self.refusal
            Self.lock.unlock()
            let inputText = try ProcessingTests.require(body["input"] as? String, "summary input text")
            let input = try ProcessingTests.require(
                JSONSerialization.jsonObject(with: Data(inputText.utf8)) as? [String: Any], "summary input JSON")
            let utterances = try ProcessingTests.require(
                input["newUtterances"] as? [[String: Any]], "summary utterances")
            let utterance = try ProcessingTests.require(utterances.first, "summary first utterance")
            let text = try ProcessingTests.require(utterance["text"] as? String, "summary utterance text")
            let evidence = try ProcessingTests.require(utterance["ids"] as? [String], "summary utterance evidence")
            let delta = NotesDelta(actions: [
                NoteItem(id: "", text: text, evidence: evidence)
            ])
            let json = String(decoding: try JSONEncoder().encode(delta), as: UTF8.self)
            let content: [String: Any] =
                refusal ? ["type": "refusal", "refusal": "test refusal"] : ["type": "output_text", "text": json]
            let responseBody = try JSONSerialization.data(withJSONObject: [
                "status": status, "output": [["type": "message", "content": [content]]],
            ])
            let url = try ProcessingTests.require(request.url, "summary response URL")
            let response = try ProcessingTests.require(
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]),
                "summary HTTP response")
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
