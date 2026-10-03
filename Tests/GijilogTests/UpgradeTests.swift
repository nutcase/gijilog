import AVFoundation
import Foundation

extension ProcessingTests {
    @MainActor func testTranscriptionFailureIsShownAndRetriedWhileRecording() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            recognize: { _, offset, source, _ in [Segment(time: offset, source: source, text: "確認します")] },
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
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview, recognize: { _, _, _, _ in [] })
        await store.recover()
        try await store.waitUntilIdle()
        await store.waitForBackgroundWork()
        let output = folder.appendingPathComponent("録音.m4a")
        try Self.check(FileManager.default.fileExists(atPath: output.path), "the first recovery writes 録音.m4a")
        let seconds = try await AVURLAsset(url: output).load(.duration).seconds
        try Self.check(abs(seconds - 3) < 0.2, "an unreadable last chunk is skipped: \(seconds)s")
    }
}

extension ProcessingTests {
    @MainActor func testImportNeverBlocksStoppingARecording() async throws {
        let (root, long) = try fixture(seconds: 600, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("save"), loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview, recognize: { _, _, _, _ in [] },
            summarize: MinutesEngine.stubSummary)
        var live = Meeting(title: "live")
        live.settings = SessionSettings()
        store.meetings = [live]
        store.selected = live.id
        store.activeID = live.id
        store.recording = true
        let importing = Task { await store.importRecording(from: long) }
        let deadline = Date().addingTimeInterval(10)
        while !store.importing && Date() < deadline { await Task.yield() }
        try Self.check(store.importing, "the import is under way")
        // A microphone disconnect arrives while the file is still being read.
        await store.interrupt("マイクが切断されました。")
        try Self.check(
            !store.recording && store.meetings.first { $0.id == live.id }?.capture == .interrupted,
            "an interruption stops the recording even while a file is importing")
        try Self.check(store.selected == live.id, "an import does not take the screen away from the live meeting")
        await importing.value
        try Self.check(store.meetings.count == 2, "the import still completes after the recording stopped")
    }
    func testImportMixesEveryAudioTrack() async throws {
        let (root, audio) = try fixture(seconds: 2, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        // A movie with two audio tracks: one from 0 to 2 s, the other from 5 to 7 s.
        let source = AVURLAsset(url: audio)
        let track = try Self.require(try await source.loadTracks(withMediaType: .audio).first, "source track")
        let range = CMTimeRange(start: .zero, duration: try await source.load(.duration))
        let composition = AVMutableComposition()
        let first = try Self.require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid), "first")
        try first.insertTimeRange(range, of: track, at: .zero)
        let second = try Self.require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid), "second"
        )
        try second.insertTimeRange(range, of: track, at: .zero)
        second.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)))
        let movie = root.appendingPathComponent("two-tracks.mov")
        let session = try Self.require(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough), "export session")
        try await session.export(to: movie, as: .mov)
        let tracks = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        try Self.check(tracks.count == 2, "the test movie has two audio tracks")
        let folder = root.appendingPathComponent("imported")
        let chunks = try await AudioImport.split(movie, into: folder)
        let frames = try chunks.map {
            try AVAudioFile(forReading: folder.appendingPathComponent("chunks/" + $0.filename)).length
        }.reduce(0, +)
        let seconds = Double(frames) / AudioImport.sampleRate
        try Self.check(abs(seconds - 7) < 0.1, "both tracks are imported, not just the first: \(seconds)s")
    }
    func testSettingsCarryOverFromEveryEarlierBundleID() throws {
        try Self.check(
            Store.previousBundleIDs == [
                "io.github.nutcase.kirokuru", "local.minutes.kirokuru", "local.minutes.desktop",
            ],
            "every bundle ID an earlier build script used is migrated, newest first")
        let names = (0..<3).map { _ in "gijilog.test.\(UUID().uuidString)" }
        defer { for name in names { UserDefaults().removePersistentDomain(forName: name) } }
        let suites = try names.map { try Self.require(UserDefaults(suiteName: $0), "test defaults") }
        let (current, newer, older) = (suites[0], suites[1], suites[2])
        newer.set("/Users/someone/新しい保存先", forKey: "storageFolder")
        older.set("/Users/someone/古い保存先", forKey: "storageFolder")
        older.set("old-model", forKey: "summaryModel")
        Store.adoptPreviousSettings(into: current, from: [newer, older])
        try Self.check(
            current.string(forKey: "storageFolder") == "/Users/someone/新しい保存先"
                && current.string(forKey: "summaryModel") == "old-model",
            "the newest earlier version wins, and older versions fill the gaps")
    }
}
