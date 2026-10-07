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
    // An utterance plays from its time on the meeting's clock, which is where it sits in 録音.m4a, also in a part
    // recorded after a break.
    func testPlaybackFindsEachUtteranceInTheRecording() async throws {
        let (root, tone) = try fixture(seconds: 3, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        for name in ["first.caf", "after-break.caf"] {
            try FileManager.default.copyItem(at: tone, to: folder.appendingPathComponent("chunks/" + name))
        }
        // The first part is 3 seconds; the meeting goes on after a break at 10 seconds on its clock.
        let manifest = RecordingManifest(chunks: [
            RecordedChunk(filename: "first.caf", offset: 0, source: "マイク"),
            RecordedChunk(filename: "after-break.caf", offset: 10, source: "マイク"),
        ])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("recording.json"))
        try await AudioMixdown.write(folder: folder)
        let segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "前半"),
            Segment(id: "b", time: 10, source: "マイク", text: "休憩のあと"),
            Segment(id: "c", time: 1, source: "Mac音声", text: "相手側"),
        ]
        let first = ClipPlayer.range(of: segments[0], in: segments)
        let later = ClipPlayer.range(of: segments[1], in: segments)
        try Self.check(
            first == 0...10 && later == 10...35 && ClipPlayer.range(of: segments[2], in: segments) == 1...26,
            "an utterance plays to the next one from the same source, at most 30 seconds: \(first), \(later)")
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("録音.m4a"))
        func loudness(at seconds: Double) throws -> Float {
            let rate = file.processingFormat.sampleRate
            file.framePosition = AVAudioFramePosition(seconds * rate)
            let frames = AVAudioFrameCount(rate * 0.5)
            let buffer = try Self.require(
                AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), "buffer")
            try file.read(into: buffer, frameCount: frames)
            let samples = try Self.require(buffer.floatChannelData?[0], "samples")
            let count = Int(buffer.frameLength)
            return count == 0 ? 0 : (0..<count).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(count)
        }
        let speech = try loudness(at: later.lowerBound + 0.5)
        let breakTime = try loudness(at: 6)
        try Self.check(
            speech > 0.001 && breakTime < 0.000_01,
            "the part after the break is heard from its utterance's time, with the break silent: \(speech), \(breakTime)"
        )
    }
    // A meeting folder synced from another Mac or restored appears in the list without a restart; a copy of a listed
    // meeting and a meeting.json still being written do not.
    @MainActor func testMeetingFoldersAddedWhileRunningAreListed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var here = Meeting(title: "この Mac の会議")
        here.capture = .stopped
        here.folderName = "2026-10-07 10.00 この Mac の会議"
        store.meetings = [here]
        try await store.checkpoint(here.id)
        func write(_ meeting: Meeting, to name: String) throws {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
        }
        var synced = Meeting(title: "別の Mac の会議")
        synced.date = here.date.addingTimeInterval(3600)
        synced.capture = .stopped
        try write(synced, to: "2026-10-07 11.00 別の Mac の会議")
        try write(here, to: "2026-10-07 10.00 この Mac の会議 (2)")
        let partial = root.appendingPathComponent("2026-10-07 12.00 同期中")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(#"{"id":"#.utf8).write(to: partial.appendingPathComponent("meeting.json"))
        await store.loadAddedMeetings()
        try Self.check(
            store.meetings.map(\.id) == [synced.id, here.id]
                && store.meetings[0].folderName == "2026-10-07 11.00 別の Mac の会議",
            "a synced meeting is listed in date order, without the copy or the half-written one")
        var later = Meeting(title: "同期中")
        later.date = here.date.addingTimeInterval(7200)
        try write(later, to: "2026-10-07 12.00 同期中")
        await store.loadAddedMeetings()
        await store.loadAddedMeetings()
        try Self.check(
            store.meetings.map(\.id) == [later.id, synced.id, here.id],
            "a meeting whose file finished writing is listed on the next change, and only once")
        store.change(synced.id) { $0.title = "こちらで直した" }
        await store.flushCheckpoints()
        let saved = try JSONDecoder().decode(
            Meeting.self,
            from: Data(contentsOf: root.appendingPathComponent("2026-10-07 11.00 別の Mac の会議/meeting.json")))
        try Self.check(saved.title == "こちらで直した", "a listed meeting is saved in its own folder")

        let watched = root.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        final class Seen: @unchecked Sendable { var changed = false }
        let seen = Seen()
        let watcher = FolderWatcher(watched) { seen.changed = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("x".utf8).write(to: watched.appendingPathComponent("new.txt"))
        for _ in 0..<50 where !seen.changed { try await Task.sleep(nanoseconds: 100_000_000) }
        withExtendedLifetime(watcher) {}
        try Self.check(seen.changed, "the save location is watched for changes")

        // The vocabulary list sits next to the meetings, to sync with them; a list kept before joins it once.
        try Self.check(
            VocabularyFile.merged("ギジログ\nモリバス", "モリバス、OKR\n高松") == "ギジログ\nモリバス\nOKR\n高松"
                && VocabularyFile.merged("", "OKR") == "OKR" && VocabularyFile.merged("A, B", "") == "A, B",
            "two lists become one without repeats, and one alone is kept as typed")
        try Self.check(
            VocabularyFile.read(in: watched) == nil && VocabularyFile.write("ギジログ\n高松", in: watched)
                && VocabularyFile.read(in: watched) == "ギジログ\n高松"
                && FileManager.default.fileExists(atPath: watched.appendingPathComponent("語句リスト.txt").path),
            "the list is saved as 語句リスト.txt in the save location")
    }
    // A listed meeting changed in the save location by another Mac is read again; changes made here and not yet saved
    // win, and this app's own saves are not taken for changes.
    @MainActor func testMeetingsChangedElsewhereAreReloaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "共有の会議")
        meeting.capture = .stopped
        meeting.folderName = "2026-10-07 18.00 共有の会議"
        store.meetings = [meeting]
        for _ in 0..<3 {
            store.change(meeting.id) { $0.status = "完了" }
            try await store.checkpoint(meeting.id)
        }
        let file = store.folder(meeting.id).appendingPathComponent("meeting.json")
        var later = Date().addingTimeInterval(5)
        func writeElsewhere(_ title: String) throws {
            var other = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
            other.title = title
            other.revision = 1  // The other Mac counts its own saves.
            try JSONEncoder().encode(other).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
            later.addTimeInterval(5)
        }
        await store.reloadChangedMeetings()
        try Self.check(store.meetings[0].title == "共有の会議", "this app's own saves are not read back")
        try writeElsewhere("別の Mac で直した")
        await store.reloadChangedMeetings()
        try Self.check(store.meetings[0].title == "別の Mac で直した", "a meeting changed on another Mac is read again")
        store.change(meeting.id) { $0.title = "こちらで直した" }
        await store.flushCheckpoints()
        func saved() throws -> String { try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file)).title }
        let afterReload = try saved()
        try Self.check(afterReload == "こちらで直した", "a change made here afterwards is saved, not refused as stale")
        store.change(meeting.id) { $0.title = "まだ保存していない" }
        try writeElsewhere("同時に直した")
        await store.reloadChangedMeetings()
        await store.flushCheckpoints()
        let together = try saved()
        try Self.check(
            store.meetings[0].title == "まだ保存していない" && together == "まだ保存していない",
            "a change here not yet saved wins over one made elsewhere")
        try writeElsewhere("録音中に直した")
        store.activeID = meeting.id
        await store.reloadChangedMeetings()
        try Self.check(store.meetings[0].title == "まだ保存していない", "a meeting being recorded here is not replaced")
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
