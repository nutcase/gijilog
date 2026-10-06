import Foundation

extension ProcessingTests {
    func testMisheardWordsAreFoundBySpellingAndReading() throws {
        try Self.check(
            TermMatcher.reading("森バス") == "moribasu" && TermMatcher.reading("もりばす") == TermMatcher.reading("モリバス")
                && TermMatcher.reading("高松") != TermMatcher.reading("高山"),
            "spellings that read the same match, different names do not")
        let product = TermMatcher.changedTerm(from: "森バスのコストを整理中", to: "モリバスのコストを整理中")
        let name = TermMatcher.changedTerm(from: "高山さんに確認する", to: "高松さんに確認する")
        try Self.check(
            product?.from == "森バス" && product?.to == "モリバス" && name?.from == "高山" && name?.to == "高松",
            "an edit is read as whole words: \(String(describing: product)), \(String(describing: name))")
        try Self.check(
            TermMatcher.changedTerm(from: "A案にする", to: "A案にする") == nil
                && TermMatcher.changedTerm(from: "短い", to: "まったく別の、ずっと長い文章へと書き換えてしまった結果") == nil,
            "no change, or a rewrite, offers no correction")

        var meeting = Meeting(title: "森バス定例")
        meeting.segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "森バスの件です"),
            Segment(id: "b", time: 10, source: "Mac音声", text: "もりばすのコストは"),
            Segment(id: "c", time: 20, source: "Mac音声", text: "モリバスは好調です"),
        ]
        var notes = MinutesState()
        notes.content.summary = [NoteItem(id: "s1", text: "森バス：整理中", evidence: ["a"])]
        notes.content.actions = [NoteItem(id: "x1", text: "資料を作る", owner: "森バス担当", evidence: ["b"])]
        meeting.notes = notes
        let found = meeting.occurrences(of: "森バス", correctedTo: "モリバス")
        try Self.check(
            found.map(\.found) == ["森バス", "森バス", "森バス", "森バス", "もりばす"]
                && found.filter(\.exact).count == 4 && !found.contains { $0.place == .segment("c") },
            "the title, minutes, owner and transcript are searched, and the right spelling is left out: \(found)")

        let correction = meeting.correct(found, to: "モリバス")
        try Self.check(
            meeting.title == "モリバス定例" && meeting.segments.map(\.text) == ["モリバスの件です", "モリバスのコストは", "モリバスは好調です"]
                && meeting.notes?.content.summary[0].text == "モリバス：整理中"
                && meeting.notes?.content.actions[0].owner == "モリバス担当"
                && correction.variants == ["森バス", "もりばす"] && meeting.corrections.count == 1,
            "every chosen occurrence is fixed, and the correction is kept")
        try Self.check(
            meeting.corrected("もりばすと森バス") == "モリバスとモリバス", "text written later gets the same correction")
        meeting.undo(correction.id)
        try Self.check(
            meeting.title == "森バス定例" && meeting.segments[1].text == "もりばすのコストは" && meeting.corrections.isEmpty,
            "a correction can be undone")
        try Self.check(
            TermMatcher.replacing(["郡"], with: "郡司", in: "郡司さんと郡さん") == "郡司さんと郡司さん",
            "the right spelling is never corrected inside itself")
    }
    func testHandEditsSurviveAIUpdates() throws {
        let first = Segment(id: "s1", time: 0, source: "マイク", text: "B案にします")
        let second = Segment(id: "s2", time: 30, source: "マイク", text: "資料は田中さんが金曜までに作ります")
        var state = MinutesState()
        state.appliedSegmentIDs = ["s1"]
        state.content.decisions = [NoteItem(id: "d1", text: "B案にする（手直し）", evidence: ["s1"], edited: true)]
        state.dismissed = [MinutesEngine.normalized("不要な項目")]
        let delta = NotesDelta(
            decisions: [
                NoteItem(id: "d1", text: "A案にする", evidence: ["s2"]),
                NoteItem(id: "", text: "不要な項目", evidence: ["s2"]),
            ],
            actions: [NoteItem(id: "", text: "資料を作る", owner: "田中", due: "金曜", evidence: ["s2"])])
        let merged = MinutesEngine.merge(state, delta: delta, batch: [second], segments: [first, second])
        try Self.check(
            merged.content.decisions.map(\.text) == ["B案にする（手直し）"] && merged.content.actions.count == 1,
            "a live update leaves an edited item and a deleted one alone")
        let rewritten = try MinutesEngine.rewrite(
            state,
            delta: NotesDelta(decisions: [
                NoteItem(id: "", text: "B案にする（手直し）", evidence: ["s1"]),
                NoteItem(id: "", text: "不要な項目", evidence: ["s1"]),
                NoteItem(id: "", text: "C案も検討する", evidence: ["s2"]),
            ]), transcript: [first, second])
        try Self.check(
            rewritten.content.decisions.map(\.text) == ["B案にする（手直し）", "C案も検討する"]
                && rewritten.content.decisions[0].edited == true,
            "the final review keeps edited items, without duplicates or deleted ones")
        var spelled = state
        spelled.corrections = [TermCorrection(variants: ["森バス"], to: "モリバス")]
        let input = try MinutesEngine.reviewInput(spelled, transcript: [first, second])
        let payload = try Self.require(
            JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any], "review payload")
        let draft = payload["draft"] as? [String: Any]
        try Self.check(
            (draft?["decisions"] as? [Any])?.isEmpty == true && payload["fixed"] != nil && payload["dismissed"] != nil
                && input.contains("モリバス"),
            "the review is told what was fixed, deleted, and how words are spelled")
        let hints = TranscriptionHints(
            meeting: {
                var meeting = Meeting(title: "定例")
                meeting.corrections = spelled.corrections
                return meeting
            }(), before: 0, vocabulary: "ギジログ")
        try Self.check(hints.terms == ["ギジログ", "モリバス"], "transcription is told the corrected spellings")
    }
    @MainActor func testEditingMinutesByHand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "定例")
        meeting.capture = .stopped
        meeting.status = "完了"
        meeting.segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "森バスの価格を決めます"),
            Segment(id: "b", time: 10, source: "Mac音声", text: "森バスは来月リリースです"),
        ]
        var notes = MinutesState()
        notes.content.summary = [NoteItem(id: "s1", text: "森バス：価格を決める", evidence: ["a"])]
        notes.content.decisions = [NoteItem(id: "d1", text: "来月リリースする", evidence: ["b"])]
        meeting.notes = notes
        store.meetings = [meeting]
        try Self.check(store.canEditMinutes(store.meetings[0]), "a finished meeting can be edited")

        store.updateNoteItem(meeting.id, part: .summary, id: "s1") { $0.text = "モリバス：価格を決める" }
        let offer = try Self.require(store.correctionOffer, "an offer to fix the word elsewhere")
        try Self.check(
            store.meetings[0].notes?.content.summary[0].edited == true && offer.from == "森バス" && offer.to == "モリバス"
                && offer.count == 2,
            "an edit marks the item and offers to fix the same word in both utterances")
        store.applyOfferedCorrection()
        try Self.check(
            store.meetings[0].segments.allSatisfy { $0.text.hasPrefix("モリバス") } && store.correctionOffer == nil
                && store.vocabulary == "モリバス",
            "the word is fixed in the transcript, and the right spelling joins the vocabulary")

        let added = try Self.require(store.addNoteItem(meeting.id, part: .actions, text: " 議事録を共有する "), "added")
        store.removeNoteItem(meeting.id, part: .decisions, id: "d1")
        let edited = try Self.require(store.meetings[0].notes, "edited notes")
        try Self.check(
            edited.content.actions.map(\.text) == ["議事録を共有する"] && edited.content.actions[0].id == added
                && edited.content.decisions.isEmpty && edited.dismissed == [MinutesEngine.normalized("来月リリースする")],
            "items can be added and deleted, and a deleted AI item is remembered")

        let correction = try Self.require(store.meetings[0].corrections.first, "the correction")
        store.undoCorrection(meeting.id, correction.id)
        try Self.check(
            store.meetings[0].segments[0].text == "森バスの価格を決めます" && store.meetings[0].corrections.isEmpty,
            "the correction is undone")
        await store.flushCheckpoints()
        let saved = try store.savedMeeting(meeting.id)
        try Self.check(
            saved.notes?.content.summary[0].edited == true && saved.notes?.dismissed?.count == 1,
            "edits are saved with the meeting")
        store.change(meeting.id) { $0.capture = .recording }
        try Self.check(!store.canEditMinutes(store.meetings[0]), "minutes are not edited while the AI writes them")
        store.toggleFolded("議論の経緯")
        let folded = store.foldedSections
        store.toggleFolded("議論の経緯")
        try Self.check(folded == ["議論の経緯"] && store.foldedSections.isEmpty, "a section folds away and opens again")
    }
    @MainActor func testActionOwnersAndDeadlinesArePicked() throws {
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            DueDate.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 13)) ?? Date()
        }
        func start(_ y: Int, _ m: Int, _ d: Int) -> Date { DueDate.calendar.startOfDay(for: day(y, m, d)) }
        let tuesday = day(2026, 10, 6)
        try Self.check(
            DueDate.parse("10月10日", from: tuesday) == start(2026, 10, 10)
                && DueDate.parse("１０/１０までに", from: tuesday) == start(2026, 10, 10)
                && DueDate.parse("金曜", from: tuesday) == start(2026, 10, 9)
                && DueDate.parse("来週水曜日", from: tuesday) == start(2026, 10, 14)
                && DueDate.parse("明日", from: tuesday) == start(2026, 10, 7)
                && DueDate.parse("2027年1月5日", from: tuesday) == start(2027, 1, 5)
                && DueDate.parse("1月10日", from: day(2026, 12, 20)) == start(2027, 1, 10)
                && DueDate.parse("11月", from: tuesday) == nil && DueDate.parse("2月30日", from: tuesday) == nil,
            "a said deadline is read as a day counted from the meeting, and one that names no day is left alone")
        let written = DueDate.text(start(2026, 10, 10), from: tuesday)
        try Self.check(
            written == "10月10日（土）" && DueDate.parse(written, from: tuesday) == start(2026, 10, 10)
                && DueDate.text(start(2027, 1, 5), from: tuesday) == "2027年1月5日（火）",
            "a picked day is written like the minutes' dates and reads back the same: \(written)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        func meeting(_ title: String, _ date: Date, _ owners: [String?]) -> Meeting {
            var meeting = Meeting(title: title)
            meeting.date = date
            meeting.capture = .stopped
            meeting.segments = [Segment(id: "a", time: 0, source: "マイク", text: "佐藤さんの件")]
            var notes = MinutesState()
            notes.content.actions = owners.enumerated().map {
                NoteItem(id: "x\($0)", text: "作業\($0)", owner: $1, evidence: ["a"])
            }
            meeting.notes = notes
            return meeting
        }
        let older = meeting("前回", day(2026, 10, 1), ["佐藤", "鈴木", "佐藤"])
        let newer = meeting("今回", day(2026, 10, 6), ["佐藤さん", nil, "田中"])
        store.meetings = [older, newer]
        try Self.check(
            store.knownOwners == ["佐藤さん", "田中", "鈴木"],
            "everyone named as an owner is listed once as last written, most often first, then most recent: \(store.knownOwners)"
        )
        store.updateNoteItem(newer.id, part: .actions, id: "x0", offersCorrection: false) { $0.owner = "鈴木" }
        try Self.check(
            store.meetings[1].notes?.content.actions[0].owner == "鈴木" && store.correctionOffer == nil,
            "picking someone else from the list does not offer to change the name across the meeting")
    }
    @MainActor func testEditingTheTranscriptByHand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meeting = Meeting(title: "定例")
        meeting.capture = .recording
        meeting.segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "森バスの価格を決めます"),
            Segment(id: "b", time: 10, source: "Mac音声", text: "森バスは来月リリースです"),
            Segment(id: "c", time: 20, source: "Mac音声", text: "Hallo zusammen."),
        ]
        var notes = MinutesState()
        notes.content.summary = [NoteItem(id: "s1", text: "森バス：価格を決める", evidence: ["a"])]
        meeting.notes = notes
        store.meetings = [meeting]
        try Self.check(store.canEditTranscript(store.meetings[0]), "the transcript can be corrected while recording")
        store.updateSegment(meeting.id, id: "a", text: " モリバスの価格を決めます ")
        let offer = try Self.require(store.correctionOffer, "an offer to fix the word elsewhere")
        try Self.check(
            store.meetings[0].segments[0].text == "モリバスの価格を決めます" && store.meetings[0].segments[0].edited == true
                && offer.inTranscript && offer.count == 2,
            "a corrected line is marked, and the word is offered for fixing in the other line and the summary")
        store.updateSegment(meeting.id, id: "b", text: "   ")
        store.removeSegment(meeting.id, id: "c")
        try Self.check(
            store.meetings[0].segments.map(\.text) == ["モリバスの価格を決めます", "森バスは来月リリースです"],
            "a blank edit is ignored, and an invented line can be deleted")
        await store.flushCheckpoints()
        let saved = try store.savedMeeting(meeting.id)
        let old = try JSONDecoder().decode(
            Segment.self, from: Data(#"{"id":"x","time":1,"source":"マイク","text":"旧"}"#.utf8))
        try Self.check(
            saved.segments[0].edited == true && saved.segments[1].edited == nil && old.edited == nil,
            "the mark is saved, and older lines read without it")
    }
}
