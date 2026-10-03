import AVFoundation
import Foundation

extension ProcessingTests {
    func testImportCutsAnyRecordingIntoChunks() async throws {
        let (root, audio) = try fixture(seconds: 75, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("imported")
        let chunks = try await AudioImport.split(audio, into: folder)
        try Self.check(chunks.map(\.offset) == [0, 30, 60], "30-second chunks on the recording's own clock")
        let lengths = try chunks.map {
            try AVAudioFile(forReading: folder.appendingPathComponent("chunks/" + $0.filename)).length
        }
        try Self.check(lengths == [480_000, 480_000, 240_000], "no audio is lost or duplicated: \(lengths)")
        let inputs = try Processor.recordingInputs(folder: folder)
        try Self.check(
            inputs.count == 3 && inputs.allSatisfy { $0.source == AudioImport.source },
            "imported chunks are listed like recorded ones")
    }
    @MainActor func testImportedRecordingBecomesMinutes() async throws {
        let (root, audio) = try fixture(seconds: 45, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        let store = Store(root: save, loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(
            store: store,
            recognize: { _, offset, source, _ in
                [Segment(time: offset, source: source, text: "\(Int(offset))秒の資料を確認します")]
            },
            summarize: MinutesEngine.stubSummary)
        await store.importRecording(from: audio)
        try await store.waitUntilIdle()
        await store.waitForMixdowns()
        let meeting = try Self.require(store.meetings.first, "imported meeting")
        try Self.check(
            meeting.title == "input" && meeting.jobs.count == 2 && meeting.segments.map(\.time) == [0, 30]
                && meeting.notes != nil && meeting.status == "完了",
            "a recording made elsewhere is transcribed and summarized like a live meeting")
        let folder = store.folder(meeting.id)
        try Self.check(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("議事録.md").path)
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent("録音.m4a").path)
                && FileManager.default.fileExists(atPath: audio.path),
            "the meeting folder holds minutes and audio, and the original file is untouched")
        let text = root.appendingPathComponent("memo.txt")
        try Data("not audio".utf8).write(to: text)
        await store.importRecording(from: text)
        let folders = try FileManager.default.contentsOfDirectory(atPath: save.path)
        try Self.check(
            store.error != nil && store.meetings.count == 1 && folders.count == 1,
            "a file without audio is refused and leaves nothing behind")
    }
}
