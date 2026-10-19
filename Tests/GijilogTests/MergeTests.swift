import Foundation

extension ProcessingTests {
    // Two Macs changed one meeting from the same version: what only one changed comes through, what both changed
    // differently keeps this Mac's and is listed, and the other's version of a listed place can be taken.
    func testMeetingsChangedOnTwoMacsMerge() throws {
        var base = Meeting(title: "定例")
        base.tags = ["定例", "開発"]
        base.segments = [
            Segment(id: "s1", time: 0, source: "マイク", text: "資料を確認します"),
            Segment(id: "s2", time: 5, source: "マイク", text: "範囲を決めます"),
            Segment(id: "s3", time: 9, source: "マイク", text: "次回に回します"),
        ]
        var notes = MinutesState()
        notes.content.decisions = [
            NoteItem(id: "d1", text: "書き出しまでを範囲にする", evidence: ["s2"]),
            NoteItem(id: "d2", text: "来週に決める", evidence: ["s3"]),
            NoteItem(id: "d3", text: "資料を共有する", evidence: ["s1"]),
        ]
        base.notes = notes
        base.agenda = [AgendaItem(title: "範囲")]
        base.jobs = [TranscriptionJob(id: "j", filename: "chunks/a.caf", offset: 0, source: "マイク")]

        var ours = base  // This Mac: a tag added, a line and a decision corrected, a decision deleted.
        ours.tags.append("重要")
        ours.segments[0].text = "資料を確かめます"
        ours.notes?.content.decisions[0].text = "書き出しまでを今回の範囲にする"
        ours.notes?.content.decisions.remove(at: 1)
        var theirs = base  // The other Mac: the title, a tag removed, another line, the same decision, the agenda.
        theirs.title = "週次定例"
        theirs.tags.removeAll { $0 == "開発" }
        theirs.segments[1].text = "範囲を決めましょう"
        theirs.segments.remove(at: 2)
        theirs.notes?.content.decisions[0].text = "書き出しまでを範囲とする"
        theirs.notes?.content.decisions.append(NoteItem(id: "d4", text: "FAQを更新する", evidence: ["s1"]))
        theirs.notes?.content.decisions[2].text = "資料を全員に共有する"
        theirs.agenda[0].title = "範囲の確認"
        theirs.jobs[0].state = .completed

        let result = MeetingMerge.merge(base: base, ours: ours, theirs: theirs, oursProcesses: false)
        let merged = result.meeting
        let decisions = merged.notes?.content.decisions ?? []
        try Self.check(
            merged.title == "週次定例" && merged.tags == ["定例", "重要"]
                && merged.segments.map(\.text) == ["資料を確かめます", "範囲を決めましょう"]
                && decisions.map(\.id) == ["d1", "d3", "d4"] && decisions[0].text == "書き出しまでを今回の範囲にする"
                && decisions[1].text == "資料を全員に共有する" && merged.agenda.map(\.title) == ["範囲の確認"]
                && merged.jobs.map(\.state) == [.completed],
            "what only one Mac changed comes through, deletions included: \(merged.title) \(merged.tags) \(decisions.map(\.id))"
        )
        try Self.check(
            result.spots.map(\.id) == ["note:decisions:d1"] && result.spots[0].kept == "書き出しまでを今回の範囲にする"
                && result.spots[0].other == "書き出しまでを範囲とする" && result.spots[0].label.hasPrefix("決定事項"),
            "a decision both Macs corrected differently keeps this Mac's and is listed: \(result.spots.map(\.id))")
        var settled = merged
        MeetingMerge.take("note:decisions:d1", from: theirs, into: &settled)
        try Self.check(
            settled.notes?.content.decisions.first?.text == "書き出しまでを範囲とする",
            "the other Mac's version of a listed place can be taken")

        // Deleted on one Mac and corrected on the other: the correction stays, and is listed.
        var deletedHere = base
        deletedHere.segments.removeFirst()
        var correctedThere = base
        correctedThere.segments[0].text = "資料を先に確認します"
        let kept = MeetingMerge.merge(base: base, ours: deletedHere, theirs: correctedThere, oursProcesses: true)
        try Self.check(
            kept.meeting.segments.first?.text == "資料を先に確認します" && kept.spots.map(\.id) == ["segment:s1"]
                && kept.spots.first?.kept == "" && kept.meeting.jobs == base.jobs,
            "a line deleted on one Mac and corrected on the other is kept and listed")
    }
    // On a Mac that keeps a history of versions, a meeting changed here and on another Mac at once is merged from
    // the version both had, and a place both changed differently is left to settle.
    @MainActor func testStoreMergesFromTheVersionBothHad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let save = root.appendingPathComponent("save")
        let store = Store(root: save, loadSettings: false, copies: root.appendingPathComponent("copies"))
        var meeting = Meeting(title: "定例")
        meeting.folderName = "both"
        meeting.capture = .stopped
        meeting.segments = [Segment(id: "s1", time: 0, source: "マイク", text: "資料を確認します")]
        store.meetings = [meeting]
        try await store.checkpoint(meeting.id)
        let file = save.appendingPathComponent("both/meeting.json")
        let base = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        var later = Date().addingTimeInterval(5)
        func saveThere(_ change: (inout Meeting) -> Void) throws {
            var other = base
            change(&other)
            other.revision += 1
            other.saveCounts = SaveCounts.of(base).adding("another Mac")
            other.savedOn = "別の Mac"
            try JSONEncoder().encode(other).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
            later.addTimeInterval(5)
        }
        // Here a line is corrected; there the title and a tag change, from the same version.
        store.change(meeting.id) { $0.segments[0].text = "資料を確かめます" }
        try await store.checkpoint(meeting.id)
        try saveThere {
            $0.title = "週次定例"
            $0.tags = ["定例"]
        }
        await store.reloadChangedMeetings()
        await store.flushCheckpoints()
        let aside = save.appendingPathComponent("both/" + MeetingRepository.asideName)
        let merged = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        try Self.check(
            merged.title == "週次定例" && merged.tags == ["定例"] && merged.segments[0].text == "資料を確かめます"
                && merged.conflict == nil && !FileManager.default.fileExists(atPath: aside.path)
                && SaveCounts.of(merged).includes(SaveCounts.of(base).adding("another Mac")),
            "changes from both Macs are merged into one version, saved past both: \(merged.title)")

        // Both change the title, differently: this Mac's shows, and the other's can be taken.
        let both = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        store.change(meeting.id) { $0.title = "週次の定例会" }
        try await store.checkpoint(meeting.id)
        var other = both
        other.title = "定例ミーティング"
        other.revision += 1
        other.saveCounts = SaveCounts.of(both).adding("another Mac")
        other.savedOn = "別の Mac"
        try JSONEncoder().encode(other).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
        await store.reloadChangedMeetings()
        await store.flushCheckpoints()
        let spots = store.meetings[0].conflict?.spots ?? []
        try Self.check(
            store.meetings[0].title == "週次の定例会" && spots.map(\.id) == ["title"] && spots[0].other == "定例ミーティング"
                && FileManager.default.fileExists(atPath: aside.path),
            "a title changed differently on both Macs keeps this Mac's and is left to settle: \(spots.map(\.id))")
        await store.settleSpot(meeting.id, spot: "title", takeOther: true)
        await store.flushCheckpoints()
        let settled = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        try Self.check(
            settled.title == "定例ミーティング" && settled.conflict == nil
                && !FileManager.default.fileExists(atPath: aside.path),
            "settling the last place takes the other Mac's title and lets the version aside go")
    }
}
