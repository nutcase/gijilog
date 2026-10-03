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
struct SessionSettings: Codable, Sendable {
    var mode = "hybrid"
    var model = "gpt-6-sol"
    var localModel = ""
    var cloud: Bool { mode == "cloud" }
    var cloudSummary: Bool { mode != "local" }
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
    var state = "open"
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
    var extractionOnly = false
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
    init(title: String) { self.title = title }
    enum CodingKeys: String, CodingKey {
        case id, title, date, segments, minutes, status, capture, settings, jobs, notes, captureError, hasAudio,
            revision
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
    }
}

// Encoding and disk access stay off the UI actor. Every write is an atomic checkpoint.
actor MeetingRepository {
    let root: URL
    private var savedRevisions: [UUID: UInt64] = [:]
    init(root: URL) { self.root = root }
    func save(_ meeting: Meeting) throws {
        guard meeting.revision >= savedRevisions[meeting.id, default: 0] else { return }
        let folder = root.appendingPathComponent(meeting.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(meeting).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        savedRevisions[meeting.id] = meeting.revision
    }
    func load() throws -> ([Meeting], [String]) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var meetings: [Meeting] = []
        var errors: [String] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let file = folder.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do { meetings.append(try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))) } catch {
                errors.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (meetings.sorted { $0.date > $1.date }, errors)
    }
    func flush() {}
    func backup(_ meeting: Meeting) throws {
        let folder = root.appendingPathComponent(meeting.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(meeting).write(
            to: folder.appendingPathComponent("meeting.before-reprocess.json"), options: .atomic)
    }
}
