import Foundation

extension ProcessingTests {
    func testSearchFindsEveryKeywordAnywhereInAMeeting() throws {
        var meeting = Meeting(title: "週次プロダクト定例")
        meeting.tags = ["Sales"]
        var notes = MinutesState()
        notes.content.actions = [
            NoteItem(id: "a1", text: "FAQを更新する", owner: "佐藤さん", due: "10月10日", evidence: ["s2"])
        ]
        notes.content.decisions = [
            NoteItem(id: "d1", text: "書き出しまでを範囲にする", evidence: ["s1"], reason: "話者分離は精度の検証が済んでいない")
        ]
        meeting.notes = notes
        meeting.segments = [
            Segment(id: "s1", time: 96, source: "Mac音声", text: "では書き出しまでを今回の範囲にします。"),
            Segment(
                id: "s2", time: 214, source: "マイク",
                text: "えーと、先週も少し話しましたけれども、ＦＡＱは佐藤さんにお願いして、10月10日までに更新してもらいます。"),
        ]

        try Self.check(
            MeetingSearch.terms(" 佐藤\u{3000}faq  佐藤 ") == ["佐藤", "faq"],
            "half-width and full-width spaces separate keywords, and repeats are dropped")
        try Self.check(MeetingSearch.terms("  \u{3000} ").isEmpty, "spaces alone are no search")

        let action = try Self.require(MeetingSearch.search(meeting, terms: ["faq"]), "a minutes item matches")
        try Self.check(
            action.place == .minutes && action.snippet == "FAQを更新する" && action.segmentID == nil,
            "minutes come before the transcript, and case does not matter: \(action)")
        let spoken = try Self.require(
            MeetingSearch.search(meeting, terms: ["お願い", "SALES", "精度"]), "keywords spread over a meeting")
        try Self.check(
            spoken.place == .transcript && spoken.segmentID == "s2" && spoken.time == 214,
            "a transcript match points at its utterance: \(spoken)")
        try Self.check(
            spoken.snippet.hasPrefix("…") && spoken.snippet.contains("お願い"),
            "the passage is cut around the keyword: \(spoken.snippet)")
        try Self.check(
            MeetingSearch.search(meeting, terms: ["ＦＡＱ"])?.snippet == "FAQを更新する",
            "full-width and half-width letters match each other")
        try Self.check(
            MeetingSearch.search(meeting, terms: ["定例"])?.place == .title
                && MeetingSearch.search(meeting, terms: ["sales"])?.place == .tags,
            "the title and tags are searched")
        try Self.check(
            MeetingSearch.search(meeting, terms: ["FAQ", "存在しない"]) == nil
                && MeetingSearch.search(meeting, terms: []) == nil,
            "every keyword must appear somewhere in the meeting")
        let passages = try Self.require(
            MeetingSearch.passages(meeting, terms: ["佐藤", "お願い"], limit: 5), "passages for two keywords")
        try Self.check(
            passages.first?.segmentID == "s2" && passages.first?.source == "マイク"
                && passages.map(\.place) == [.transcript, .minutes],
            "the passage with more keywords comes before an earlier one with fewer: \(passages)")
        try Self.check(
            MeetingSearch.passages(meeting, terms: ["佐藤", "存在しない"], limit: 5) == nil,
            "no passages unless the meeting has every keyword")
        let marked = MeetingSearch.ranges(of: ["faq", "と"], in: "FAQとfaqとＦＡＱ").count
        try Self.check(marked == 5, "every occurrence of every keyword is marked: \(marked)")
    }
    @MainActor func testSearchNarrowsTheListWithTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meetings = ["週次定例", "A社ヒアリング", "採用面談"].map { Meeting(title: $0) }
        meetings[0].segments = [Segment(time: 3, source: "マイク", text: "予算の話をします")]
        meetings[1].segments = [Segment(time: 5, source: "Mac音声", text: "予算は来月決まります")]
        meetings[1].tags = ["顧客"]
        store.meetings = meetings
        store.selected = meetings[2].id

        store.searchText = "予算"
        try Self.check(store.visibleMeetings.count == 3, "results wait for the search to run")
        store.refreshSearch()
        try Self.check(
            store.visibleMeetings.map(\.id) == [meetings[0].id, meetings[1].id] && store.selected == meetings[0].id,
            "the list shows meetings with the keyword and selects the first one")
        store.toggleTagFilter("顧客")
        try Self.check(store.visibleMeetings.map(\.id) == [meetings[1].id], "a search and a tag filter combine")
        store.clearTagFilter()

        store.change(meetings[2].id) { $0.segments.append(Segment(time: 9, source: "マイク", text: "予算の確認")) }
        store.refreshSearch()
        try Self.check(
            store.visibleMeetings.count == 3 && store.selected == meetings[1].id,
            "new speech joins the results without moving the selection")
        store.searchText = " "
        store.refreshSearch()
        try Self.check(
            store.searchHits.isEmpty && store.searchedTerms.isEmpty && store.visibleMeetings.count == 3,
            "clearing the search shows every meeting")
    }
}
