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
            recognize: { _, offset, source, _ in
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
            again.segments.count == 2 && again.jobs.allSatisfy { $0.filename.hasPrefix("chunks/import-") }
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
