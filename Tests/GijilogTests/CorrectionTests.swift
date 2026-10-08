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
        // An item is edited because the user wanted it worded differently, so the AI writing the same item again
        // almost never matches the edit word for word. It cites the same lines, which is how it is recognised.
        let reworded = try MinutesEngine.rewrite(
            state,
            delta: NotesDelta(decisions: [
                NoteItem(id: "", text: "B案に決定した", evidence: ["s1"]),
                NoteItem(id: "", text: "C案も検討する", evidence: ["s2"]),
            ]), transcript: [first, second])
        try Self.check(
            reworded.content.decisions.map(\.text) == ["B案にする（手直し）", "C案も検討する"],
            "the final review does not add the AI's own wording of an edited item: \(reworded.content.decisions.map(\.text))"
        )
        let relive = MinutesEngine.merge(
            state, delta: NotesDelta(decisions: [NoteItem(id: "", text: "B案に決めた", evidence: ["s1", "s2"])]),
            batch: [second], segments: [first, second])
        try Self.check(
            relive.content.decisions.map(\.text) == ["B案にする（手直し）"],
            "nor does a later part of a long meeting: \(relive.content.decisions.map(\.text))")
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
        try Self.check(
            hints.terms == ["モリバス", "ギジログ"], "transcription is told the corrected spellings, this meeting's first")
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
        var shared = NoteItem(id: "x9", text: "見積もりを作る", evidence: [])
        shared.owners = ["塚原さん", "小堀さん"]
        try Self.check(
            shared.owner == "塚原さん、小堀さん" && NoteItem.names("塚原さん, 小堀さん、塚原さん") == ["塚原さん", "小堀さん"]
                && NoteItem.toggling("小堀", in: shared.owner) == "塚原さん"
                && NoteItem.toggling("市川さん", in: shared.owner) == "塚原さん、小堀さん、市川さん"
                && NoteItem.toggling("塚原さん", in: "塚原さん") == nil,
            "an action can have several owners, each added or taken off on its own")
        let said = ["s": Segment(id: "s", time: 0, source: "マイク", text: "見積もりは塚原さんと小堀さんでお願いします")]
        let checked = MinutesEngine.grounded(
            NoteItem(id: "", text: "見積もりを作る", owner: "塚原さん、小堀さん、誰か、鈴木さん", evidence: ["s"]), known: said)
        try Self.check(
            checked.owner == "塚原さん、小堀さん", "each owner the speech names stays; an invented or vague one goes")
        store.meetings[0].notes?.content.actions.append(shared)
        try Self.check(
            store.knownOwners.contains("塚原さん") && store.knownOwners.contains("小堀さん")
                && !store.knownOwners.contains("塚原さん、小堀さん"),
            "several owners are listed as separate people")
        store.meetings[0].notes?.content.actions.removeLast()
        store.updateNoteItem(newer.id, part: .actions, id: "x0", offersCorrection: false) { $0.owner = "鈴木" }
        try Self.check(
            store.meetings[1].notes?.content.actions[0].owner == "鈴木" && store.correctionOffer == nil,
            "picking someone else from the list does not offer to change the name across the meeting")
    }
    // A line corrected while a live update is being written is not in that update: the update must not clear its
    // mark, or the items it fed would read as checked.
    @MainActor func testCorrectionsDuringAnUpdateStayMarked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        let gate = Gate()
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            summarize: { state, segments, _, _ in
                await gate.wait()
                let batch = MinutesEngine.batch(segments, state: state)
                return MinutesEngine.merge(
                    state, delta: MinutesEngine.extract(batch), batch: batch, segments: segments)
            })
        var meeting = Meeting(title: "定例")
        meeting.settings = SessionSettings()
        meeting.capture = .recording
        meeting.segments = [
            Segment(id: "a", time: 0, source: "マイク", text: "新しい案を採用することにします"),
            Segment(id: "b", time: 30, source: "マイク", text: "次は日程の話です"),
        ]
        var notes = MinutesState()
        notes.content.decisions = [NoteItem(id: "d1", text: "新しい案を採用する", evidence: ["a"])]
        notes.appliedSegmentIDs = ["a"]
        meeting.notes = notes
        store.meetings = [meeting]
        store.pipeline.resume(meeting.id, key: "")
        store.pipeline.requestSummary(meeting.id, force: true)
        for _ in 0..<50 where !store.pipeline.isSummarizing(meeting.id) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try Self.check(store.pipeline.isSummarizing(meeting.id), "an update is being written")
        store.updateSegment(meeting.id, id: "a", text: "新しい案は採用しないことにします")
        await gate.release()
        for _ in 0..<200 where store.pipeline.isSummarizing(meeting.id) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = try Self.require(store.meetings[0].notes, "notes")
        try Self.check(
            after.appliedSegmentIDs.contains("b") && after.revisedSegmentIDs == ["a"]
                && after.itemsCitingRevisedLines.contains("d1"),
            "the update arrived, and the decision citing the corrected line is still to check: \(String(describing: after.revisedSegmentIDs))"
        )

        // Before the first minutes there is nothing to mark: a correction waits on the meeting, and the first minutes
        // take it when they were written from the line as it was. One made before they were asked for is in them.
        let firstGate = Gate()
        let first = Store(root: root.appendingPathComponent("first"), loadSettings: false)
        first.pipeline = ProcessingPipeline(
            store: first, review: MinutesEngine.stubReview,
            summarize: { state, segments, _, _ in
                await firstGate.wait()
                var written = state
                written.content.decisions = [NoteItem(id: "d1", text: "新しい案を採用する", evidence: ["a"])]
                written.content.actions = [NoteItem(id: "x1", text: "日程を決める", evidence: ["b"])]
                written.appliedSegmentIDs = Set(segments.map(\.id))
                return written
            })
        var fresh = meeting
        fresh.notes = nil
        first.meetings = [fresh]
        first.updateSegment(fresh.id, id: "b", text: "次は日程を決めます")
        first.pipeline.resume(fresh.id, key: "")
        first.pipeline.requestSummary(fresh.id, force: true)
        for _ in 0..<50 where !first.pipeline.isSummarizing(fresh.id) { try await Task.sleep(nanoseconds: 10_000_000) }
        first.updateSegment(fresh.id, id: "a", text: "新しい案は採用しないことにします")
        let waiting = first.meetings[0].revisedBeforeMinutes
        await firstGate.release()
        for _ in 0..<200 where first.pipeline.isSummarizing(fresh.id) { try await Task.sleep(nanoseconds: 10_000_000) }
        let firstNotes = try Self.require(first.meetings[0].notes, "the first minutes")
        try Self.check(
            waiting == ["a", "b"] && firstNotes.itemsCitingRevisedLines == ["d1"]
                && first.meetings[0].revisedBeforeMinutes == nil,
            "a line corrected while the first minutes were written marks the decision citing it; one corrected before does not: \(firstNotes.itemsCitingRevisedLines)"
        )
        store.recording = false
    }
    // A word fixed once is learned: later meetings get it fixed by themselves, transcription is told its right
    // spelling and the people named as owners, and the fix can be undone in one meeting.
    @MainActor func testMisheardWordsAreLearnedFromFixes() async throws {
        try Self.check(
            LearnedWords.parse("森バス、もりばす → モリバス\nおかしな行\n高山 → 高松") == [
                LearnedWord(variants: ["森バス", "もりばす"], to: "モリバス"), LearnedWord(variants: ["高山"], to: "高松"),
            ]
                && LearnedWords.learning(["モリ バス", "森バス"], to: "モリバス", in: "森バス → モリバス")
                    == "森バス、モリ バス → モリバス",
            "the list reads one right spelling a line, and a fix joins its line")
        // The list keeps the words fixed latest: a fix renews its word, and past the limit the one fixed longest ago
        // is forgotten. A word keeps its latest misheard spellings.
        let full = (1...LearnedWords.limit).reduce("") { LearnedWords.learning(["誤\($1)"], to: "正\($1)", in: $0) }
        let renewed = LearnedWords.learning(["誤1b"], to: "正1", in: full)
        let over = LearnedWords.parse(LearnedWords.learning(["誤X"], to: "正X", in: renewed))
        let spellings = LearnedWords.parse((1...15).reduce("") { LearnedWords.learning(["誤\($1)"], to: "正", in: $0) })
        try Self.check(
            over.count == LearnedWords.limit && over.first?.to == "正3" && over.dropLast().last?.to == "正1"
                && over.last?.to == "正X" && spellings.first?.variants == (6...15).map { "誤\($0)" },
            "the list keeps \(LearnedWords.limit) words, forgetting the one fixed longest ago: \(over.prefix(2))")
        var first = Meeting(title: "前々回")
        first.date = Date(timeIntervalSince1970: 0)
        first.corrections = [TermCorrection(variants: ["高山"], to: "高松")]
        var second = Meeting(title: "前回")
        second.corrections = [
            TermCorrection(variants: ["IQ"], to: "AIQ"), TermCorrection(variants: ["森バス"], to: "モリバス", learned: true),
        ]
        try Self.check(
            LearnedWords.seed(from: [second, first]) == "高山 → 高松\nIQ → AIQ",
            "the fixes already made by hand start the list, oldest first, without learned ones")

        let (root, audio) = try fixture(seconds: 12, amplitude: 0.25)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("save"), loadSettings: false)
        store.key = "TEST"
        store.learnedWords = "森バス → モリバス"
        var earlier = Meeting(title: "前回")
        earlier.capture = .stopped
        var notes = MinutesState()
        notes.content.actions = [NoteItem(id: "x", text: "資料を作る", owner: "佐藤さん", evidence: [])]
        earlier.notes = notes
        store.meetings = [earlier]
        final class Told: @unchecked Sendable { var terms: [String] = [] }
        let told = Told()
        store.pipeline = ProcessingPipeline(
            store: store, review: MinutesEngine.stubReview,
            recognize: { _, offset, source, _, hints in
                told.terms = hints.terms
                return [Segment(time: offset, source: source, text: "森バスの資料を確認します")]
            },
            summarize: MinutesEngine.stubSummary)
        await store.importRecording(from: audio)
        try await store.waitUntilIdle()
        let meeting = try Self.require(store.meetings.first { $0.title != "前回" }, "imported meeting")
        let learned = try Self.require(meeting.corrections.first, "the learned fix")
        try Self.check(
            meeting.segments.allSatisfy { $0.text == "モリバスの資料を確認します" } && learned.learned == true
                && learned.to == "モリバス" && learned.changes.count == meeting.segments.count
                && told.terms.contains("モリバス") && told.terms.contains("佐藤"),
            "a learned word is fixed in new speech, and transcription is told it and the owners: \(told.terms) "
                + "\(meeting.segments.map(\.text)) \(meeting.corrections.map { ($0.to, $0.learned, $0.changes.count) })"
        )
        store.undoCorrection(meeting.id, learned.id)
        let undone = try Self.require(store.meetings.first { $0.id == meeting.id }, "undone meeting")
        try Self.check(
            undone.segments.allSatisfy { $0.text == "森バスの資料を確認します" } && undone.corrections.isEmpty
                && undone.ignoredLearned == ["モリバス"]
                && !store.hintVocabulary(for: undone).contains("モリバス")
                && store.learned.map(\.to) == ["モリバス"],
            "undone in one meeting, it stays undone there and is still learned for the others")
        store.applyCorrection(
            meeting.id, occurrences: undone.occurrences(of: "資料", correctedTo: "試料"), to: "試料", addToVocabulary: false)
        try Self.check(
            store.learned.contains(LearnedWord(variants: ["資料"], to: "試料")), "a new fix is learned")
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
        let revised = try Self.require(store.meetings[0].notes, "notes")
        try Self.check(
            revised.revisedSegmentIDs == ["a", "c"] && revised.itemsCitingRevisedLines == ["s1"],
            "a corrected or deleted line marks the minutes citing it for checking")
        let rewritten = try MinutesEngine.rewrite(
            revised, delta: NotesDelta(summary: [NoteItem(id: "", text: "モリバス：価格を決める", evidence: ["a"])]),
            transcript: store.meetings[0].segments)
        try Self.check(
            rewritten.revisedSegmentIDs == nil && rewritten.itemsCitingRevisedLines.isEmpty,
            "minutes written again from the corrected transcript need no checking")
        // An item edited by hand is kept as it was by the rewrite, so it still needs checking; the items written
        // again from the corrected lines do not.
        var withHandEdit = revised
        withHandEdit.content.decisions = [NoteItem(id: "d1", text: "森バスの価格は来週決める", evidence: ["a"], edited: true)]
        let keptAsEdited = try MinutesEngine.rewrite(
            withHandEdit, delta: NotesDelta(summary: [NoteItem(id: "", text: "モリバス：価格を決める", evidence: ["a"])]),
            transcript: store.meetings[0].segments)
        try Self.check(
            keptAsEdited.itemsCitingRevisedLines == ["d1"] && keptAsEdited.revisedSegmentIDs == nil,
            "an item edited by hand and kept by the rewrite still needs checking: \(keptAsEdited.itemsCitingRevisedLines)"
        )
        let again = try MinutesEngine.rewrite(
            keptAsEdited, delta: NotesDelta(summary: [NoteItem(id: "", text: "モリバス：価格を決める", evidence: ["a"])]),
            transcript: store.meetings[0].segments)
        try Self.check(again.itemsCitingRevisedLines == ["d1"], "until someone checks it, through another rewrite")
        // Processing the whole recording again writes a new transcript with new line IDs: an edited item still to
        // check carries over marked by its own ID, through the rewrite after it, and the rest is written again.
        var beforeReprocess = withHandEdit
        beforeReprocess.content.actions = [NoteItem(id: "x1", text: "見積もりを出す", evidence: ["b"], edited: true)]
        let carried = try Self.require(MinutesState.keptForReprocessing(beforeReprocess), "what carries over")
        let renumbered = [Segment(id: "n1", time: 0, source: "マイク", text: "モリバスの価格を決めます")]
        let reprocessed = try MinutesEngine.rewrite(
            carried, delta: NotesDelta(summary: [NoteItem(id: "", text: "モリバス：価格を決める", evidence: ["n1"])]),
            transcript: renumbered)
        try Self.check(
            carried.content.summary.isEmpty && carried.content.decisions.map(\.id) == ["d1"]
                && carried.itemsCitingRevisedLines == ["d1"] && reprocessed.itemsCitingRevisedLines == ["d1"]
                && MinutesState.keptForReprocessing(MinutesState()) == nil,
            "an edited item still to check stays so through processing the recording again: \(carried.itemsCitingRevisedLines)"
        )
        // Marks made while minutes were being written join them; marks cleared meanwhile stay cleared.
        var written = MinutesState()
        written.revisedSegmentIDs = ["old"]
        var before = MinutesState()
        before.revisedSegmentIDs = ["old"]
        var now = MinutesState()
        now.revisedSegmentIDs = ["new"]
        written.keepMarks(madeSince: before, now: now)
        try Self.check(
            written.revisedSegmentIDs == ["new"],
            "a line corrected meanwhile stays marked, and one kept as it is meanwhile does not come back")
        store.keepMinutesDespiteRevisions(meeting.id)
        try Self.check(
            store.meetings[0].notes?.itemsCitingRevisedLines.isEmpty == true, "the minutes can be kept as they are")
        await store.flushCheckpoints()
        let saved = try store.savedMeeting(meeting.id)
        let old = try JSONDecoder().decode(
            Segment.self, from: Data(#"{"id":"x","time":1,"source":"マイク","text":"旧"}"#.utf8))
        try Self.check(
            saved.segments[0].edited == true && saved.segments[1].edited == nil && old.edited == nil,
            "the mark is saved, and older lines read without it")
    }
}
