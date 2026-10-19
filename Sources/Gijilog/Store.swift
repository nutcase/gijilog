import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// The last few seconds of peak levels per track, drawn as a scrolling waveform.
// Published apart from Store so the 10 Hz meter does not redraw the transcript.
@MainActor final class LevelMeter: ObservableObject {
    static let length = 48  // About 5 seconds at the recorder's 10 Hz updates.
    @Published private(set) var system = [Float](repeating: 0, count: length)
    @Published private(set) var microphone = [Float](repeating: 0, count: length)
    func record(_ value: Float, microphone isMicrophone: Bool) {
        if isMicrophone {
            microphone = Array(microphone.dropFirst()) + [value]
        } else {
            system = Array(system.dropFirst()) + [value]
        }
    }
    func reset() {
        system = [Float](repeating: 0, count: Self.length)
        microphone = system
    }
}

@MainActor final class Store: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selected: UUID? {
        didSet {
            if selected != nil && askOpen { askOpen = false }  // Choosing a meeting leaves the questions.
            // An utterance a link or an item's evidence pointed to is marked only until another meeting is shown.
            if let revealed, revealed.meetingID != selected { self.revealed = nil }
        }
    }
    @Published var recording = false
    @Published var busy = false  // Only capture setup/flush; AI processing does not block another meeting.
    @Published var ready = true
    @Published var status = "準備完了"
    @Published var error: String?
    @Published var tab = "議事録"
    @Published var deletion: Meeting?  // Awaiting confirmation in the UI.
    @Published var showsTranscript = true  // The live transcript panel beside the minutes.
    @Published var pinsLiveWindow = true  // Keep the compact live window above the video call.
    @Published var dropTargeted = false  // A file is being dragged over the window.
    @Published var tagFilter: [String] = []  // The list shows meetings that have every one of these.
    @Published var tagEditor: UUID?  // The meeting whose tag field is open.
    @Published var settingsTab = "一般"
    @Published var liveTab = "議事録"  // The compact window shows the minutes or the transcript.
    // Questions about every meeting fill the main view in place of a meeting, opened from the top of the list. The
    // conversation lasts as long as the app runs; while the AI answers, it says what it is reading.
    @Published var askOpen = false
    var viewedBeforeAsking: UUID?  // "この会議" in a question.
    @Published var asked: [AskMessage] = []
    @Published var askTags: [String] = []  // Questions read only the meetings with any of these tags; none, all.
    let askStream = AskStream()
    var draggedNoteItem: NoteItemDrag?  // The item a drag in the minutes started from, until it is dropped.
    var askTask: Task<Void, Never>?
    var askGeneration = 0  // Counts conversations, so an answer stopped by a new one is dropped.
    // The utterance an answer's link or a minutes item's evidence pointed to, marked in the transcript.
    @Published var revealed: Reveal?
    // Names and terms the transcription should spell this way, one per line or separated by commas.
    @Published var vocabulary = "" { didSet { saveVocabulary() } }
    // Misheard words learned from every fix ("森バス、もりばす → モリバス" a line): new speech is fixed with them, and
    // their right spellings are transcription hints. Both lists are kept in the save location's vocabulary.json.
    @Published var learnedWords = "" { didSet { saveVocabulary() } }
    var learned: [LearnedWord] { LearnedWords.capped(LearnedWords.parse(learnedWords)) }
    private var readingVocabulary = false  // Taking the lists from their file, which need not be written back.
    // vocabulary.json written wrong, as by hand: the lists are not saved until it is put right, so that nothing
    // written there is lost.
    @Published private(set) var vocabularyProblem: VocabularyFile.Unreadable?
    private var vocabularyBase: VocabularyFile?  // The lists as last read from the file or written to it.
    private var vocabularyDate: Date?  // When the file was last changed, as of then.
    /// Writes the lists. Another Mac may have changed the file since it was last read here, before this Mac took the
    /// change in: its changes are kept, and this Mac's join them.
    private func saveVocabulary() {
        guard persistsSettings && !readingVocabulary && vocabularyProblem == nil else { return }
        let mine = VocabularyFile(terms: vocabulary, corrections: learnedWords)
        var lists = mine
        // The file is read again only when it changed since: saving runs at every keystroke in the settings.
        if VocabularyFile.modified(in: root) != vocabularyDate {
            let theirs = readVocabulary(in: root)
            guard vocabularyProblem == nil else { return }
            // A file that was not there when the lists were last read has nothing removed from it, only added.
            let base = vocabularyBase ?? VocabularyFile()
            if let theirs, theirs != base {
                lists = VocabularyFile.merged(base: base, mine: mine, theirs: theirs)
                readingVocabulary = true
                if lists.terms != mine.terms { vocabulary = lists.terms.joined(separator: "\n") }
                if lists.corrections != mine.corrections { learnedWords = LearnedWords.format(lists.corrections) }
                readingVocabulary = false
            }
        }
        if lists.write(in: root) {
            vocabularyBase = lists
            vocabularyDate = VocabularyFile.modified(in: root)
        }
    }
    /// The lists in a save location's vocabulary.json; nil when it has none, or one written wrong, which is noted.
    private func readVocabulary(in root: URL) -> VocabularyFile? {
        do {
            let file = try VocabularyFile.read(in: root)
            vocabularyProblem = nil
            vocabularyDate = VocabularyFile.modified(in: root)
            return file
        } catch {
            let problem = error as? VocabularyFile.Unreadable ?? VocabularyFile.Unreadable()
            if vocabularyProblem != problem { status = problem.message }
            vocabularyProblem = problem
            return nil
        }
    }
    /// What transcription is told to spell this way for a meeting: the vocabulary list, the right spellings learned
    /// from fixes (but those undone in this meeting), and the people named as owners, without honorifics.
    func hintVocabulary(for meeting: Meeting) -> String {
        let ignored = Set(meeting.ignoredLearned ?? [])
        let people = knownOwners.map { name in
            ["さん", "さま", "様", "氏", "くん", "君", "ちゃん"].first(where: { name.hasSuffix($0) && name.count > $0.count })
                .map { String(name.dropLast($0.count)) } ?? name
        }
        let terms = TranscriptionHints.terms(vocabulary).prefix(VocabularyFile.termLimit)
        return (terms + learned.map(\.to).filter { !ignored.contains($0) } + people).joined(separator: "\n")
    }
    @Published var compactWindowOpen = false  // Alerts go to the compact window while it is open, else the full one.
    let player = ClipPlayer()  // Plays back one utterance of a finished meeting.
    // Sections of the minutes folded away, by title: the same in every meeting and in both windows, and kept.
    @Published var foldedSections: Set<String> = [] {
        didSet {
            if persistsSettings { UserDefaults.standard.set(foldedSections.sorted(), forKey: "foldedSections") }
        }
    }
    func toggleFolded(_ section: String) {
        if foldedSections.contains(section) { foldedSections.remove(section) } else { foldedSections.insert(section) }
    }
    @Published var editingTitle: UUID? {  // The meeting whose title is open for renaming.
        didSet { if editingTitle == nil && oldValue != nil { takeInChangesLeftWhileEditing() } }
    }
    @Published var editingNoteItem: String? {  // The minutes item open for editing, as "part/id".
        didSet { if editingNoteItem == nil && oldValue != nil { takeInChangesLeftWhileEditing() } }
    }
    @Published var addingNoteItem: String?  // The section whose "add an item" field is open, as "meeting/part".
    @Published var editingSegment: String? {  // The transcript line open for editing.
        didSet { if editingSegment == nil && oldValue != nil { takeInChangesLeftWhileEditing() } }
    }
    @Published var minutesFind = FindState()  // Finding words in the open meeting's minutes.
    @Published var transcriptFind = FindState()  // Finding words in the open meeting's transcript.
    @Published var correctionOffer: CorrectionOffer?  // After an edit: fix the same word elsewhere too?
    @Published var correcting: CorrectionRequest?  // The sheet for fixing a word across a meeting.
    @Published var editingAgendaItem: UUID?  // The agenda topic open for editing; the others show as text.
    @Published var addingAgenda: UUID?  // The meeting whose "add a topic" field is open.
    @Published var searchText = ""
    @Published var focusesSearch = false  // Set by ⌘F; the sidebar moves the cursor to its search field.
    @Published var searchHits: [UUID: SearchHit] = [:]
    @Published var searchedTerms: [String] = []  // The keywords searchHits answers.
    private var searchUpdates: AnyCancellable?
    // Once a meeting is complete and 録音.m4a exists, its chunks are only needed to reprocess per track.
    @Published var removesWorkingAudio = true {
        didSet { if persistsSettings { UserDefaults.standard.set(removesWorkingAudio, forKey: "removesWorkingAudio") } }
    }
    // Local MCP: AI apps on this Mac read meetings through the bundled bridge. See MCPServer.swift.
    @Published var mcpEnabled = true {
        didSet {
            guard persistsSettings else { return }
            UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled")
            updateMCPServer()
        }
    }
    @Published var mcpIncludesTranscript = true {
        didSet {
            if persistsSettings { UserDefaults.standard.set(mcpIncludesTranscript, forKey: "mcpIncludesTranscript") }
        }
    }
    @Published var mcpHiddenTags: [String] = [] {  // Meetings with any of these tags are never shown to AI apps.
        didSet { if persistsSettings { UserDefaults.standard.set(mcpHiddenTags, forKey: "mcpHiddenTags") } }
    }
    @Published var mcpAccesses: [MCPAccess] = []
    @Published var mcpConnections = 0
    @Published var mcpProblem: String?
    var mcpServer: MCPSocketServer?
    @Published var storageUsage: StorageUsage?
    @Published var reclaimableBytes: Int64 = 0
    // Importing is separate from `busy` (capture setup and stop), so a recording can always be stopped.
    @Published var importing = false
    var importQueue: [URL] = []
    var importTask: Task<Void, Never>?
    // Changed only through saveSettings; the settings form edits its own draft.
    @Published var key = ""
    @Published var model = "gpt-6-sol"
    @Published var microphone = ""
    @Published var pendingChunks = 0
    @Published var preparingIDs: Set<UUID> = []
    let meter = LevelMeter()
    let recorder: Recorder
    @Published private(set) var root: URL  // The save location: one folder per meeting.
    var folderWatcher: FolderWatcher?  // New meeting folders in the save location, while the app runs.
    let repository: MeetingRepository
    let persistsSettings: Bool
    // Names this Mac in the meetings it records or processes (Meeting.workingMac). Stores that keep no settings, as
    // in tests and previews, share one for the process: the same Mac.
    let thisMac: String
    static let unsavedMac = UUID().uuidString
    var activeID: UUID?
    lazy var pipeline = ProcessingPipeline(store: self)
    var captureInputID: String?  // The microphone in use, so unrelated devices cannot stop a recording.
    var summaryTimer: Timer?
    var silenceTimer: Timer?
    // A stop is under way: the system audio capture is ending, the last audio is being written and the meeting
    // saved as stopped. (Set only by stop; a test sets it to stand for a slow one.)
    var stopping = false
    // Recording stops by itself after this many minutes without sound on either track (0: never), as when a
    // meeting ended and the recording was left running.
    @Published var autoStopMinutes = 15 {
        didSet { if persistsSettings { UserDefaults.standard.set(autoStopMinutes, forKey: "autoStopMinutes") } }
    }
    @Published var lastSoundAt = Date()  // When someone was last heard in the recording.
    static let silenceWarning: TimeInterval = 60  // How long before stopping the warning shows.
    /// Seconds until recording stops for silence, while it is close enough to warn; nil otherwise.
    func secondsUntilSilenceStop(now: Date = Date()) -> Int? {
        guard recording, autoStopMinutes > 0 else { return nil }
        let left = Double(autoStopMinutes * 60) - now.timeIntervalSince(lastSoundAt)
        return left <= Self.silenceWarning ? max(0, Int(left.rounded(.up))) : nil
    }
    /// Someone was heard, or the user asked to keep recording: the silence starts over.
    func heardSound() { lastSoundAt = Date() }
    func dismissSilenceStop(_ id: UUID) { change(id) { $0.stoppedForSilence = nil } }
    func stopIfSilent(now: Date = Date()) async {
        guard recording, !busy, autoStopMinutes > 0, let id = activeID,
            now.timeIntervalSince(lastSoundAt) >= Double(autoStopMinutes * 60)
        else { return }
        await stop()
        change(id) { $0.stoppedForSilence = now }
        try? await checkpoint(id)
        status = "音が\(autoStopMinutes)分なかったため、録音を止めました。"
    }
    var activity: NSObjectProtocol?
    var shuttingDown = false
    var pendingCaptureError: String?
    private var observers: [NSObjectProtocol] = []
    // Every change is written by a coalesced checkpoint; lifecycle steps also call checkpoint() directly.
    // Revisions live here rather than in the published meetings so a save does not redraw the UI.
    var dirtyIDs: Set<UUID> = []
    var revisions: [UUID: UInt64] = [:]
    var savedCounts: [UUID: SaveCounts] = [:]  // Of the version this Mac last saved or took in (see Sync.swift).
    var savedSizes: [UUID: Int] = [:]
    var backgroundWork: Task<Void, Never>?  // Work on meeting folders, one step at a time (StoreProcessing).
    private var flushTask: Task<Void, Never>?
    private var writesInFlight = 0
    var hasPendingWrites: Bool { !dirtyIDs.isEmpty || writesInFlight > 0 }
    var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
    init(
        root: URL? = nil, recorder: Recorder = Recorder(), loadSettings: Bool = true,
        discardFolder: (@Sendable (URL) throws -> Void)? = nil, copies: URL? = nil
    ) {
        self.recorder = recorder
        if loadSettings {
            Self.adoptPreviousSettings(
                into: .standard, from: Self.previousBundleIDs.compactMap { UserDefaults(suiteName: $0) })
        }
        let root =
            root ?? UserDefaults.standard.string(forKey: "storageFolder").map(URL.init(fileURLWithPath:))
            ?? Self.defaultRoot
        self.root = root
        persistsSettings = loadSettings
        if loadSettings, let id = Self.machineID() {
            thisMac = id
        } else if loadSettings {
            let saved = UserDefaults.standard.string(forKey: "thisMac")
            thisMac = saved ?? UUID().uuidString
            if saved == nil { UserDefaults.standard.set(thisMac, forKey: "thisMac") }
        } else {
            thisMac = Self.unsavedMac
        }
        repository = MeetingRepository(
            root: root, copies: copies ?? (loadSettings ? Self.copies : nil), discard: discardFolder)
        if loadSettings {
            let defaults = UserDefaults.standard
            microphone = defaults.string(forKey: "microphone") ?? ""
            removesWorkingAudio = defaults.object(forKey: "removesWorkingAudio") as? Bool ?? true
            mcpEnabled = defaults.object(forKey: "mcpEnabled") as? Bool ?? true
            mcpIncludesTranscript = defaults.object(forKey: "mcpIncludesTranscript") as? Bool ?? true
            mcpHiddenTags = defaults.stringArray(forKey: "mcpHiddenTags") ?? []
            autoStopMinutes = defaults.object(forKey: "autoStopMinutes") as? Int ?? 15
            // The lists are read from the save location without writing them back (the observers of these published
            // properties do run here, and an empty list read before its file exists would create it empty).
            readingVocabulary = true
            VocabularyFile.adoptOldFiles(in: root)
            let read = readVocabulary(in: root)
            vocabularyBase = read
            let file = read ?? VocabularyFile()
            learnedWords = LearnedWords.format(file.corrections)
            // The vocabulary moved from the app's settings to the save location, to be shared with the meetings:
            // what was kept in the settings joins whatever the file has, once.
            if let kept = defaults.string(forKey: "vocabulary"), vocabularyProblem == nil {
                let joined = file.merging(terms: kept, corrections: "")
                vocabulary = joined.terms.joined(separator: "\n")
                if joined.write(in: root) {
                    vocabularyBase = joined
                    defaults.removeObject(forKey: "vocabulary")
                }
            } else {
                vocabulary = file.terms.joined(separator: "\n")
            }
            readingVocabulary = false
            foldedSections = Set(defaults.stringArray(forKey: "foldedSections") ?? [])
            let savedModel = defaults.string(forKey: "summaryModel")
            model = savedModel == "gpt-4.1-mini" ? "gpt-6-sol" : (savedModel ?? model)
            ready = false
            // Reading the key can wait on macOS asking whether this build may use it, as after a rebuild: the window
            // and the menu bar come up meanwhile, and recovery waits for the key to know what it may resume.
            let keyLoad = Task.detached { KeyStore.read() }
            Task {
                let saved = await keyLoad.value
                if key.isEmpty { key = saved }  // Unless one was saved in Settings meanwhile.
                await moveMeetings(from: Self.previousLocations)
                await recover()
            }
        }
        recorder.onError = { [weak self] message in
            Task { @MainActor in await self?.interrupt(message) }
        }
        recorder.onChunk = { [weak self] url, offset, source in
            await self?.enqueueChunk(url, offset: offset, source: source)
        }
        recorder.onLevel = { [weak self] source, value in
            Task { @MainActor in self?.meter.record(value, microphone: source == "マイク") }
        }
        recorder.onSound = { [weak self] in Task { @MainActor in self?.heardSound() } }
        // Search once typing pauses, and again as a live meeting grows.
        searchUpdates = Publishers.CombineLatest($searchText, $meetings)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshSearch() } }
        if loadSettings {
            updateMCPServer()
            observers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in await self?.interrupt("Macのスリープにより録音を中断しました。復帰後に録音を開始してください。") }
                })
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
                ) { [weak self] note in
                    let device = note.object as? AVCaptureDevice
                    let id = device?.uniqueID
                    let isAudio = device?.hasMediaType(.audio) ?? false
                    Task { @MainActor in
                        guard let self, Store.isCaptureInputLost(id, isAudio: isAudio, inUse: self.captureInputID)
                        else { return }
                        await self.interrupt("マイクが切断されました。入力機器を確認して録音を開始してください。")
                    }
                })
        }
    }
    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    // Cameras and microphones other than the one being recorded may come and go during a meeting.
    // When the default input is used, a later default change is followed by capture and covered by the watchdog.
    nonisolated static func isCaptureInputLost(_ id: String?, isAudio: Bool, inUse: String?) -> Bool {
        isAudio && id != nil && id == inUse
    }
    var settings: SessionSettings { SessionSettings(model: model) }
    var hasKey: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ギジログ")
    }
    func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(meetings.first { $0.id == id }?.folderName ?? id.uuidString)
    }
    // Earlier versions, newest first: the app was キロクル (bundle IDs io.github.nutcase.kirokuru and
    // local.minutes.kirokuru, default folder ~/Documents/キロクル), and before that local.minutes.desktop, which
    // kept meetings in Application Support under UUID folders. Settings from a newer ID win.
    nonisolated static let previousBundleIDs = [
        "io.github.nutcase.kirokuru", "local.minutes.kirokuru", "local.minutes.desktop",
    ]
    struct PreviousLocation: Sendable {
        let folder: URL
        let renamesFolders: Bool  // UUID-named folders get date-and-title names.
    }
    nonisolated static var previousLocations: [PreviousLocation] {
        let manager = FileManager.default
        return [
            PreviousLocation(
                folder: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Minutes/Meetings"), renamesFolders: true),
            PreviousLocation(
                folder: manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("キロクル"),
                renamesFolders: false),
        ]
    }
    /// Copies settings the new bundle ID does not have yet, so a custom save location survives the rename.
    nonisolated static func adoptPreviousSettings(into defaults: UserDefaults, from previous: [UserDefaults]) {
        for key in ["storageFolder", "summaryModel", "microphone"] where defaults.object(forKey: key) == nil {
            if let value = previous.lazy.compactMap({ $0.object(forKey: key) }).first {
                defaults.set(value, forKey: key)
            }
        }
    }
    // Moves meetings from earlier default locations into the save location once, so none disappear from the list.
    func moveMeetings(from locations: [PreviousLocation]) async {
        let target = root
        for location in locations {
            let source = location.folder
            guard source.standardizedFileURL != target.standardizedFileURL,
                FileManager.default.fileExists(atPath: source.path)
            else { continue }
            let renames = location.renamesFolders
            let result = await Task.detached { () -> Result<[String], Error> in
                Result {
                    try MeetingRepository.moveMeetings(
                        from: source, to: target,
                        rename: renames ? { meetingFolderName(date: $0.date, title: $0.title) } : nil)
                }
            }.value
            switch result {
            case .success(let failures) where !failures.isEmpty:
                error =
                    "一部の会議を新しい保存先へ移動できませんでした。元の場所に残っています: \(source.path)\n"
                    + failures.joined(separator: "\n")
            case .failure(let failure):
                error =
                    "保存先（\(displayPath(target))）に書き込めません。これまでの会議は元の場所に残っています。\n"
                    + failure.localizedDescription
                return
            default: break
            }
        }
    }
    // Changing the save location moves every meeting with it, so the list always matches one folder.
    func chooseStorageFolder() {
        guard ready, !recording, !busy, !meetings.contains(where: { isProcessing($0.id) }) else {
            error = "録音中や処理中は保存先を変更できません。終わってから変更してください。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "ここに保存"
        panel.directoryURL = root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL, url != root.standardizedFileURL else {
            return
        }
        guard !url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            error = "今の保存先の中のフォルダは選べません。"
            return
        }
        let alert = NSAlert()
        alert.messageText = "保存先を変更しますか？"
        alert.informativeText = "これまでの会議 \(meetings.count)件のフォルダも「\(url.lastPathComponent)」へ移動します。"
        alert.addButton(withTitle: "移動して変更")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await changeStorage(to: url) }
    }
    func changeStorage(to newRoot: URL) async {
        await flushCheckpoints()
        busy = true
        defer { busy = false }
        do {
            let failures = try await repository.relocate(to: newRoot)
            root = newRoot
            // The list goes along, joined with one the new location may already have.
            if persistsSettings {
                VocabularyFile.adoptOldFiles(in: newRoot)
                let there = readVocabulary(in: newRoot)
                if vocabularyProblem == nil {
                    let joined = (there ?? VocabularyFile()).merging(terms: vocabulary, corrections: learnedWords)
                    readingVocabulary = true
                    vocabulary = joined.terms.joined(separator: "\n")
                    learnedWords = LearnedWords.format(joined.corrections)
                    readingVocabulary = false
                    vocabularyBase = joined.write(in: newRoot) ? joined : there
                }
            }
            if persistsSettings { UserDefaults.standard.set(newRoot.path, forKey: "storageFolder") }
            await recover()
            status = "保存先を変更しました"
            if !failures.isEmpty {
                error = "一部の会議を移動できませんでした。元の場所に残っています。\n" + failures.joined(separator: "\n")
            }
        } catch { self.error = "保存先を変更できませんでした: " + error.localizedDescription }
    }
    func change(_ id: UUID, _ update: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        update(&meetings[i])
        dirtyIDs.insert(id)
        scheduleFlush(id)
    }
    func checkpoint(_ id: UUID) async throws {
        guard var meeting = meetings.first(where: { $0.id == id }) else { return }
        dirtyIDs.remove(id)  // Changes made while this write is in flight mark the meeting dirty again.
        let revision = max(revisions[id] ?? 0, meeting.revision) + 1
        let counts = (savedCounts[id] ?? SaveCounts.of(meeting)).adding(thisMac)
        revisions[id] = revision
        savedCounts[id] = counts
        meeting.revision = revision
        meeting.saveCounts = counts
        meeting.schemaVersion = max(meeting.schemaVersion, Meeting.schema)  // A newer one is not saved (see save).
        meeting.savedOn = Self.computerName
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        do {
            savedSizes[id] = try await repository.save(meeting, history: id != activeID)
        } catch {
            dirtyIDs.insert(id)
            throw error
        }
    }
    // Rewriting a long meeting on every chunk grows with the square of its length. Writes are coalesced and,
    // for large meetings, limited to about 50 KB/s (at most every 10 seconds). A crash re-runs only the latest jobs.
    func scheduleFlush(_ id: UUID) {
        guard flushTask == nil else { return }
        let delay = min(10, max(1, Double(savedSizes[id] ?? 0) / 50_000))
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flushCheckpoints()
        }
    }
    func flushCheckpoints() async {
        flushTask?.cancel()
        flushTask = nil
        var failed: Set<UUID> = []
        while let id = dirtyIDs.subtracting(failed).first {
            do { try await checkpoint(id) } catch {
                failed.insert(id)
                self.error = error.localizedDescription
                pipeline.pause()
                // Do not await stop here: a delivery callback may be waiting on this flush.
                if id == activeID { Task { await interrupt("処理状態を保存できませんでした。録音を停止します。") } }
            }
        }
    }
    /// A meeting changed on another Mac while it was open for editing here was left as it was; once the edit closes,
    /// unless it changed the meeting (whose next save then goes over the other), the change is taken in.
    private func takeInChangesLeftWhileEditing() {
        guard persistsSettings else { return }
        Task { await reloadChangedMeetings() }
    }
    /// Takes the lists from the save location when they changed there, as when another Mac or a hand edited them.
    /// Lists that read the same are kept as typed.
    func readVocabularyFile() {
        // The watcher hears every change in the save location, most of them meetings being saved: a file unchanged
        // since it was last read or written is not read again, unless it could not be read then.
        guard persistsSettings, vocabularyProblem != nil || VocabularyFile.modified(in: root) != vocabularyDate,
            let file = readVocabulary(in: root)
        else { return }
        vocabularyBase = file
        readingVocabulary = true
        defer { readingVocabulary = false }
        let here = VocabularyFile(terms: vocabulary, corrections: learnedWords)
        if file.terms != here.terms { vocabulary = file.terms.joined(separator: "\n") }
        if file.corrections != here.corrections { learnedWords = LearnedWords.format(file.corrections) }
    }
    /// Whether a request to quit is turned down: while recording, one sent by another app (`sender`, its bundle ID, or
    /// "" for a process without one), as an app that quits apps it thinks unused would. The user's own quit (⌘Q and
    /// the menus send none), the Dock's, and logging out or shutting down (which give a reason) go ahead.
    nonisolated static func refusesQuit(recording: Bool, sender: String?, fromThisApp: Bool, systemReason: Bool)
        -> Bool
    {
        guard recording, let sender, !fromThisApp, !systemReason else { return false }
        return sender != "com.apple.dock"
    }
    func prepareForTermination() async {
        shuttingDown = true
        stopMCPServer()  // The bridge starts the app again when an AI app next asks.
        pipeline.pause(terminal: true)
        recorder.cancelPendingStart()
        // Quitting right after 停止 lets that stop finish, so the meeting is saved as stopped, not as interrupted.
        for _ in 0..<300 where stopping { try? await Task.sleep(nanoseconds: 50_000_000) }
        if recording {
            await stop()
        } else if let id = activeID {
            do { try await recorder.stop() } catch { self.error = error.localizedDescription }
            change(id) {
                $0.capture = .interrupted
                $0.status = "録音開始を中断・保存済み"
            }
            activeID = nil
        }
        await flushCheckpoints()  // Only meetings changed since their last checkpoint are written.
    }
    @discardableResult func saveSettings(microphone: String, key: String, model: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try KeyStore.save(key) } catch {
            self.error = error.localizedDescription
            return false
        }
        self.key = key
        self.model = model.isEmpty ? "gpt-6-sol" : model
        self.microphone = microphone
        let defaults = UserDefaults.standard
        defaults.set(self.model, forKey: "summaryModel")
        defaults.set(microphone, forKey: "microphone")
        status = "設定を保存しました"
        return true
    }
    /// Saves the minutes where the user chooses, with the transcript only when asked for: the minutes are what
    /// gets shared, and the transcript is long. (A checkbox in the save panel was not drawn: the panel runs in
    /// another process, and the accessory window stayed blank.)
    func export(_ meeting: Meeting, includesTranscript: Bool = false) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.exportFilename(meeting.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = MinutesEngine.document(meeting, includesTranscript: includesTranscript)
            try (text ?? "# \(meeting.title)\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
        }
    }
    nonisolated static func exportFilename(_ title: String) -> String { fileSafeName(title, fallback: "議事録") + ".md" }
}

/// A decision, open issue or action being dragged to another topic: which meeting, section and item it is. What the
/// drag carries is the item's own text, which is what a text field it is dropped on takes.
struct NoteItemDrag: Equatable {
    let meetingID: UUID
    let part: NotePart
    let id: String
}
/// An utterance to show in the transcript, and in which window: the full window's panel, or the compact window's
/// tab. `count` tells one request from the next, so the same utterance asked for twice is scrolled to twice.
struct Reveal: Equatable {
    let meetingID: UUID
    let segmentID: String
    let compact: Bool
    let count: Int
}
/// What ギジログAI is doing while it answers: what it reads, and the answer as it is written. Kept apart from the
/// Store, so that each piece of a streamed answer redraws the conversation alone.
@MainActor final class AskStream: ObservableObject {
    @Published var progress: String?
    @Published var draft = ""
    @Published var question = ""  // Being typed, kept while a meeting is open in place of the conversation.
}
