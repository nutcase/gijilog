import Foundation

struct Segment: Codable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var time: Double
    var source: String
    var text: String
    init(id: String = UUID().uuidString, time: Double, source: String, text: String) {
        self.id = id
        self.time = time
        self.source = source
        self.text = text
    }
    enum CodingKeys: String, CodingKey { case id, time, source, text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        source = try c.decode(String.self, forKey: .source)
        text = try c.decode(String.self, forKey: .text)
        // Old meetings acquire repeatable IDs when reopened.
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? stableID("\(time)|\(source)|\(text)")
    }
}
func stableID(_ text: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
}
enum CaptureState: String, Codable { case recording, stopped, interrupted }
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
struct NoteItem: Codable, Identifiable, Sendable {
    var id: String
    var text: String
    var owner: String?
    var due: String?
    var evidence: [String]
    var state = ItemState.open
}
struct NotesDelta: Codable, Sendable {
    var summary: [NoteItem] = []
    var decisions: [NoteItem] = []
    var unresolved: [NoteItem] = []
    var actions: [NoteItem] = []
}
struct MinutesState: Codable, Sendable {
    var content = NotesDelta()
    var appliedSegmentIDs: Set<String> = []
    var updatedAt: Date?
    var extractionOnly = false  // Notes from the former keyword-extraction mode.
    var rejectedItems: Int?  // AI items dropped because their evidence could not be verified.
    var latestSegmentIDs: Set<String>?  // Utterances behind the most recent update, to mark what just changed.
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
    var captureError: String?
    var hasAudio: Bool?
    var revision: UInt64 = 0
    // The meeting's folder inside the save location. Loading sets it from the folder actually found,
    // so a folder renamed in Finder keeps working. Older meetings live in a folder named by their UUID.
    var folderName: String?
    init(title: String) { self.title = title }
    enum CodingKeys: String, CodingKey {
        case id, title, date, segments, minutes, status, capture, settings, jobs, notes, captureError, hasAudio,
            revision, folderName
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
        captureError = try c.decodeIfPresent(String.self, forKey: .captureError)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName)
    }
}

// A name that is safe as a file or folder name in Finder.
func fileSafeName(_ text: String, fallback: String) -> String {
    let unsafe = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
    let name = String(text.unicodeScalars.map { unsafe.contains($0) ? Character("-") : Character($0) })
        .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? fallback : String(name.prefix(80))
}
// A folder as Finder names it, e.g. "~/書類/キロクル" for ~/Documents/キロクル.
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
    let untitled = title.range(of: #"^会議 \d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    return formatter.string(from: date) + " " + fileSafeName(untitled ? "会議" : title, fallback: "会議")
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
