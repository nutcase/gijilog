import AVFoundation
import CoreMedia
import Foundation

@main struct ProcessingTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw AppError.message("FAIL: " + message) }
    }
    static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw AppError.message("FAIL: " + message) }
        return value
    }
    static func main() async throws {
        _ = URLProtocol.registerClass(BlockNetworkProtocol.self)  // Consulted after the per-test mocks.
        let tests = ProcessingTests()
        try tests.testChunkingPreservesFramesAndOffsets()
        try await tests.testSilentCloudChunkDoesNotCallAPI()
        try tests.testLegacyExtractionNotesRender()
        try await tests.testRecorderKeepsBothTracksAndFlushesTail()
        try await tests.testStopFailureClosesFilesBeforeRestart()
        try await tests.testReplayPreservesDelayedTracksAndGaps()
        try await tests.testSilentReplayDoesNotCallAPI()
        try await tests.testStoreDistinguishesEmptyUnrecognizedAndComplete()
        try tests.testIncrementalNotesAndEvidenceValidation()
        try tests.testLateArrivingTranscriptAndEchoInput()
        try tests.testLegacyMeetingMigration()
        try await tests.testCloudStructuredContractAndRefusal()
        try await tests.testBoundedWorkerPool()
        try await tests.testSelectiveRetryAndRestartRecovery()
        try await tests.testStopDoesNotBlockNextMeeting()
        try await tests.testTerminationLeavesRecoverableJobs()
        try await tests.testRepositoryRejectsStaleSnapshot()
        try await tests.testDeviceFormatChangeAndInputWatchdog()
        try await tests.testSummaryCoalescesLatestUtterances()
        try await tests.testFullReprocessBacksUpAndReplacesOldNotes()
        try await tests.testRetryBudgetAndMissingChunkIsolation()
        try tests.testOnlyTheActiveInputStopsRecording()
        try await tests.testLiveSummaryRecoversAfterFailure()
        try tests.testCloudErrorDetailAndRetryAfter()
        try await tests.testCheckpointsCoalesceAndSkipCleanMeetings()
        try await tests.testRecoverySkipsSettledMeetings()
        try tests.testExportHasOneTitleHeading()
        try await tests.testDeleteMovesFolderAndBlocksLateWrites()
        try await tests.testMeetingFolderHoldsMinutesAndAudio()
        try await tests.testSaveLocationMovesWithItsMeetings()
        try tests.testLegacyMeetingsMoveToReadableFolders()
        try await tests.testImportCutsAnyRecordingIntoChunks()
        try await tests.testImportCutsAtPauses()
        try await tests.testImportedRecordingBecomesMinutes()
        try tests.testChunkCutterEndsAtPauses()
        try tests.testOnlyVoiceIsSent()
        try tests.testTranscriptionHints()
        try await tests.testTranscriptionRequestCarriesHints()
        try tests.testMisheardWordsAreFoundBySpellingAndReading()
        try tests.testHandEditsSurviveAIUpdates()
        try await tests.testEditingMinutesByHand()
        try await tests.testEditingTheTranscriptByHand()
        try await tests.testTranscriptionFailureIsShownAndRetriedWhileRecording()
        try await tests.testEarlierSettingsAndFoldersCarryOver()
        try await tests.testInterruptedRecordingGetsAudioOnFirstRecovery()
        try await tests.testImportNeverBlocksStoppingARecording()
        try await tests.testImportMixesEveryAudioTrack()
        try tests.testSettingsCarryOverFromEveryEarlierBundleID()
        try await tests.testCompletedMeetingKeepsOnlyRecordingAndMinutes()
        try await tests.testStorageUsageAndCleanupOfCompleteMeetingsOnly()
        try tests.testMinutesExplainDecisionsAndSeparateHistory()
        try tests.testReviewCannotRollBackLaterEvidence()
        try await tests.testReviewUsesStructuredQualityContract()
        try await tests.testFinalReviewDiscardsOutdatedResponse()
        try await tests.testFinalReviewCheckpointsAndResumesWithoutAudio()
        try await tests.testReviewWaitsForRecordingAndPendingTranscription()
        try await tests.testRefineSavedTranscriptWithoutRetranscription()
        try tests.testTagsAreNormalizedAndDeduplicated()
        try await tests.testTagsFilterTheListAndAreSaved()
        try await tests.testTagsCanBeRenamedMergedAndDeleted()
        try tests.testSearchFindsEveryKeywordAnywhereInAMeeting()
        try await tests.testSearchNarrowsTheListWithTags()
        try tests.testFindingWordsInsideAMeeting()
        try tests.testAgendaParsesPastedText()
        try tests.testAgendaFollowsTheMeeting()
        try tests.testMinutesModelJudgesTheTopic()
        try await tests.testPreparedMeetingWaitsWithItsAgenda()
        try await tests.testAgendaRecordsWhereTheTimeWent()
        try tests.testMCPSpeaksBothProtocolEras()
        try tests.testMCPToolsReadMeetings()
        try tests.testMCPSearchReturnsEveryMatchingPassage()
        try tests.testMCPKeepsWhatTheUserWithholds()
        try await tests.testMCPAnswersOverItsSocket()
        print(
            "PASS: 73 checks (recording, chunking at pauses, voice gate, transcription hints, editing and corrections, incremental notes, durable queue, bounded concurrency, retry, recovery, lifecycle, structured API, partial validation, coalesced saves, export, deletion, save location, audio mixdown, file import, upgrade and recovery, storage cleanup, minutes quality and final review, tags, search, agenda, MCP)"
        )
    }
    /// A steady tone, silent in the given ranges of seconds.
    func fixture(seconds: Double, amplitude: Float, silent: [ClosedRange<Double>] = []) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("input.caf")
        let format = try Self.require(
            AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1), "fixture audio format")
        let buffer = try Self.require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16000)),
            "fixture audio buffer")
        buffer.frameLength = buffer.frameCapacity
        let samples = try Self.require(buffer.floatChannelData, "fixture audio samples")[0]
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / 16000
            samples[frame] = silent.contains { $0.contains(time) } ? 0 : amplitude * sin(Float(frame) * 0.17)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return (folder, url)
    }
    func testChunkingPreservesFramesAndOffsets() throws {
        let (folder, url) = try fixture(seconds: 45, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chunks = try Processor.chunks(url, directory: folder)
        try Self.check(chunks.count == 2, "chunk count")
        try Self.check(chunks[0].1 == 0, "first chunk offset")
        try Self.check(chunks[1].1 == 40, "second chunk offset")
        let frames = try chunks.reduce(Int64(0)) { try $0 + AVAudioFile(forReading: $1.0).length }
        try Self.check(frames == 720000, "frame continuity")
    }
    func testSilentCloudChunkDoesNotCallAPI() async throws {
        let (folder, url) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: folder) }
        let segments = try await Processor.recognizeChunk(url, offset: 12, source: "マイク", key: "")
        try Self.check(segments.isEmpty, "silent chunk must skip network")
    }
    actor ChunkCollector {
        var values: [(URL, Double, String)] = []
        func add(_ url: URL, _ offset: Double, _ source: String) { values.append((url, offset, source)) }
    }
    func testRecorderKeepsBothTracksAndFlushesTail() async throws {
        let (folder, _) = try fixture(seconds: 1, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        let collector = ChunkCollector()
        recorder.onChunk = { url, offset, source in await collector.add(url, offset, source) }
        try recorder.prepareFiles(in: folder)
        let format = try Self.require(
            AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1), "recording audio format")
        // A silent second, then 26 seconds of speech without a pause: one chunk ends at the limit, and the tail
        // is flushed on stop.
        for second in 0..<27 {
            let pcm = try Self.require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000), "recording audio buffer")
            pcm.frameLength = 16000
            let samples = try Self.require(pcm.floatChannelData, "recording audio samples")[0]
            for i in 0..<16000 { samples[i] = second == 0 ? 0 : 0.25 }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 16000),
                presentationTimeStamp: CMTime(value: Int64(second), timescale: 1), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            let created = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format.formatDescription, sampleCount: 16000, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            try Self.check(created == noErr, "sample creation")
            guard let sample else { throw AppError.message("missing sample") }
            let attached = CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList)
            try Self.check(attached == noErr, "sample audio attachment")
            CMSampleBufferSetDataReady(sample)
            recorder.consume(sample, of: .audio)
            recorder.consume(sample, of: .microphone)
        }
        try await recorder.stop()
        let chunks = await collector.values
        try Self.check(chunks.count == 4, "two full chunks and two tails")
        for source in ["Mac音声", "マイク"] {
            let trackChunks = chunks.filter { $0.2 == source }.sorted { $0.1 < $1.1 }
            try Self.check(trackChunks.map { $0.1 } == [0, 25], "common clock and tail offset")
            let files = try trackChunks.map { try AVAudioFile(forReading: $0.0) }
            try Self.check(files.reduce(Int64(0)) { $0 + $1.length } == 432000, "no lost final second: " + source)
            try Self.check(
                files.allSatisfy { $0.fileFormat.commonFormat == .pcmFormatInt16 }, "chunks are 16-bit PCM: " + source)
        }
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
            $0.hasSuffix(".caf") && $0 != "input.caf"
        }
        try Self.check(copies.isEmpty, "no second full-length copy of each track is written: \(copies)")
    }
    func audioSample(at second: Int64, amplitude: Float = 0.25, sampleRate: Double = 16000) throws -> CMSampleBuffer {
        let format = try Self.require(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1), "sample audio format")
        let pcm = try Self.require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)), "sample audio buffer")
        pcm.frameLength = AVAudioFrameCount(sampleRate)
        let samples = try Self.require(pcm.floatChannelData, "sample audio samples")[0]
        for i in 0..<Int(sampleRate) { samples[i] = amplitude }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(value: second, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let created = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: Int(sampleRate), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        try Self.check(created == noErr, "sample creation")
        guard let sample else { throw AppError.message("missing sample") }
        let attached = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList)
        try Self.check(attached == noErr, "sample attachment")
        CMSampleBufferSetDataReady(sample)
        return sample
    }
    actor StopFailure {
        var first = true
        func stop() throws {
            if first {
                first = false
                throw AppError.message("injected stop failure")
            }
        }
    }
    func testStopFailureClosesFilesBeforeRestart() async throws {
        let (folder, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        let failure = StopFailure()
        let recorder = Recorder(stopCapture: { _ in try await failure.stop() })
        let collector = ChunkCollector()
        recorder.onChunk = { url, offset, source in await collector.add(url, offset, source) }
        try recorder.prepareFiles(in: first)
        recorder.consume(try audioSample(at: 0), of: .audio)
        var rejected = false
        do { try recorder.prepareFiles(in: second) } catch { rejected = true }
        try Self.check(rejected, "active writers must block a new meeting")
        var failed = false
        do { try await recorder.stop() } catch { failed = true }
        try Self.check(failed, "stop failure must be reported after cleanup")
        let firstChunks = await collector.values
        try Self.check(firstChunks.count == 1, "failed stop must still deliver the tail")
        recorder.consume(try audioSample(at: 10), of: .audio)  // Late callback must be ignored.
        try recorder.prepareFiles(in: second)
        recorder.consume(try audioSample(at: 20), of: .audio)
        recorder.consume(try audioSample(at: 21), of: .audio)
        try await recorder.stop()
        func frames(_ folder: URL) throws -> Int64 {
            try Processor.recordingInputs(folder: folder).reduce(Int64(0)) {
                try $0 + AVAudioFile(forReading: $1.url).length
            }
        }
        let firstFrames = try frames(first)
        let secondFrames = try frames(second)
        try Self.check(firstFrames == 16000, "previous meeting must not receive later audio")
        try Self.check(secondFrames == 32000, "next meeting must receive its own audio")
        let inputs = try Processor.recordingInputs(folder: second)
        try Self.check(inputs.count == 1 && inputs[0].offset == 0, "next meeting must reset its origin")
    }
    func testReplayPreservesDelayedTracksAndGaps() async throws {
        let (folder, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        try recorder.prepareFiles(in: folder)
        recorder.consume(try audioSample(at: 0), of: .audio)
        recorder.consume(try audioSample(at: 5), of: .microphone)
        recorder.consume(try audioSample(at: 10), of: .audio)
        try await recorder.stop()
        let inputs = try Processor.recordingInputs(folder: folder)
        try Self.check(inputs.map(\.offset) == [0, 5, 10], "replay clock must preserve track delay and capture gap")
        try Self.check(inputs.map(\.source) == ["Mac音声", "マイク", "Mac音声"], "replay order must match capture order")
        try Self.check(URLProtocol.registerClass(MockCloudProtocol.self), "register mock transport")
        defer { URLProtocol.unregisterClass(MockCloudProtocol.self) }
        MockCloudProtocol.reset()
        let segments = try await Processor.transcribe(folder: folder, key: "TEST", progress: { _ in })
        try Self.check(segments.map(\.time) == [0, 5, 10], "transcription must use the persisted common clock")
        try Self.check(MockCloudProtocol.count == 3, "all three audible chunks must be recognized")
    }
    func testSilentReplayDoesNotCallAPI() async throws {
        let (folder, url) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        try recorder.prepareFiles(in: folder)
        recorder.consume(try audioSample(at: 0, amplitude: 0), of: .audio)
        try await recorder.stop()
        try Self.check(URLProtocol.registerClass(MockCloudProtocol.self), "register mock transport")
        defer { URLProtocol.unregisterClass(MockCloudProtocol.self) }
        MockCloudProtocol.reset()
        let newSegments = try await Processor.transcribe(folder: folder, key: "TEST", progress: { _ in })
        try Self.check(newSegments.isEmpty && MockCloudProtocol.count == 0, "new silent recording must not upload")
        let legacy = folder.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: legacy.appendingPathComponent("system.caf"))
        let oldSegments = try await Processor.transcribe(folder: legacy, key: "TEST", progress: { _ in })
        try Self.check(oldSegments.isEmpty && MockCloudProtocol.count == 0, "legacy silent recording must not upload")
    }
    @MainActor func testStoreDistinguishesEmptyUnrecognizedAndComplete() async throws {
        let (folder, audio) = try fixture(seconds: 1, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(root: folder.appendingPathComponent("meetings"), loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview, summarize: MinutesEngine.stubSummary)
        func activate(_ input: Meeting) async throws {
            var meeting = input
            meeting.settings = store.settings
            store.meetings = [meeting]
            store.selected = meeting.id
            store.recording = true
            store.activeID = meeting.id
            try await store.checkpoint(meeting.id)
            store.pipeline.resume(meeting.id, key: "TEST")
        }
        let empty = Meeting(title: "empty")
        try await activate(empty)
        await store.stop()
        try await store.waitUntilIdle()
        try Self.check(store.meetings[0].status == "録音なし", "missing audio cannot be complete")
        try Self.check(!store.status.contains("保存しました"), "missing audio must not show success")
        try Self.check(store.activeID == nil && !store.busy, "empty stop must release the UI")

        let silent = Meeting(title: "silent")
        try await activate(silent)
        try store.recorder.prepareFiles(in: store.folder(silent.id))
        store.recorder.consume(try audioSample(at: 0, amplitude: 0), of: .audio)
        await store.stop()
        try await store.waitUntilIdle()
        try Self.check(store.meetings[0].status == "録音済み・認識結果なし", "saved audio without words cannot be complete")
        try Self.check(store.meetings[0].minutes.isEmpty, "empty transcript must not produce minutes")
        await store.process()
        try await store.waitUntilIdle()
        try Self.check(store.meetings[0].status == "録音済み・認識結果なし", "replay must use the same empty-result state")

        var complete = Meeting(title: "complete")
        let jobID = stableID("system.caf")
        complete.jobs = [
            TranscriptionJob(id: jobID, filename: "system.caf", offset: 0, source: "Mac音声", state: .completed)
        ]
        complete.segments = [Segment(id: jobID + ":0", time: 0, source: "Mac音声", text: "次回までに確認します")]
        try await activate(complete)
        try FileManager.default.copyItem(at: audio, to: store.folder(complete.id).appendingPathComponent("system.caf"))
        await store.stop()
        try await store.waitUntilIdle()
        try Self.check(store.meetings[0].status == "完了", "real audio and transcript can complete")
        try Self.check(store.meetings[0].minutes.contains("アクションアイテム"), "successful stop must produce minutes")
        let saved = try JSONDecoder().decode(
            Meeting.self, from: Data(contentsOf: store.folder(complete.id).appendingPathComponent("meeting.json")))
        try Self.check(saved.status == store.meetings[0].status, "completion state must be persisted")
    }
    // Meetings recorded with the former keyword-extraction mode still render, labeled as candidates.
    func testLegacyExtractionNotesRender() throws {
        let segments = [
            Segment(id: "a", time: 12, source: "Mac音声", text: "次回までに検討します"),
            Segment(id: "b", time: 24, source: "マイク", text: "この案に決定します"),
        ]
        var state = MinutesEngine.merge(
            MinutesState(), delta: MinutesEngine.extract(segments), batch: segments, segments: segments)
        state.extractionOnly = true
        let text = MinutesEngine.render(state, segments: segments)
        try Self.check(text.contains("[00:24] この案に決定します"), "decision evidence")
        try Self.check(text.contains("[00:12] 次回までに検討します"), "pending evidence")
        try Self.check(text.contains("候補"), "unconfirmed candidate label")
        let sections = text.components(separatedBy: "\n## ").map { $0.components(separatedBy: "\n")[0] }
        try Self.check(
            sections.dropFirst() == ["要約", "決定事項と理由の候補", "アクションアイテム", "未決事項・次の確認の候補"],
            "what a reader acts on comes before the open issues: \(sections)")
        let actions = text.components(separatedBy: "\n## アクションアイテム\n")[1]
        try Self.check(actions.contains("- [ ] 次回までに検討します"), "action checklist")
        try Self.check(actions.contains("担当者: 未定 / 期限: 未定"), "no invented owner or deadline")
        try Self.check(state.latestSegmentIDs == ["a", "b"], "the latest update remembers its utterances")
    }
}

// No real API calls are made by the regression tests.
final class MockCloudProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var calls = 0
    private static var body = Data()
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    /// The last transcription request's multipart body.
    static var lastBody: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: body, as: UTF8.self)
    }
    static func reset() {
        lock.lock()
        calls = 0
        body = Data()
        lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.calls += 1
        Self.lock.unlock()
        guard request.url?.path == "/v1/audio/transcriptions" else {
            client?.urlProtocol(self, didFailWithError: AppError.message("unexpected network request"))
            return
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: AppError.message("invalid mock response"))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.body = body
        Self.lock.unlock()
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"確認します\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
