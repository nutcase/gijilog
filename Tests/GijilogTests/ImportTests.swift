import AVFoundation
import Foundation

extension ProcessingTests {
    func testImportCutsAnyRecordingIntoChunks() async throws {
        let (root, audio) = try fixture(seconds: 75, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("imported")
        let chunks = try await AudioImport.split(audio, into: folder)
        let lengths = try chunks.map {
            try AVAudioFile(forReading: folder.appendingPathComponent("chunks/" + $0.filename)).length
        }
        try Self.check(lengths.reduce(0, +) == 1_200_000, "no audio is lost or duplicated: \(lengths)")
        try Self.check(
            chunks.count > 2 && lengths.allSatisfy { Double($0) / AudioImport.sampleRate <= ChunkCutter.maximum }
                && zip(chunks, chunks.dropFirst()).enumerated().allSatisfy { i, pair in
                    abs(pair.1.offset - pair.0.offset - Double(lengths[i]) / AudioImport.sampleRate) < 0.001
                },
            "chunks follow one another on the recording's own clock, none longer than the limit: \(lengths)")
        let inputs = try Processor.recordingInputs(folder: folder)
        try Self.check(
            inputs.count == chunks.count && inputs.allSatisfy { $0.source == AudioImport.source },
            "imported chunks are listed like recorded ones")
    }
    func testImportCutsAtPauses() async throws {
        // Speech from 1 s to 40 s with one pause at 14 s: the first chunk ends inside the pause, and the second,
        // with no pause in it, ends at the length limit.
        let (root, audio) = try fixture(seconds: 40, amplitude: 0.25, silent: [0...1, 14...14.6])
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("imported")
        let chunks = try await AudioImport.split(audio, into: folder)
        let offsets = chunks.map(\.offset)
        try Self.check(
            offsets.count == 3 && (14.25...14.5).contains(offsets[1])
                && abs(offsets[2] - offsets[1] - ChunkCutter.maximum) < 0.1,
            "a chunk ends at a pause, not in the middle of a word: \(offsets)")
    }
    @MainActor func testImportedRecordingBecomesMinutes() async throws {
        let (root, audio) = try fixture(seconds: 45, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        let store = Store(root: save, loadSettings: false)
        store.key = "TEST"
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            recognize: { _, offset, source, _, _ in
                [Segment(time: offset, source: source, text: "\(Int(offset))秒の資料を確認します")]
            },
            summarize: MinutesEngine.stubSummary)
        await store.importRecording(from: audio)
        try await store.waitUntilIdle()
        await store.waitForBackgroundWork()
        let meeting = try Self.require(store.meetings.first, "imported meeting")
        try Self.check(
            meeting.title == "input" && meeting.jobs.count > 1
                && meeting.segments.map(\.time) == meeting.jobs.map(\.offset).sorted()
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
