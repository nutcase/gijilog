import AVFoundation
import Foundation

extension ProcessingTests {
    @MainActor func testMeetingFolderHoldsMinutesAndAudio() async throws {
        let (root, audio) = try fixture(seconds: 3, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("save"), loadSettings: false)
        var meeting = Meeting(title: "週次定例")
        meeting.capture = .stopped
        meeting.folderName = meetingFolderName(date: meeting.date, title: meeting.title)
        meeting.segments = [Segment(id: "a", time: 0, source: "マイク", text: "資料を確認します")]
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        let folder = store.folder(meeting.id)
        try Self.check(folder.lastPathComponent.hasSuffix(" 週次定例"), "the folder is named by date and title")
        let document = try String(contentsOf: folder.appendingPathComponent("議事録.md"), encoding: .utf8)
        try Self.check(
            document.hasPrefix("# 週次定例") && document.contains("資料を確認します"),
            "readable minutes are saved next to the audio")
        // Two tracks on the common clock: the Mac audio pauses for a second, and the microphone starts 6 seconds in,
        // so only a correct leading gap on the microphone track makes the mix 9 seconds long.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        for name in ["system.caf", "mic.caf", "system2.caf"] {
            try FileManager.default.copyItem(at: audio, to: folder.appendingPathComponent("chunks/" + name))
        }
        let manifest = RecordingManifest(chunks: [
            RecordedChunk(filename: "system.caf", offset: 0, source: "Mac音声"),
            RecordedChunk(filename: "mic.caf", offset: 6, source: "マイク"),
            RecordedChunk(filename: "system2.caf", offset: 4, source: "Mac音声"),
        ])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("recording.json"))
        try await AudioMixdown.write(folder: folder)
        let mixed = AVURLAsset(url: folder.appendingPathComponent("録音.m4a"))
        let seconds = try await mixed.load(.duration).seconds
        try Self.check(abs(seconds - 9) < 0.2, "both tracks are mixed on the recording clock: \(seconds)s")
    }
    @MainActor func testSaveLocationMovesWithItsMeetings() async throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let store = Store(root: first, loadSettings: false)
        var meeting = Meeting(title: "移動する会議")
        meeting.capture = .stopped
        meeting.folderName = "2026-10-03 17.26 移動する会議"
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        await store.changeStorage(to: second)
        let moved = second.appendingPathComponent("2026-10-03 17.26 移動する会議")
        try Self.check(
            FileManager.default.fileExists(atPath: moved.appendingPathComponent("meeting.json").path)
                && !FileManager.default.fileExists(atPath: first.appendingPathComponent(meeting.folderName ?? "").path),
            "the meeting folder moves to the new save location")
        try Self.check(
            store.root == second && store.meetings.map(\.id) == [meeting.id] && store.folder(meeting.id) == moved,
            "the list and later saves follow the new location")
        store.change(meeting.id) { $0.title = "移動後に変更" }
        await store.flushCheckpoints()
        let saved = try store.savedMeeting(meeting.id)
        try Self.check(saved.title == "移動後に変更", "changes are written to the new location")
    }
    func testLegacyMeetingsMoveToReadableFolders() throws {
        let (root, _) = try fixture(seconds: 1, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy")
        let target = root.appendingPathComponent("target")
        var untitled = Meeting(title: "会議 2026/10/3 17:26")
        untitled.date = Date(timeIntervalSince1970: 1_791_000_000)
        let titled = Meeting(title: "A社/定例")
        for meeting in [untitled, titled] {
            let folder = legacy.appendingPathComponent(meeting.id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
        }
        let failures = try MeetingRepository.moveMeetings(
            from: legacy, to: target, rename: { meetingFolderName(date: $0.date, title: $0.title) })
        let names = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
        try Self.check(failures.isEmpty && names.count == 2, "every old meeting moves")
        try Self.check(
            names.contains(meetingFolderName(date: untitled.date, title: "会議"))
                && names.contains { $0.hasSuffix(" A社-定例") },
            "folders are named by date and a file-safe title: \(names)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: legacy.path)
        try Self.check(leftovers.isEmpty, "nothing is left behind")
    }
}
