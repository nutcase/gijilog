import Foundation

struct Segment: Codable, Identifiable, Sendable, Equatable {
    var id: String = UUID().uuidString
    var time: Double
    var source: String
    var text: String
    var edited: Bool?  // Corrected by hand.
    init(id: String = UUID().uuidString, time: Double, source: String, text: String) {
        self.id = id
        self.time = time
        self.source = source
        self.text = text
    }
    enum CodingKeys: String, CodingKey { case id, time, source, text, edited }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        source = try c.decode(String.self, forKey: .source)
        text = try c.decode(String.self, forKey: .text)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited)
        // Old meetings acquire repeatable IDs when reopened.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? stableID("\(time)|\(source)|\(text)")
    }
}
func stableID(_ text: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
}
// A planned meeting has been prepared (title, tags, agenda) but not recorded yet.
enum CaptureState: String, Codable { case planned, recording, stopped, interrupted }
enum JobState: String, Codable, Sendable { case pending, running, completed, failed }
enum ItemState: String, Codable, CaseIterable, Sendable { case open, done, cancelled }
// Transcription and minutes always use OpenAI. Older meetings may also carry "mode"/"localModel", which are ignored.
struct SessionSettings: Codable, Sendable {
    var model = "gpt-6-sol"
}
struct TranscriptionJob: Codable, Identifiable, Sendable {
    var id: String
    var filename: String
    var offset: Double
    var source: String
    var state = JobState.pending
    var attempts = 0
    var lastError: String?
    var retryAfter: Date?
}
struct NoteItem: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var text: String
    var owner: String?
    var due: String?
    var evidence: [String]
    var state = ItemState.open
    var reason: String?
    var nextStep: String?
    var changeSummary: String?
    var edited: Bool?  // Written or changed by hand: AI updates leave it as it is.
}
struct NotesDelta: Codable, Sendable {
    var summary: [NoteItem] = []
    var decisions: [NoteItem] = []
    var unresolved: [NoteItem] = []
    var actions: [NoteItem] = []
    var history: [NoteItem] {
        decisions.filter { $0.state == .cancelled } + unresolved.filter { $0.state != .open }
            + actions.filter { $0.state == .cancelled }
    }
}
struct MinutesState: Codable, Sendable {
    var content = NotesDelta()
    var appliedSegmentIDs: Set<String> = []
    var updatedAt: Date?
    var extractionOnly = false  // Notes from the former keyword-extraction mode.
    // AI items dropped because their evidence did not check out. Kept for diagnosis, not shown: the earlier
    // version of each item stays, so nothing the reader had is lost, and a count alone reads as deleted content.
    var rejectedItems: Int?
    var latestSegmentIDs: Set<String>?  // Utterances behind the most recent update, to mark what just changed.
    var reviewedSegmentIDs: Set<String>?  // Checkpointed progress through the post-meeting review.
    var finalizedAt: Date?
    var dismissed: [String]?  // Items deleted by hand, normalized, so the AI does not bring them back.
    // Passed through a live update and never saved: the agenda goes in, the topic being discussed comes out.
    var agenda: [AgendaItem] = []
    var topic: AgendaTopic?
    var corrections: [TermCorrection] = []  // The user's spellings, for the AI to follow.
    enum CodingKeys: String, CodingKey {
        case content, appliedSegmentIDs, updatedAt, extractionOnly, rejectedItems, latestSegmentIDs,
            reviewedSegmentIDs, finalizedAt, dismissed
    }
}
struct Meeting: Codable, Identifiable {
    var id = UUID()
    var title: String
    var date = Date()
    var segments: [Segment] = []
    var minutes = ""
    var status = "録音中"
    var capture = CaptureState.recording
    var settings: SessionSettings?
    var jobs: [TranscriptionJob] = []
    var notes: MinutesState?
    var finalReviewPending: Bool?  // Nil keeps older, completed meetings from making new API calls on launch.
    var captureError: String?
    var hasAudio: Bool?
    var revision: UInt64 = 0
    // The meeting's folder inside the save location. Loading sets it from the folder actually found,
    // so a folder renamed in Finder keeps working. Older meetings live in a folder named by their UUID.
    var folderName: String?
    var tags: [String] = []  // In the order they were added; see MeetingTags for spelling and duplicates.
    var agenda: [AgendaItem] = []  // Optional; a meeting without one works exactly as before.
    var corrections: [TermCorrection] = []  // Misheard words fixed across the meeting; see Corrections.swift.
    var clockStart: Date?  // Set when a recording continues the meeting: when its clock would have started.
    init(title: String) { self.title = title }
    /// When the meeting's clock reads zero: the start of the recording, or, for a meeting recorded in parts, the
    /// moment that puts the latest part right after the earlier ones.
    var recordingOrigin: Date { clockStart ?? date }
    enum CodingKeys: String, CodingKey {
        case id, title, date, segments, minutes, status, capture, settings, jobs, notes, captureError, hasAudio,
            revision, folderName, finalReviewPending, tags, agenda, corrections, clockStart
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        segments = try c.decode([Segment].self, forKey: .segments)
        minutes = try c.decode(String.self, forKey: .minutes)
        status = try c.decode(String.self, forKey: .status)
        capture =
            try c.decodeIfPresent(CaptureState.self, forKey: .capture) ?? (status == "録音中" ? .recording : .stopped)
        settings = try c.decodeIfPresent(SessionSettings.self, forKey: .settings)
        jobs = try c.decodeIfPresent([TranscriptionJob].self, forKey: .jobs) ?? []
        notes = try c.decodeIfPresent(MinutesState.self, forKey: .notes)
        finalReviewPending = try c.decodeIfPresent(Bool.self, forKey: .finalReviewPending)
        captureError = try c.decodeIfPresent(String.self, forKey: .captureError)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        agenda = try c.decodeIfPresent([AgendaItem].self, forKey: .agenda) ?? []
        corrections = try c.decodeIfPresent([TermCorrection].self, forKey: .corrections) ?? []
        clockStart = try c.decodeIfPresent(Date.self, forKey: .clockStart)
    }
}

// Tags are the user's own labels for finding meetings again. They never leave the Mac.
enum MeetingTags {
    static let maxLength = 40
    /// Splits typed or pasted text into tags. Commas (, 、 ，) and line breaks separate tags.
    static func parse(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",、，\n\r")).compactMap(normalize)
    }
    /// Trims the tag, drops leading #s (as in "#定例"), and folds runs of whitespace into one space.
    static func normalize(_ tag: String) -> String? {
        let words = tag.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let name = String(words.drop(while: { $0 == "#" || $0 == "＃" })).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : String(name.prefix(maxLength))
    }
    /// Tags that differ only in case or character width ("Sales", "sales", "ｓａｌｅｓ") are the same tag.
    static func key(_ tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
    /// Appends the tags the list does not have yet, keeping its order.
    static func adding(_ tags: [String], to list: [String]) -> [String] {
        var result = list
        var keys = Set(list.map(key))
        for tag in tags.compactMap(normalize) where keys.insert(key(tag)).inserted { result.append(tag) }
        return result
    }
    static func contains(_ list: [String], _ tag: String) -> Bool { list.contains { key($0) == key(tag) } }
}

// One topic of a meeting's agenda. Spans are when it was being discussed, in seconds from the start of the
// recording, as the minutes model judges from the transcript; a topic the meeting returns to gets another span.
struct AgendaItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var goal: String?  // What the topic should decide.
    var minutes: Int?  // Planned length.
    var spans: [AgendaSpan] = []
    enum Progress { case pending, current, done }
    var progress: Progress { spans.isEmpty ? .pending : spans.last?.end == nil ? .current : .done }
    /// Seconds discussed so far; an open span counts up to `now`.
    func spent(now: Double) -> Double { spans.reduce(0) { $0 + max(0, ($1.end ?? now) - $1.start) } }
    init(title: String, goal: String? = nil, minutes: Int? = nil) {
        self.title = title
        self.goal = goal
        self.minutes = minutes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        spans = try c.decodeIfPresent([AgendaSpan].self, forKey: .spans) ?? []
    }
}
struct AgendaSpan: Codable, Equatable, Sendable {
    var start: Double
    var end: Double?
}
// Which topic the newest speech is about, as the minutes model judged it, and when that talk began.
struct AgendaTopic: Equatable, Sendable {
    var item: UUID
    var since: Double
}
enum MeetingAgenda {
    /// One item per line of typed or pasted text (a calendar invite, a chat message). Bullets and numbering are
    /// dropped, and a trailing length such as "（10分）" or "10 min" becomes the planned minutes.
    static func parse(_ text: String) -> [AgendaItem] {
        text.components(separatedBy: .newlines).compactMap { line in
            var title = line.trimmingCharacters(in: .whitespaces)
            if let marker = title.range(of: marker, options: .regularExpression) { title.removeSubrange(marker) }
            var minutes: Int?
            if let length = title.range(of: length, options: [.regularExpression, .caseInsensitive]) {
                let digits = title[length].applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? ""
                minutes = Int(digits.filter(\.isNumber))
                title.removeSubrange(length)
            }
            title = title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return AgendaItem(title: String(title.prefix(200)), minutes: minutes)
        }
    }
    private static let marker = #"^(?:[-*+•・●○◯□■▪◦‣]|[0-9０-９]{1,2}[.．)）]|[(（][0-9０-９]{1,2}[)）]|[①-⑳])\s*"#
    private static let length = #"[\s　]*[(（]?\s*[0-9０-９]{1,3}\s*(?:分|min|mins|minutes)\s*[)）]?$"#
    /// A switch back within this many seconds undoes the switch, so a brief misjudgment leaves no trace.
    static let undoWindow: Double = 30
    static func currentIndex(_ items: [AgendaItem]) -> Int? { items.firstIndex { $0.progress == .current } }
    /// The meeting moves to `index` at `time`: the topic under way stops there and the chosen one starts.
    /// Going straight back to the topic just left reopens it.
    static func switchTo(_ items: [AgendaItem], index: Int, at time: Double) -> [AgendaItem] {
        guard items.indices.contains(index) else { return items }
        var items = items
        let current = currentIndex(items)
        guard current != index else { return items }
        if let current, let open = items[current].spans.last {
            let time = max(time, open.start)
            if time - open.start < undoWindow, items[index].spans.last?.end == open.start {
                items[current].spans.removeLast()
                items[index].spans[items[index].spans.count - 1].end = nil
                return items
            }
            items[current].spans[items[current].spans.count - 1].end = time
            items[index].spans.append(AgendaSpan(start: time))
        } else {
            items[index].spans.append(AgendaSpan(start: time))
        }
        return items
    }
    /// The minutes model judged that the newest speech is about `topic`.
    static func follow(_ items: [AgendaItem], _ topic: AgendaTopic) -> [AgendaItem] {
        guard let index = items.firstIndex(where: { $0.id == topic.item }) else { return items }
        return switchTo(items, index: index, at: topic.since)
    }
    /// Recording has stopped: the topic being discussed ends there.
    static func finish(_ items: [AgendaItem], at time: Double) -> [AgendaItem] {
        var items = items
        if let current = currentIndex(items) {
            let start = items[current].spans[items[current].spans.count - 1].start
            items[current].spans[items[current].spans.count - 1].end = max(time, start)
        }
        return items
    }
    /// Minutes as a person says them: "8分", "1分未満".
    static func duration(_ seconds: Double) -> String {
        seconds < 60 ? "1分未満" : "\(Int((seconds / 60).rounded()))分"
    }
}

// Keyword search across a meeting: its title, tags, minutes and transcript.
struct SearchHit: Equatable {
    enum Place: Equatable { case title, tags, agenda, minutes, transcript }
    var place: Place
    var snippet: String  // The matching passage, cut around the first keyword.
    var segmentID: String?  // The utterance, when the passage is in the transcript.
    var time: Double?
    var source: String?  // マイク or Mac音声, when the passage is in the transcript.
}
// Finding words inside one meeting: its transcript and its minutes each have a find bar, which steps through the
// lines or items holding every word.
struct FindState: Equatable {
    var query = ""
    var index = 0
    var open = false
    var focus = 0  // Bumped to put the cursor back in the field.
    var terms: [String] { MeetingSearch.terms(query) }
    /// Moves to the next (1) or previous (-1) match, wrapping around.
    mutating func step(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }
    func current(in matches: [String]) -> String? {
        matches.isEmpty || terms.isEmpty ? nil : matches[min(index, matches.count - 1)]
    }
}
enum MeetingSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive]
    private static func containsAll(_ text: String, _ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: options) != nil }
    }
    /// The transcript lines holding every word, in order.
    static func lines(_ meeting: Meeting, terms: [String]) -> [String] {
        meeting.segments.filter { containsAll($0.text, terms) }.map(\.id)
    }
    /// The minutes items holding every word in any of their fields, in the order the minutes show them.
    static func items(_ meeting: Meeting, terms: [String]) -> [String] {
        guard let content = meeting.notes?.content else { return [] }
        let shown =
            content.summary.filter { $0.state != .cancelled } + content.decisions.filter { $0.state != .cancelled }
            + content.unresolved.filter { $0.state == .open } + content.history
            + content.actions.filter { $0.state != .cancelled }
        return shown.filter { item in
            containsAll(
                [item.text, item.owner, item.due, item.reason, item.nextStep, item.changeSummary].compactMap { $0 }
                    .joined(separator: "\n"), terms)
        }.map(\.id)
    }
    /// Keywords separated by spaces (half-width or full-width). A meeting must contain every one.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return query.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter {
            seen.insert($0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)).inserted
        }
    }
    /// Where the meeting matches, or nil unless every keyword appears somewhere in it.
    /// The passage shown is the first place, in reading order, that has the first keyword.
    static func search(_ meeting: Meeting, terms: [String]) -> SearchHit? {
        guard let first = terms.first else { return nil }
        let places = places(meeting)
        for term in terms.dropFirst() where !places.contains(where: { $0.1.range(of: term, options: options) != nil }) {
            return nil
        }
        for (place, text, segment) in places {
            guard let range = text.range(of: first, options: options) else { continue }
            return hit(place, text, segment, around: range)
        }
        return nil
    }
    /// Every place in the meeting that has a keyword: those with the most keywords first, then in reading order.
    /// Nil unless the meeting has every keyword somewhere.
    static func passages(_ meeting: Meeting, terms: [String], limit: Int) -> [SearchHit]? {
        guard search(meeting, terms: terms) != nil else { return nil }
        var found: [(hit: SearchHit, matched: Int, order: Int)] = []
        for (order, (place, text, segment)) in places(meeting).enumerated() {
            let matched = terms.filter { text.range(of: $0, options: options) != nil }
            guard let term = matched.first, let range = text.range(of: term, options: options) else { continue }
            found.append((hit(place, text, segment, around: range), matched.count, order))
        }
        return found.sorted { $0.matched != $1.matched ? $0.matched > $1.matched : $0.order < $1.order }
            .prefix(limit).map(\.hit)
    }
    /// The searchable text of a meeting, in reading order.
    private static func places(_ meeting: Meeting) -> [(SearchHit.Place, String, Segment?)] {
        var places: [(SearchHit.Place, String, Segment?)] = [(.title, meeting.title, nil)]
        places += meeting.tags.map { (.tags, $0, nil) }
        places += meeting.agenda.flatMap { [$0.title, $0.goal].compactMap { $0.map { (.agenda, $0, nil) } } }
        if let content = meeting.notes?.content {
            for item in content.summary + content.decisions + content.unresolved + content.actions {
                places += [item.text, item.reason, item.nextStep, item.changeSummary, item.owner, item.due]
                    .compactMap { $0.map { (.minutes, $0, nil) } }
            }
        } else if !meeting.minutes.isEmpty {
            places.append((.minutes, meeting.minutes, nil))
        }
        places += meeting.segments.map { (.transcript, $0.text, $0) }
        return places
    }
    private static func hit(
        _ place: SearchHit.Place, _ text: String, _ segment: Segment?, around range: Range<String.Index>
    )
        -> SearchHit
    {
        SearchHit(
            place: place, snippet: snippet(text, around: range), segmentID: segment?.id, time: segment?.time,
            source: segment?.source)
    }
    /// Every occurrence of every keyword in the text, for marking them.
    static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for term in terms {
            var rest = text.startIndex..<text.endIndex
            while let range = text.range(of: term, options: options, range: rest), !range.isEmpty {
                result.append(range)
                rest = range.upperBound..<text.endIndex
            }
        }
        return result
    }
    static func snippet(_ text: String, around range: Range<String.Index>, before: Int = 14, after: Int = 40)
        -> String
    {
        let start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        let passage = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + passage + (end < text.endIndex ? "…" : "")
    }
}

/// A count short enough for a chip or badge: up to 9999 as is, then 1.2万, 123万 and so on.
func shortCount(_ count: Int) -> String {
    count.formatted(.number.notation(.compactName).locale(Locale(identifier: "ja_JP")))
}
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}
extension Meeting {
    /// Failed transcription chunks as a sentence for either window, or nil when nothing failed.
    var transcriptionFailure: String? {
        let failed = jobs.filter { $0.state == .failed }
        guard let first = failed.first else { return nil }
        return "\(first.source) \(clock(first.offset)) からの文字起こしに失敗しました（\(failed.count)件）。\(first.lastError ?? "")"
    }
}
// The audio a meeting needs only while it is processed: the chunks and any per-track .caf files from earlier
// versions. 録音.m4a (for listening back) and 議事録.md stay.
enum WorkingAudio {
    static func files(in folder: URL) -> [URL] {
        let manager = FileManager.default
        let chunks = folder.appendingPathComponent("chunks")
        let tracks = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "caf" }
        return (manager.fileExists(atPath: chunks.path) ? [chunks] : []) + tracks
    }
    static func size(in folder: URL) -> Int64 { files(in: folder).reduce(0) { $0 + diskSize($1) } }
    /// Deletes the working audio and returns the bytes freed.
    @discardableResult static func remove(in folder: URL) -> Int64 {
        var freed: Int64 = 0
        for url in files(in: folder) {
            let size = diskSize(url)
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed
    }
    static func diskSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let item = items?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
// "1.7 MB", and "0 KB" rather than "Zero KB".
func bytes(_ count: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: count)
}
// How much the save location uses, split by what the files are for.
struct StorageUsage: Equatable, Sendable {
    var recordings: Int64 = 0  // 録音.m4a
    var working: Int64 = 0  // Chunks and per-track audio.
    var other: Int64 = 0  // Minutes and the app's data.
    var meetings = 0
    var total: Int64 { recordings + working + other }
    static func measure(_ root: URL) -> StorageUsage {
        var usage = StorageUsage()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders
        where FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.json").path) {
            usage.meetings += 1
            let all = WorkingAudio.diskSize(folder)
            let recording = WorkingAudio.diskSize(folder.appendingPathComponent(AudioMixdown.filename))
            let working = WorkingAudio.size(in: folder)
            usage.recordings += recording
            usage.working += working
            usage.other += max(0, all - recording - working)
        }
        return usage
    }
}
// A name that is safe as a file or folder name in Finder.
func fileSafeName(_ text: String, fallback: String) -> String {
    let unsafe = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
    let name = String(text.unicodeScalars.map { unsafe.contains($0) ? Character("-") : Character($0) })
        .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? fallback : String(name.prefix(80))
}
// A folder as Finder names it, e.g. "~/書類/ギジログ" for ~/Documents/ギジログ.
func displayPath(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    var current = url.standardizedFileURL
    var names: [String] = []
    while current.path != "/" && current.path != home {
        names.insert(FileManager.default.displayName(atPath: current.path), at: 0)
        current = current.deletingLastPathComponent()
    }
    return (current.path == home ? "~/" : "/") + names.joined(separator: "/")
}
// "2026-10-03 17.26 週次定例": sorts by date in Finder. Untitled meetings are just "会議".
func meetingFolderName(date: Date, title: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH.mm"
    return formatter.string(from: date) + " " + fileSafeName(isUntitledMeeting(title) ? "会議" : title, fallback: "会議")
}
/// Whether the title is the one given to a meeting started without a name ("会議 2026/10/05 13:00").
func isUntitledMeeting(_ title: String) -> Bool {
    title.range(of: #"^会議 \d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2}$"#, options: .regularExpression) != nil
}

// Encoding and disk access stay off the UI actor. Every write is an atomic checkpoint.
// Each meeting is one folder holding its audio, the readable minutes (議事録.md) and the app's own data.
actor MeetingRepository {
    static let documentName = "議事録.md"
    private(set) var root: URL
    private let discard: @Sendable (URL) throws -> Void
    private var savedRevisions: [UUID: UInt64] = [:]
    private var deleted: Set<UUID> = []
    init(root: URL, discard: (@Sendable (URL) throws -> Void)? = nil) {
        self.root = root
        self.discard = discard ?? { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    }
    func folder(for meeting: Meeting) -> URL {
        root.appendingPathComponent(meeting.folderName ?? meeting.id.uuidString)
    }
    /// Returns the number of bytes written, or 0 when a stale or deleted snapshot is ignored.
    @discardableResult func save(_ meeting: Meeting) throws -> Int {
        guard !deleted.contains(meeting.id), meeting.revision >= savedRevisions[meeting.id, default: 0] else {
            return 0
        }
        let folder = folder(for: meeting)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(meeting)
        try data.write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        // The readable minutes travel with the audio; they are rewritten whenever the meeting changes.
        if let document = MinutesEngine.document(meeting) {
            try Data(document.utf8).write(to: folder.appendingPathComponent(Self.documentName), options: .atomic)
        }
        savedRevisions[meeting.id] = meeting.revision
        return data.count
    }
    func load() throws -> ([Meeting], [String]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var meetings: [Meeting] = []
        var errors: [String] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let file = folder.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                var meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
                meeting.folderName = folder.lastPathComponent
                meetings.append(meeting)
            } catch {
                errors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (meetings.sorted { $0.date > $1.date }, errors)
    }
    // Meetings saved before 議事録.md existed get one when they are next loaded.
    func writeMissingDocuments(_ meetings: [Meeting]) {
        for meeting in meetings {
            let file = folder(for: meeting).appendingPathComponent(Self.documentName)
            guard !FileManager.default.fileExists(atPath: file.path), let document = MinutesEngine.document(meeting)
            else { continue }
            try? Data(document.utf8).write(to: file, options: .atomic)
        }
    }
    func backup(_ meeting: Meeting) throws {
        let folder = folder(for: meeting)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(meeting).write(
            to: folder.appendingPathComponent("meeting.before-reprocess.json"), options: .atomic)
    }
    /// Moves the meeting folder to the Trash. Later writes for the meeting are ignored so it cannot reappear.
    func delete(_ meeting: Meeting) throws {
        let folder = folder(for: meeting)
        if FileManager.default.fileExists(atPath: folder.path) { try discard(folder) }
        deleted.insert(meeting.id)
        savedRevisions[meeting.id] = nil
    }
    /// Moves every meeting folder to a new save location and switches to it. Returns folders that could not move.
    func relocate(to newRoot: URL) throws -> [String] {
        let failures = try Self.moveMeetings(from: root, to: newRoot, rename: nil)
        root = newRoot
        return failures
    }
    /// Moves meeting folders between save locations, keeping each folder's name unless `rename` gives a new one.
    nonisolated static func moveMeetings(from source: URL, to target: URL, rename: ((Meeting) -> String)?) throws
        -> [String]
    {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        guard source.standardizedFileURL != target.standardizedFileURL,
            let folders = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        else { return [] }
        var failures: [String] = []
        for folder in folders {
            let file = folder.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var name = folder.lastPathComponent
            if let rename, let meeting = try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file)) {
                name = rename(meeting)
            }
            do { try FileManager.default.moveItem(at: folder, to: uniqueFolder(in: target, name: name)) } catch {
                failures.append(folder.lastPathComponent)
            }
        }
        return failures
    }
    nonisolated static func uniqueFolder(in root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(name) (\(number))")
            number += 1
        }
        return candidate
    }
}
