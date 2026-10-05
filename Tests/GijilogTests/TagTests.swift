import Foundation

extension ProcessingTests {
    func testTagsAreNormalizedAndDeduplicated() throws {
        let typed = MeetingTags.parse("#定例、 Sales,sales ,ｓａｌｅｓ\n  ,  ＃  採用   面接 ")
        try Self.check(
            typed == ["定例", "Sales", "sales", "ｓａｌｅｓ", "採用 面接"],
            "commas, Japanese commas and line breaks separate tags; # and extra spaces are dropped: \(typed)")
        let merged = MeetingTags.adding(typed, to: ["SALES"])
        try Self.check(
            merged == ["SALES", "定例", "採用 面接"],
            "tags differing only in case or width are one tag, and the first spelling stays: \(merged)")
        let counts = [7, 9999, 12345, 1_234_567].map(shortCount)
        try Self.check(counts == ["7", "9999", "1.2万", "123万"], "chip counts stay short: \(counts)")
        let long = try Self.require(MeetingTags.normalize(String(repeating: "長", count: 60)), "long tag")
        try Self.check(long.count == MeetingTags.maxLength, "a tag is cut to \(MeetingTags.maxLength) characters")
        try Self.check(MeetingTags.parse(" , 、#\n").isEmpty, "separators and # alone make no tag")
        let legacy = try JSONDecoder().decode(
            Meeting.self, from: try JSONEncoder().encode(Meeting(title: "旧")).removingKey("tags"))
        try Self.check(legacy.tags.isEmpty, "meetings saved before tags load with none")
    }
    @MainActor func testTagsFilterTheListAndAreSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meetings = ["週次定例", "A社ヒアリング", "採用面談"].map { Meeting(title: $0) }
        for i in meetings.indices {
            meetings[i].capture = .stopped
            meetings[i].status = "完了"
        }
        meetings[0].segments = [Segment(id: "s1", time: 3, source: "マイク", text: "定例を始めます")]  // 議事録.md needs content.
        store.meetings = meetings
        store.selected = meetings[1].id
        store.addTags("定例, Sales", to: meetings[0].id)
        store.addTags("sales、顧客", to: meetings[1].id)
        store.addTags("採用", to: meetings[2].id)
        try Self.check(
            store.meetings[1].tags == ["Sales", "顧客"], "a tag already in use keeps its spelling on other meetings")
        try Self.check(
            store.allTags.map(\.name) == ["Sales", "定例", "顧客", "採用"] && store.allTags[0].count == 2,
            "tags are listed most used first: \(store.allTags)")

        store.toggleTagFilter("定例")
        try Self.check(
            store.visibleMeetings.map(\.id) == [meetings[0].id] && store.selected == meetings[0].id,
            "the list narrows to the tag and the selection follows what is shown")
        store.toggleTagFilter("SALES")
        try Self.check(store.visibleMeetings.map(\.id) == [meetings[0].id], "every selected tag must match")
        store.toggleTagFilter("定例")
        try Self.check(
            Set(store.visibleMeetings.map(\.id)) == [meetings[0].id, meetings[1].id]
                && store.selected == meetings[0].id,
            "turning a tag off widens the list without moving a selection it still shows")
        store.removeTag("sales", from: meetings[0].id)
        store.removeTag("Sales", from: meetings[1].id)
        try Self.check(
            store.tagFilter.isEmpty && store.visibleMeetings.count == 3,
            "a tag no meeting has any more stops narrowing the list")

        await store.flushCheckpoints()
        let saved = try store.savedMeeting(meetings[1].id)
        try Self.check(saved.tags == ["顧客"], "tags are saved with the meeting")
        let document = try String(
            contentsOf: store.folder(meetings[0].id).appendingPathComponent(MeetingRepository.documentName),
            encoding: .utf8)
        try Self.check(
            document.hasPrefix("# 週次定例\n\nタグ: 定例\n\n## 文字起こし"),
            "議事録.md lists the tags under the title: \(document.prefix(60))")
        let folder = store.folder(meetings[0].id)
        store.renameMeeting(meetings[0].id, to: "  PRD会議\n ")
        store.renameMeeting(meetings[1].id, to: "   ")
        await store.flushCheckpoints()
        let renamed = try String(
            contentsOf: store.folder(meetings[0].id).appendingPathComponent(MeetingRepository.documentName),
            encoding: .utf8)
        try Self.check(
            store.meetings[0].title == "PRD会議" && store.meetings[1].title == "A社ヒアリング"
                && renamed.hasPrefix("# PRD会議\n") && store.folder(meetings[0].id) == folder,
            "a recorded meeting can be renamed in place, 議事録.md follows, and a blank title is ignored")
        try Self.check(
            MinutesEngine.render(MinutesState(), segments: [], title: "会議", tags: ["定例", "顧客"])
                .hasPrefix("# 会議\n\nタグ: 定例, 顧客\n\n## 要約"),
            "minutes list the tags under the title")
    }
    @MainActor func testTagsCanBeRenamedMergedAndDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        var meetings = ["週次定例", "A社ヒアリング", "採用面談"].map { Meeting(title: $0) }
        meetings[0].tags = ["定例", "営業"]
        meetings[1].tags = ["顧客", "Sales"]
        meetings[2].tags = ["採用"]
        store.meetings = meetings
        store.toggleTagFilter("営業")

        try Self.check(
            !store.renameTag("営業", to: " , ") && !store.renameTag("営業", to: "営業, 顧客"),
            "an empty name or one a comma would split is refused")
        try Self.check(store.renameTag("営業", to: "sales"), "renaming to another tag's name is allowed")
        try Self.check(
            store.meetings[0].tags == ["定例", "sales"] && store.meetings[1].tags == ["顧客", "sales"],
            "renaming onto an existing tag merges them, spelled as typed: \(store.meetings.map(\.tags))")
        try Self.check(
            store.tagFilter == ["sales"] && store.visibleMeetings.count == 2, "a filter on the renamed tag follows it")
        store.renameTag("SALES", to: "営業部")
        store.renameTag("定例", to: "定例")
        try Self.check(
            store.meetings[0].tags == ["定例", "営業部"] && store.meetings[1].tags == ["顧客", "営業部"],
            "a rename keeps each tag in its place: \(store.meetings.map(\.tags))")

        store.deleteTag("営業部")
        try Self.check(
            store.meetings.map(\.tags) == [["定例"], ["顧客"], ["採用"]] && store.meetings.count == 3,
            "deleting a tag takes it off every meeting and keeps the meetings")
        try Self.check(store.tagFilter.isEmpty, "a deleted tag stops narrowing the list")
        await store.flushCheckpoints()
        let saved = try store.savedMeeting(meetings[1].id)
        try Self.check(saved.tags == ["顧客"], "renames and deletions are saved")
    }
}

extension Data {
    fileprivate func removingKey(_ key: String) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: self) as? [String: Any] ?? [:]
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }
}
