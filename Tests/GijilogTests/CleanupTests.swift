import AVFoundation
import Foundation

extension ProcessingTests {
    @MainActor func importedMeeting(seconds: Double, removesWorkingAudio: Bool) async throws -> (Store, Meeting, URL) {
        let (root, audio) = try fixture(seconds: seconds, amplitude: 0.25)
        let store = Store(root: root.appendingPathComponent("save"), loadSettings: false)
        store.key = "TEST"
        store.removesWorkingAudio = removesWorkingAudio
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            recognize: { _, offset, source, _, _ in
                [Segment(time: offset, source: source, text: "\(Int(offset))秒の資料を確認します")]
            },
            summarize: MinutesEngine.stubSummary)
        await store.importRecording(from: audio)
        try await store.waitUntilIdle()
        await store.waitForBackgroundWork()
        return (store, try Self.require(store.meetings.first, "imported meeting"), root)
    }
    @MainActor func testCompletedMeetingKeepsOnlyRecordingAndMinutes() async throws {
        let (store, meeting, root) = try await importedMeeting(seconds: 45, removesWorkingAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = store.folder(meeting.id)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        try Self.check(
            meeting.status == "完了" && !names.contains("chunks") && names.contains("録音.m4a")
                && names.contains("議事録.md"),
            "a complete meeting keeps 録音.m4a and 議事録.md and drops its working audio: \(names)")

        // Reprocessing without working audio transcribes 録音.m4a again.
        await store.process(meeting.id, rebuild: true)
        try await store.waitUntilIdle()
        await store.waitForBackgroundWork()
        let again = try Self.require(store.meetings.first, "reprocessed meeting")
        try Self.check(
            again.segments.count == again.jobs.count && again.jobs.count > 1
                && again.jobs.allSatisfy { $0.filename.hasPrefix("chunks/import-") }
                && again.status == "完了"
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("meeting.before-reprocess.json").path),
            "a full reprocess rebuilds the transcript from 録音.m4a and keeps a backup")

        let (kept, keptMeeting, keptRoot) = try await importedMeeting(seconds: 45, removesWorkingAudio: false)
        defer { try? FileManager.default.removeItem(at: keptRoot) }
        try Self.check(
            FileManager.default.fileExists(atPath: kept.folder(keptMeeting.id).appendingPathComponent("chunks").path),
            "with the setting off, working audio stays")
    }
    @MainActor func testStorageUsageAndCleanupOfCompleteMeetingsOnly() async throws {
        let (store, complete, root) = try await importedMeeting(seconds: 45, removesWorkingAudio: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // A second meeting whose transcription failed keeps its audio for a retry.
        let (_, audio) = try fixture(seconds: 3, amplitude: 0.25)
        var failed = Meeting(title: "失敗")
        failed.capture = .stopped
        failed.settings = SessionSettings()
        failed.folderName = "2026-10-03 10.00 失敗"
        failed.jobs = [
            TranscriptionJob(id: "x", filename: "chunks/x.caf", offset: 0, source: "マイク", state: .failed, attempts: 3)
        ]
        store.meetings.append(failed)
        try FileManager.default.createDirectory(
            at: store.folder(failed.id).appendingPathComponent("chunks"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: audio, to: store.folder(failed.id).appendingPathComponent("chunks/x.caf"))
        try await store.checkpoint(failed.id)

        let usage = StorageUsage.measure(store.root)
        try Self.check(
            usage.meetings == 2 && usage.recordings > 0 && usage.working > 0 && usage.other > 0
                && usage.total == usage.recordings + usage.working + usage.other,
            "usage is split into recordings, working audio, and the rest: \(usage)")
        try Self.check(store.cleanableMeetings() == [complete.id], "only complete meetings with 録音.m4a are cleanable")
        let freed = await store.removeWorkingAudio(of: [complete.id, failed.id])
        let after = StorageUsage.measure(store.root)
        try Self.check(
            freed > 0 && after.working < usage.working && after.recordings == usage.recordings
                && FileManager.default.fileExists(
                    atPath: store.folder(failed.id).appendingPathComponent("chunks/x.caf").path),
            "cleanup frees the complete meeting's working audio and leaves the failed one alone")
    }
}

extension ProcessingTests {
    func testRecordingContinuesAfterTheEarlierPart() async throws {
        let (folder, _) = try fixture(seconds: 1, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = Recorder()
        try recorder.prepareFiles(in: folder)
        recorder.consume(try audioSample(at: 0), of: .microphone)
        try await recorder.stop()
        try recorder.prepareFiles(in: folder, continuingAt: 100)
        recorder.consume(try audioSample(at: 500), of: .microphone)
        try await recorder.stop()
        let inputs = try Processor.recordingInputs(folder: folder)
        let length = try Processor.recordedLength(folder: folder)
        try Self.check(
            inputs.map(\.offset) == [0, 100] && abs(length - 101) < 0.01,
            "the earlier chunks stay listed and the new part starts after them: \(inputs.map(\.offset)), \(length)")
    }
    @MainActor func testContinuingAMeetingWhoseWorkingAudioWasCleaned() async throws {
        let (store, meeting, root) = try await importedMeeting(seconds: 45, removesWorkingAudio: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let segments = store.meetings[0].segments
        let cleaned = try Store.workingAudioMissing(store.folder(meeting.id))
        try Self.check(
            store.canContinueRecording(store.meetings[0]) && cleaned,
            "a finished meeting without working audio can be continued")
        let base = try await store.prepareContinuation(meeting.id)
        let again = try Self.require(store.meetings.first, "continued meeting")
        let inputs = try Processor.recordingInputs(folder: store.folder(meeting.id))
        try Self.check(
            abs(base - 45) < 0.5 && !inputs.isEmpty
                && inputs.allSatisfy { input in
                    again.jobs.contains {
                        $0.filename == "chunks/" + input.url.lastPathComponent && $0.state == .completed
                    }
                } && again.segments == segments && !store.pipeline.isProcessing(meeting.id),
            "録音.m4a is cut into chunks again, already transcribed, and the new part starts after it: \(base)")
        var timed = again
        timed.clockStart = timed.date.addingTimeInterval(600)
        try Self.check(
            timed.recordingOrigin == timed.date.addingTimeInterval(600) && again.recordingOrigin == again.date,
            "a continued meeting's clock runs on from its earlier part")
        var planned = Meeting(title: "準備中")
        planned.capture = .planned
        try Self.check(!store.canContinueRecording(planned), "a prepared meeting is recorded, not continued")
    }
}
