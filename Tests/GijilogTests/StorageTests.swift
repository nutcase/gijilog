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
        // A sync arrives as a burst of changes, and each starts a load of its own while the last is still reading the
        // folders. Both used to find the meeting unlisted and both added it.
        var burst = Meeting(title: "一度に届いた会議")
        burst.date = later.date.addingTimeInterval(3600)
        try write(burst, to: "2026-10-07 13.00 一度に届いた会議")
        async let first: Void = store.loadAddedMeetings()
        async let second: Void = store.loadAddedMeetings()
        _ = await (first, second)
        try Self.check(
            store.meetings.filter { $0.id == burst.id }.count == 1,
            "a meeting reached by two loads at once is listed once: \(store.meetings.map(\.title))")
        store.meetings.removeAll { $0.id == burst.id }
        try FileManager.default.removeItem(at: root.appendingPathComponent("2026-10-07 13.00 一度に届いた会議"))
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
        let none = try VocabularyFile.read(in: watched)
        let written = VocabularyFile(terms: "ギジログ\n高松", corrections: "").write(in: watched)
        let read = try VocabularyFile.read(in: watched)
        try Self.check(
            none == nil && written && read?.terms == ["ギジログ", "高松"]
                && FileManager.default.fileExists(atPath: watched.appendingPathComponent("vocabulary.json").path),
            "the lists are saved as vocabulary.json in the save location")
    }
    // Both lists are kept as one JSON file, a term or a correction a line, to read and edit by hand. It is read
    // leniently, a file written wrong is left as it is, and the text files kept before join it.
    func testVocabularyIsKeptAsJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let lists = VocabularyFile(
            terms: "ギジログ\nモリバス、OKR\nギジログ", corrections: "森バス、もりばす → モリバス\nIQ → AIQ\n森 バス → モリバス")
        try Self.check(
            lists.json == """
                {
                  "terms": [
                    "ギジログ",
                    "モリバス",
                    "OKR"
                  ],
                  "corrections": [
                    { "heard": ["IQ"], "correct": "AIQ" },
                    { "heard": ["森バス", "もりばす", "森 バス"], "correct": "モリバス" }
                  ]
                }
                """ + "\n" && VocabularyFile().json == "{\n  \"terms\": [],\n  \"corrections\": []\n}\n",
            "the file has a term or a correction a line, without repeats, a word fixed again last")
        let reread = try VocabularyFile(json: Data(lists.json.utf8))
        try Self.check(reread == lists, "the file reads back as written")
        let typed = #"{"corrections": [{"heard": " 高山 ", "correct": "高松"}, {"heard": ["高松"], "correct": "高松"}]}"#
        let lenient = try VocabularyFile(json: Data(typed.utf8))
        let empty = try VocabularyFile(json: Data(" \n".utf8))
        try Self.check(
            lenient == VocabularyFile(corrections: [LearnedWord(variants: ["高山"], to: "高松")])
                && empty == VocabularyFile(),
            "a list may be left out, one spelling heard needs no brackets, and an empty file has empty lists")
        let broken = "{\n  \"terms\": [\n    \"ギジログ\"\n    \"OKR\"\n  ]\n}\n"
        var problem: VocabularyFile.Unreadable?
        do { _ = try VocabularyFile(json: Data(broken.utf8)) } catch { problem = error as? VocabularyFile.Unreadable }
        try Self.check(
            problem?.line == 4, "a file written wrong is not read, and says the line: \(String(describing: problem))")

        // The vocabulary keeps as many terms as transcription takes as keywords; those past it are not saved.
        let crowded = VocabularyFile(terms: (1...120).map { "語\($0)" }.joined(separator: "\n"), corrections: "")
        try Self.check(
            crowded.terms.count == VocabularyFile.termLimit && crowded.terms.last == "語\(VocabularyFile.termLimit)",
            "the vocabulary keeps its first \(VocabularyFile.termLimit) terms")
        // When the file last changed is known without reading it, so a save reads it again only when it changed.
        try Self.check(
            VocabularyFile.modified(in: root) == nil, "a save location without the file has no time for it")
        // Writing the same lists again leaves the file alone, not to stir the sync.
        let file = root.appendingPathComponent("vocabulary.json")
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try Self.check(lists.write(in: root), "the lists are written")
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        lists.write(in: root)
        let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try Self.check(
            modified == past && VocabularyFile.modified(in: root) == past,
            "the same lists are not written again")

        // The text files kept before join the file and go.
        let oldTerms = root.appendingPathComponent("語句リスト.txt")
        let oldCorrections = root.appendingPathComponent("聞き間違い.txt")
        try Data("高松\nOKR".utf8).write(to: oldTerms)
        try Data("高山 → 高松\nもりばす → モリバス".utf8).write(to: oldCorrections)
        VocabularyFile.adoptOldFiles(in: root)
        let adopted = try VocabularyFile.read(in: root)
        try Self.check(
            adopted?.terms == ["ギジログ", "モリバス", "OKR", "高松"]
                && adopted?.corrections == [
                    LearnedWord(variants: ["IQ"], to: "AIQ"), LearnedWord(variants: ["高山"], to: "高松"),
                    LearnedWord(variants: ["森バス", "もりばす", "森 バス"], to: "モリバス"),
                ]
                && !FileManager.default.fileExists(atPath: oldTerms.path)
                && !FileManager.default.fileExists(atPath: oldCorrections.path),
            "the old text files join vocabulary.json and are removed: \(String(describing: adopted))")
        try Data(broken.utf8).write(to: file)
        try Data("高松".utf8).write(to: oldTerms)
        VocabularyFile.adoptOldFiles(in: root)
        let left = try String(contentsOf: file, encoding: .utf8)
        try Self.check(
            left == broken && FileManager.default.fileExists(atPath: oldTerms.path),
            "a file written wrong is left as it is, and the old ones with it")

        // A file that is there but cannot be read (as an iCloud file not yet downloaded) is not taken for none, which
        // the next save would write over.
        let elsewhere = root.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(
            at: elsewhere.appendingPathComponent(VocabularyFile.name), withIntermediateDirectories: true)
        var unopened: VocabularyFile.Unreadable?
        do { _ = try VocabularyFile.read(in: elsewhere) } catch { unopened = error as? VocabularyFile.Unreadable }
        try Self.check(
            unopened?.cannotOpen == true && unopened?.message.contains("開けません") == true,
            "a file that cannot be read is an error, not a missing file: \(String(describing: unopened))")

        // Changes made here since the file was last read join another Mac's changes to it, rather than replacing them.
        let base = VocabularyFile(terms: "ギジログ\n高松\nOKR", corrections: "森バス → モリバス\n高山 → 高松")
        let mine = VocabularyFile(terms: "ギジログ\nOKR\nAIQ", corrections: "森バス → モリバス\n高山 → 高松\nIQ → AIQ")
        let theirs = VocabularyFile(terms: "ギジログ\n高松\nOKR\nやるナビ", corrections: "森バス、もりばす → モリバス")
        let joined = VocabularyFile.merged(base: base, mine: mine, theirs: theirs)
        try Self.check(
            joined.terms == ["ギジログ", "OKR", "やるナビ", "AIQ"]
                && joined.corrections == [
                    LearnedWord(variants: ["森バス", "もりばす"], to: "モリバス"), LearnedWord(variants: ["IQ"], to: "AIQ"),
                ],
            "terms and spellings added on either Mac stay, and those removed on either go: \(joined)")
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
        let early = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        var later = Date().addingTimeInterval(5)
        // Another Mac's save counts one more save of its own onto the version it read; one that had not synced read
        // an older one.
        func writeElsewhere(_ title: String, behind: Bool = false) throws {
            var other = try JSONDecoder().decode(
                Meeting.self, from: behind ? JSONEncoder().encode(early) : Data(contentsOf: file))
            other.title = title
            other.revision += 1
            other.saveCounts = SaveCounts.of(other).adding("another Mac")
            other.savedOn = "別の Mac"
            try JSONEncoder().encode(other).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
            later.addTimeInterval(5)
        }
        await store.reloadChangedMeetings()
        try Self.check(store.meetings[0].title == "共有の会議", "this app's own saves are not read back")
        try writeElsewhere("別の Mac で直した")
        await store.reloadChangedMeetings()
        try Self.check(store.meetings[0].title == "別の Mac で直した", "a meeting changed on another Mac is read again")
        // A change arriving while the meeting is open for editing here waits, and comes in once the edit closes
        // without changing the meeting: it is not taken as read before it is taken in.
        store.selected = meeting.id
        store.editingTitle = meeting.id
        try writeElsewhere("編集中に届いた")
        await store.reloadChangedMeetings()
        let whileEditing = store.meetings[0].title
        store.editingTitle = nil
        await store.reloadChangedMeetings()
        try Self.check(
            whileEditing == "別の Mac で直した" && store.meetings[0].title == "編集中に届いた",
            "a change left while editing is taken in afterwards: \(whileEditing), \(store.meetings[0].title)")
        store.change(meeting.id) { $0.title = "こちらで直した" }
        await store.flushCheckpoints()
        func saved() throws -> String { try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file)).title }
        let afterReload = try saved()
        try Self.check(afterReload == "こちらで直した", "a change made here afterwards is saved, not refused as stale")
        // Changed on both Macs at once: this Mac's version stays, the other's is kept aside, and neither is lost.
        store.change(meeting.id) { $0.title = "まだ保存していない" }
        try writeElsewhere("同時に直した")
        let theirs = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        await store.reloadChangedMeetings()
        await store.flushCheckpoints()
        let together = try saved()
        let aside = store.folder(meeting.id).appendingPathComponent(MeetingRepository.asideName)
        func asideTitle() throws -> String {
            try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: aside)).title
        }
        let keptAside = try asideTitle()
        try Self.check(
            store.meetings[0].title == "まだ保存していない" && together == "まだ保存していない" && keptAside == "同時に直した"
                && store.meetings[0].conflict?.savedOn == "別の Mac",
            "a meeting changed on both Macs keeps this Mac's version and the other's aside: \(together), \(keptAside)")
        let ours = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        try Self.check(
            SaveCounts.of(ours).includes(SaveCounts.of(theirs)) && SaveCounts.of(ours) != SaveCounts.of(theirs),
            "and is saved past both, so the other Mac takes it in rather than keeping one aside in turn")
        // A version written on a Mac whose copy was behind would undo what was done since: it is not taken in, and
        // this Mac's goes back over it.
        try writeElsewhere("同期の遅れた古い版", behind: true)
        await store.reloadChangedMeetings()
        let afterStale = try saved()
        try Self.check(
            store.meetings[0].title == "まだ保存していない" && afterStale == "まだ保存していない",
            "an older version from another Mac is refused, and this Mac's saved over it")
        try writeElsewhere("録音中に直した")
        store.activeID = meeting.id
        await store.reloadChangedMeetings()
        let duringRecording = try asideTitle()
        try Self.check(
            store.meetings[0].title == "まだ保存していない" && duringRecording == "録音中に直した",
            "a meeting being recorded here is not replaced; the change made elsewhere is kept aside")
        store.activeID = nil
        // Either version can be put in place of the other, and the one let go only when the user keeps one.
        await store.swapConflict(meeting.id)
        await store.flushCheckpoints()
        let swapped = try saved()
        let nowAside = try asideTitle()
        try Self.check(
            store.meetings[0].title == "録音中に直した" && swapped == "録音中に直した" && nowAside == "まだ保存していない",
            "swapping puts the version aside in place and keeps the one shown aside")
        await store.dismissConflict(meeting.id)
        await store.flushCheckpoints()
        try Self.check(
            store.meetings[0].conflict == nil && !FileManager.default.fileExists(atPath: aside.path),
            "keeping the version shown lets the other go")
    }
    // While the app was not running, the meeting was changed both on another Mac and, before it quit, here: on the
    // next launch this Mac's version is shown and the other's kept aside. Work another Mac left unfinished is taken
    // up only when asked, and a file in a newer form than this version knows is not written.
    @MainActor func testTwoMacsKeepBothVersionsAndHandOverWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        let copies = root.appendingPathComponent("copies")
        let store = Store(root: save, loadSettings: false, copies: copies)
        var meeting = Meeting(title: "こちらで直した")
        meeting.folderName = "both"
        meeting.capture = .stopped
        meeting.workingMac = store.thisMac
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        let file = save.appendingPathComponent("both/meeting.json")
        var base = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        try await store.checkpoint(meeting.id)  // A save here the other Mac never saw.
        base.title = "あちらで直した"
        base.saveCounts = SaveCounts.of(base).adding("another Mac")
        base.savedOn = "別の Mac"
        try JSONEncoder().encode(base).write(to: file)
        let relaunched = Store(root: save, loadSettings: false, copies: copies)
        await relaunched.recover()
        await relaunched.flushCheckpoints()
        let asideFile = save.appendingPathComponent("both/" + MeetingRepository.asideName)
        let merged = try relaunched.savedMeeting(meeting.id)
        try Self.check(
            relaunched.meetings.first?.title == "あちらで直した" && merged.title == "あちらで直した"
                && merged.conflict == nil && !FileManager.default.fileExists(atPath: asideFile.path)
                && SaveCounts.of(merged).includes(SaveCounts.of(base)),
            "changed on both while closed, from a version this Mac keeps: merged into one")

        // Without that version (gone from this Mac's history), this Mac's version shows and the other's is kept aside.
        let editor = Store(root: save, loadSettings: false, copies: copies)
        await editor.recover()
        editor.change(meeting.id) { $0.title = "こちらでまた直した" }
        try await editor.checkpoint(meeting.id)
        try FileManager.default.removeItem(at: copies.appendingPathComponent(meeting.id.uuidString + ".history"))
        var other = merged
        other.title = "あちらでまた直した"
        other.saveCounts = SaveCounts.of(merged).adding("another Mac")
        other.revision += 1
        other.savedOn = "別の Mac"
        try JSONEncoder().encode(other).write(to: file)
        let again = Store(root: save, loadSettings: false, copies: copies)
        await again.recover()
        await again.flushCheckpoints()
        let aside = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: asideFile))
        let saved = try again.savedMeeting(meeting.id)
        try Self.check(
            again.meetings.first?.title == "こちらでまた直した" && saved.title == "こちらでまた直した"
                && aside.title == "あちらでまた直した" && saved.conflict?.savedOn == "別の Mac" && saved.conflict?.spots == nil
                && SaveCounts.of(saved).includes(SaveCounts.of(other)),
            "changed on both while closed, with no version both had: this Mac's shows and the other's is kept aside")

        // Another Mac's unfinished work waits for it, until this Mac is asked to take it up.
        var elsewhere = Meeting(title: "ほかの Mac で仕上げ中")
        elsewhere.folderName = "elsewhere"
        elsewhere.workingMac = "another Mac"
        elsewhere.capture = .stopped
        elsewhere.hasAudio = true
        elsewhere.settings = SessionSettings()
        elsewhere.finalReviewPending = true
        elsewhere.segments = [Segment(id: "s0", time: 0, source: "マイク", text: "新しい案を採用します")]
        var notes = MinutesState()
        notes.appliedSegmentIDs = ["s0"]
        notes.content.decisions = [NoteItem(id: "d1", text: "新しい案を採用する", evidence: ["s0"])]
        elsewhere.notes = notes
        try await MeetingRepository(root: save).save(elsewhere)
        let here = Store(root: save, loadSettings: false, copies: copies)
        here.key = "TEST"
        var reviews = 0
        here.pipeline = ProcessingPipeline(
            store: here,
            review: { state, _, _, _ in
                reviews += 1
                return state
            }, recognize: { _, _, _, _, _ in throw AppError.message("must not transcribe") })
        await here.recover()
        try await here.waitUntilIdle()
        let waiting = reviews == 0 && here.meetings.first { $0.id == elsewhere.id }?.workingMac == "another Mac"
        await here.continueHere(elsewhere.id)
        try await here.waitUntilIdle()
        await here.waitForBackgroundWork()
        let finished = try here.savedMeeting(elsewhere.id)
        try Self.check(
            waiting && reviews == 1 && finished.workingMac == here.thisMac && finished.finalReviewPending == false,
            "another Mac's unfinished work is taken up only when asked, and then finished here")

        var newer = Meeting(title: "新しい形式")
        newer.folderName = "newer"
        newer.schemaVersion = Meeting.schema + 1
        var refused = false
        do { try await MeetingRepository(root: save).save(newer) } catch { refused = true }
        try Self.check(refused, "a meeting in a form newer than this version knows is not written")
    }
    // Any Mac can change a meeting another Mac records: the change is saved past that Mac's saves, so it takes the
    // change in, and the meeting stays that Mac's for taking up unfinished work.
    @MainActor func testAnyMacChangesAMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "ほかの Mac の会議")
        meeting.folderName = "theirs"
        meeting.capture = .stopped
        meeting.workingMac = "another Mac"
        meeting.notes = MinutesState()
        meeting.segments = [Segment(id: "s0", time: 0, source: "マイク", text: "資料を確認します")]
        meeting.revision = 5
        meeting.saveCounts = SaveCounts(["another Mac": 5])
        try await MeetingRepository(root: root).save(meeting)
        await store.recover()
        let shown = try Self.require(store.meetings.first, "the meeting")
        try Self.check(
            store.canEditMinutes(shown) && store.canEditTranscript(shown) && store.canDelete(meeting.id),
            "another Mac's meeting can be changed here")
        store.renameMeeting(meeting.id, to: "こちらで直した")
        await store.flushCheckpoints()
        let saved = try JSONDecoder().decode(
            Meeting.self, from: Data(contentsOf: root.appendingPathComponent("theirs/meeting.json")))
        try Self.check(
            saved.title == "こちらで直した" && saved.workingMac == "another Mac"
                && SaveCounts.of(saved).includes(SaveCounts(["another Mac": 5]))
                && SyncVerdict.of(saved, here: SaveCounts(["another Mac": 5]), hereRevision: 5) == .newer,
            "the change is saved as the later version, and the meeting stays the other Mac's")

        // A recording is not ended by another app asking ギジログ to quit; the user, the Dock and shutting down are.
        try Self.check(
            Store.refusesQuit(recording: true, sender: "com.example.quitter", fromThisApp: false, systemReason: false)
                && Store.refusesQuit(recording: true, sender: "", fromThisApp: false, systemReason: false)
                && !Store.refusesQuit(
                    recording: false, sender: "com.example.quitter", fromThisApp: false, systemReason: false)
                && !Store.refusesQuit(recording: true, sender: nil, fromThisApp: false, systemReason: false)
                && !Store.refusesQuit(
                    recording: true, sender: "com.apple.dock", fromThisApp: false, systemReason: false)
                && !Store.refusesQuit(
                    recording: true, sender: "com.apple.loginwindow", fromThisApp: false, systemReason: true)
                && !Store.refusesQuit(
                    recording: true, sender: "io.github.nutcase.gijilog", fromThisApp: true, systemReason: false),
            "only another app's quit is turned down, and only while recording")
    }
    // Two Macs that saved the same meeting at once, alike in all the user sees, keep one version, not two to choose
    // from: whatever order a set was written in, whatever the save counts. One already kept aside goes on launch.
    @MainActor func testAlikeVersionsAreJoined() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "同じ会議")
        meeting.folderName = "alike"
        meeting.capture = .stopped
        var notes = MinutesState()
        notes.appliedSegmentIDs = Set((0..<20).map { "s\($0)" })
        meeting.notes = notes
        meeting.stoppedForSilence = Date(timeIntervalSince1970: 1_790_000_000)
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        let file = root.appendingPathComponent("alike/meeting.json")
        let base = try Data(contentsOf: file)
        try await store.checkpoint(meeting.id)  // A save here the other Mac never saw.
        // The other Mac saved the same meeting from the first save: its own count, the set in another order, and
        // the silence notice dismissed.
        var json = try Self.require(try JSONSerialization.jsonObject(with: base) as? [String: Any], "the saved meeting")
        var savedNotes = try Self.require(json["notes"] as? [String: Any], "notes")
        savedNotes["appliedSegmentIDs"] = Array((savedNotes["appliedSegmentIDs"] as? [String] ?? []).reversed())
        json["notes"] = savedNotes
        json["saveCounts"] = (json["saveCounts"] as? [String: Any] ?? [:]).merging(["another Mac": 1]) { a, _ in a }
        json["savedOn"] = "別の Mac"
        json.removeValue(forKey: "stoppedForSilence")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let theirs = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        var renamed = theirs
        renamed.title = "別の題"
        try Self.check(
            theirs.sameContent(as: store.meetings[0]) && !renamed.sameContent(as: store.meetings[0]),
            "versions alike but for set order, counts and a dismissed notice hold the same meeting; a title does not")
        await store.reloadChangedMeetings()
        await store.flushCheckpoints()
        let saved = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        let aside = root.appendingPathComponent("alike/" + MeetingRepository.asideName)
        try Self.check(
            !FileManager.default.fileExists(atPath: aside.path) && store.meetings[0].conflict == nil
                && saved.stoppedForSilence == nil && SaveCounts.of(saved).includes(SaveCounts.of(theirs))
                && SyncVerdict.of(saved, here: SaveCounts.of(theirs), hereRevision: theirs.revision) == .newer,
            "saved alike on both Macs, the meeting stays one version, saved past both")

        // A version kept aside before alike ones were joined goes on the next launch.
        var shown = saved
        shown.conflict = MeetingConflict(savedOn: "別の Mac", found: Date())
        try await MeetingRepository(root: root).save(shown)
        try await MeetingRepository(root: root).keepAside(theirs)
        let relaunched = Store(root: root, loadSettings: false)
        await relaunched.recover()
        await relaunched.flushCheckpoints()
        let resaved = try relaunched.savedMeeting(meeting.id)
        try Self.check(
            relaunched.meetings.first?.conflict == nil && !FileManager.default.fileExists(atPath: aside.path)
                && resaved.conflict == nil,
            "a version kept aside that holds the same meeting is let go on launch")
    }
    // Which of two versions is the later one, by each Mac's save count.
    func testSaveCountsTellNewerOlderAndBoth() throws {
        var base = Meeting(title: "会議")
        base.saveCounts = SaveCounts(["A": 3, "B": 1])
        func version(_ counts: [String: UInt64]) -> Meeting {
            var meeting = base
            meeting.saveCounts = SaveCounts(counts)
            return meeting
        }
        let here = SaveCounts(["A": 3, "B": 1])
        try Self.check(
            SyncVerdict.of(version(["A": 3, "B": 1]), here: here, hereRevision: 4) == .same
                && SyncVerdict.of(version(["A": 3, "B": 2]), here: here, hereRevision: 4) == .newer
                && SyncVerdict.of(version(["A": 2, "B": 1]), here: here, hereRevision: 4) == .older
                && SyncVerdict.of(version(["A": 2, "B": 2]), here: here, hereRevision: 4) == .both,
            "a version is the same, newer, older, or changed on both Macs")
        // However many times a Mac saves from a copy that was behind, it does not become the later version.
        try Self.check(
            SyncVerdict.of(version(["A": 2, "B": 900]), here: SaveCounts(["A": 3, "B": 1]), hereRevision: 4) == .both,
            "saving many times from an old copy does not make a version newer")
        var legacy = Meeting(title: "以前の形式")
        legacy.revision = 10
        let decoded = try JSONDecoder().decode(
            Meeting.self,
            from: Data(
                #"{"id":"\#(UUID().uuidString)","title":"x","date":0,"segments":[],"minutes":"","status":"完了"}"#.utf8))
        try Self.check(
            SyncVerdict.of(legacy, here: here, hereRevision: 9) == .newer
                && SyncVerdict.of(legacy, here: here, hereRevision: 11) == .older
                && SaveCounts.of(legacy) == SaveCounts([SaveCounts.legacy: 10]) && decoded.schemaVersion == 1
                && Meeting(title: "新しい会議").schemaVersion == Meeting.schema,
            "a file from before the counts is told by its save count, and reads as the first form")
    }
    // A sync can bring back an older meeting.json, written on a Mac whose copy was behind. This Mac's own copy, kept
    // outside the save location, puts its version back on the next launch; a newer file is read as it is.
    func testThisMacsCopyOutlastsAnOlderSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        let copies = root.appendingPathComponent("copies")
        var meeting = Meeting(title: "中長期戦略会議")
        meeting.folderName = "2026-10-09 16.00 会議"
        meeting.capture = .stopped
        meeting.revision = 754
        try await MeetingRepository(root: save, copies: copies).save(meeting)
        let file = save.appendingPathComponent("2026-10-09 16.00 会議/meeting.json")
        var old = meeting
        old.title = "会議 2026/10/9 16:00"
        old.capture = .recording
        old.revision = 623
        try JSONEncoder().encode(old).write(to: file)
        let relaunched = MeetingRepository(root: save, copies: copies)
        let (loaded, _) = try await relaunched.load()
        let restored = await relaunched.takeRestored()
        let onDisk = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        try Self.check(
            loaded.map(\.title) == ["中長期戦略会議"] && loaded.first?.capture == .stopped
                && restored == ["中長期戦略会議"] && onDisk.revision == 754 && onDisk.title == "中長期戦略会議",
            "an older version brought back by sync gives way to this Mac's copy: \(loaded.map(\.title))")
        var newer = meeting
        newer.title = "ほかの Mac で直した"
        newer.revision = 755
        try JSONEncoder().encode(newer).write(to: file)
        let (again, _) = try await MeetingRepository(root: save, copies: copies).load()
        let (third, _) = try await MeetingRepository(root: save, copies: copies).load()
        try Self.check(
            again.map(\.title) == ["ほかの Mac で直した"] && third.map(\.title) == ["ほかの Mac で直した"],
            "a newer version made elsewhere is read as it is, and becomes this Mac's copy")
        try await MeetingRepository(root: save, copies: copies).delete(newer)
        try Self.check(
            !FileManager.default.fileExists(
                atPath: copies.appendingPathComponent(meeting.id.uuidString + ".json").path),
            "deleting a meeting deletes this Mac's copy too")
    }
    @MainActor func testAddedMeetingKeepsRecoveryCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        let copies = root.appendingPathComponent("copies")
        let store = Store(root: save, loadSettings: false, copies: copies)
        await store.recover()
        var meeting = Meeting(title: "同期された新しい内容")
        meeting.folderName = "synced"
        meeting.capture = .stopped
        meeting.revision = 20
        try await MeetingRepository(root: save).save(meeting)
        await store.loadAddedMeetings()
        let copyFile = copies.appendingPathComponent(meeting.id.uuidString + ".json")
        let copy = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: copyFile))
        try Self.check(
            copy.title == meeting.title && copy.revision == 20, "an accepted new meeting gets a recovery copy")

        // A duplicate folder that is not accepted must not replace the copy of the listed meeting.
        var duplicate = meeting
        duplicate.folderName = "synced (2)"
        duplicate.title = "取り込まない写し"
        duplicate.revision = 30
        try await MeetingRepository(root: save).save(duplicate)
        await store.loadAddedMeetings()
        let unchanged = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: copyFile))
        try Self.check(
            store.meetings.count == 1 && unchanged.title == meeting.title, "rejected duplicates leave the copy alone")
        try FileManager.default.removeItem(at: save.appendingPathComponent("synced (2)"))

        var old = meeting
        old.title = "同期で届いた古い内容"
        old.revision = 10
        try await MeetingRepository(root: save).save(old)
        let relaunched = MeetingRepository(root: save, copies: copies)
        let (loaded, _) = try await relaunched.load()
        let restored = await relaunched.takeRestored()
        try Self.check(
            loaded.first?.title == meeting.title && loaded.first?.revision == 20 && restored == [meeting.title],
            "a meeting added while running survives an older sync on the next launch")
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
