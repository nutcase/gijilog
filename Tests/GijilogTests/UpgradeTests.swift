import AVFoundation
import Foundation

extension ProcessingTests {
    @MainActor func testTranscriptionFailureIsShownAndRetriedWhileRecording() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(
            store: store, recognize: { _, offset, source, _ in [Segment(time: offset, source: source, text: "確認します")] },
            summarize: MinutesEngine.stubSummary)
        var meeting = Meeting(title: "live")  // Still recording.
        meeting.settings = SessionSettings()
        meeting.jobs = [
            TranscriptionJob(
                id: "bad", filename: "chunks/bad.caf", offset: 132, source: "マイク", state: .failed, attempts: 3,
                lastError: "クラウドAPIエラー (401)")
        ]
        store.meetings = [meeting]
        store.activeID = meeting.id
        store.recording = true
        let failure = try Self.require(store.meetings[0].transcriptionFailure, "failure text")
        try Self.check(
            failure.contains("02:12") && failure.contains("1件") && failure.contains("401"),
            "the failure says where, how many, and why: \(failure)")
        store.retryFailedJobs(meeting.id)
        try await store.waitUntilIdle()
        try Self.check(
            store.meetings[0].transcriptionFailure == nil && store.meetings[0].segments.count == 1,
            "failed chunks can be retried without stopping the recording")
    }
    @MainActor func testEarlierSettingsAndFoldersCarryOver() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["gijilog.test.\(UUID().uuidString)", "gijilog.test.\(UUID().uuidString)"]
        defer { for name in names { UserDefaults().removePersistentDomain(forName: name) } }
        let current = try Self.require(UserDefaults(suiteName: names[0]), "current defaults")
        let previous = try Self.require(UserDefaults(suiteName: names[1]), "previous defaults")
        previous.set("/Users/someone/議事録", forKey: "storageFolder")
        previous.set("old-model", forKey: "summaryModel")
        current.set("current-model", forKey: "summaryModel")
        Store.adoptPreviousSettings(into: current, from: [previous])
        try Self.check(
            current.string(forKey: "storageFolder") == "/Users/someone/議事録"
                && current.string(forKey: "summaryModel") == "current-model",
            "a custom save location carries over without overriding newer settings")

        let old = root.appendingPathComponent("キロクル")
        let meeting = Meeting(title: "週次定例")
        let folder = old.appendingPathComponent("2026-10-03 17.26 週次定例")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
        let store = Store(root: root.appendingPathComponent("ギジログ"), loadSettings: false)
        await store.moveMeetings(from: [Store.PreviousLocation(folder: old, renamesFolders: false)])
        await store.recover()
        try Self.check(
            store.meetings.map(\.id) == [meeting.id] && store.meetings[0].folderName == "2026-10-03 17.26 週次定例",
            "meetings saved under the earlier name stay in the list")
    }
    @MainActor func testInterruptedRecordingGetsAudioOnFirstRecovery() async throws {
        let (root, audio) = try fixture(seconds: 3, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        var meeting = Meeting(title: "強制終了")  // Saved while still recording.
        meeting.settings = SessionSettings()
        meeting.folderName = "2026-10-03 17.26 強制終了"
        let folder = save.appendingPathComponent(meeting.folderName ?? "")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
        try FileManager.default.copyItem(at: audio, to: folder.appendingPathComponent("chunks/first.caf"))
        try Data("cut short by a forced quit".utf8).write(to: folder.appendingPathComponent("chunks/last.caf"))
        let manifest = RecordingManifest(chunks: [
            RecordedChunk(filename: "first.caf", offset: 0, source: "マイク"),
            RecordedChunk(filename: "last.caf", offset: 3, source: "マイク"),
        ])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("recording.json"))
        let store = Store(root: save, loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(store: store, recognize: { _, _, _, _ in [] })
        await store.recover()
        try await store.waitUntilIdle()
        await store.waitForMixdowns()
        let output = folder.appendingPathComponent("録音.m4a")
        try Self.check(FileManager.default.fileExists(atPath: output.path), "the first recovery writes 録音.m4a")
        let seconds = try await AVURLAsset(url: output).load(.duration).seconds
        try Self.check(abs(seconds - 3) < 0.2, "an unreadable last chunk is skipped: \(seconds)s")
    }
}
