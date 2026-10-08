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
        didSet { if selected != nil && askOpen { askOpen = false } }  // Choosing a meeting leaves the questions.
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
    @Published private(set) var tagFilter: [String] = []  // The list shows meetings that have every one of these.
    @Published var tagEditor: UUID?  // The meeting whose tag field is open.
    @Published var settingsTab = "一般"
    @Published var liveTab = "議事録"  // The compact window shows the minutes or the transcript.
    // Questions about every meeting fill the main view in place of a meeting, opened from the top of the list. The
    // conversation lasts as long as the app runs; while the AI answers, it says what it is reading.
    @Published private(set) var askOpen = false
    private var viewedBeforeAsking: UUID?  // "この会議" in a question.
    @Published var asked: [AskMessage] = []
    @Published var askTags: [String] = []  // Questions read only the meetings with any of these tags; none, all.
    @Published private(set) var askProgress: String?
    @Published private(set) var askDraft = ""  // The answer as it is being written.
    private var askTask: Task<Void, Never>?
    // The utterance an answer's link pointed to, marked in the transcript.
    @Published private(set) var revealed: (meetingID: UUID, segmentID: String)?
    // Names and terms the transcription should spell this way, one per line or separated by commas.
    @Published var vocabulary = "" { didSet { saveVocabulary() } }
    // Misheard words learned from every fix ("森バス、もりばす → モリバス" a line): new speech is fixed with them, and
    // their right spellings are transcription hints. Both lists are kept in the save location's vocabulary.json.
    @Published var learnedWords = "" { didSet { saveVocabulary() } }
    var learned: [LearnedWord] { LearnedWords.parse(learnedWords) }
    private var readingVocabulary = false  // Taking the lists from their file, which need not be written back.
    // vocabulary.json written wrong, as by hand: the lists are not saved until it is put right, so that nothing
    // written there is lost.
    @Published private(set) var vocabularyProblem: VocabularyFile.Unreadable?
    private func saveVocabulary() {
        guard persistsSettings && !readingVocabulary && vocabularyProblem == nil else { return }
        VocabularyFile(terms: vocabulary, corrections: learnedWords).write(in: root)
    }
    /// The lists in a save location's vocabulary.json; nil when it has none, or one written wrong, which is noted.
    private func readVocabulary(in root: URL) -> VocabularyFile? {
        do {
            let file = try VocabularyFile.read(in: root)
            vocabularyProblem = nil
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
        return ([vocabulary] + learned.map(\.to).filter { !ignored.contains($0) } + people).joined(separator: "\n")
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
    @Published var editingTitle: UUID?  // The meeting whose title is open for renaming.
    @Published var editingNoteItem: String?  // The minutes item open for editing, as "part/id".
    @Published var addingNoteItem: String?  // The section whose "add an item" field is open, as "meeting/part".
    @Published var editingSegment: String?  // The transcript line open for editing.
    @Published var minutesFind = FindState()  // Finding words in the open meeting's minutes.
    @Published var transcriptFind = FindState()  // Finding words in the open meeting's transcript.
    @Published var correctionOffer: CorrectionOffer?  // After an edit: fix the same word elsewhere too?
    @Published var correcting: CorrectionRequest?  // The sheet for fixing a word across a meeting.
    @Published var editingAgendaItem: UUID?  // The agenda topic open for editing; the others show as text.
    @Published var addingAgenda: UUID?  // The meeting whose "add a topic" field is open.
    @Published var searchText = ""
    @Published var focusesSearch = false  // Set by ⌘F; the sidebar moves the cursor to its search field.
    @Published private(set) var searchHits: [UUID: SearchHit] = [:]
    @Published private(set) var searchedTerms: [String] = []  // The keywords searchHits answers.
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
    @Published private(set) var mcpAccesses: [MCPAccess] = []
    @Published private(set) var mcpConnections = 0
    @Published private(set) var mcpProblem: String?
    private var mcpServer: MCPSocketServer?
    @Published private(set) var storageUsage: StorageUsage?
    @Published private(set) var reclaimableBytes: Int64 = 0
    // Importing is separate from `busy` (capture setup and stop), so a recording can always be stopped.
    @Published private(set) var importing = false
    private var importQueue: [URL] = []
    private var importTask: Task<Void, Never>?
    // Changed only through saveSettings; the settings form edits its own draft.
    @Published var key = ""
    @Published var model = "gpt-6-sol"
    @Published var microphone = ""
    @Published var pendingChunks = 0
    @Published private(set) var preparingIDs: Set<UUID> = []
    let meter = LevelMeter()
    let recorder: Recorder
    @Published private(set) var root: URL  // The save location: one folder per meeting.
    private var folderWatcher: FolderWatcher?  // New meeting folders in the save location, while the app runs.
    let repository: MeetingRepository
    private let persistsSettings: Bool
    var activeID: UUID?
    lazy var pipeline = ProcessingPipeline(store: self)
    private var captureInputID: String?  // The microphone in use, so unrelated devices cannot stop a recording.
    private var summaryTimer: Timer?
    private var silenceTimer: Timer?
    // A stop is under way: the system audio capture is ending, the last audio is being written and the meeting
    // saved as stopped. (Set only by stop; a test sets it to stand for a slow one.)
    var stopping = false
    // Recording stops by itself after this many minutes without sound on either track (0: never), as when a
    // meeting ended and the recording was left running.
    @Published var autoStopMinutes = 15 {
        didSet { if persistsSettings { UserDefaults.standard.set(autoStopMinutes, forKey: "autoStopMinutes") } }
    }
    @Published private(set) var lastSoundAt = Date()  // When someone was last heard in the recording.
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
    private var activity: NSObjectProtocol?
    private var shuttingDown = false
    private var pendingCaptureError: String?
    private var observers: [NSObjectProtocol] = []
    // Every change is written by a coalesced checkpoint; lifecycle steps also call checkpoint() directly.
    // Revisions live here rather than in the published meetings so a save does not redraw the UI.
    private var dirtyIDs: Set<UUID> = []
    private var revisions: [UUID: UInt64] = [:]
    private var savedSizes: [UUID: Int] = [:]
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
        discardFolder: (@Sendable (URL) throws -> Void)? = nil
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
        repository = MeetingRepository(root: root, discard: discardFolder)
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
            let file = readVocabulary(in: root) ?? VocabularyFile()
            learnedWords = LearnedWords.format(file.corrections)
            // The vocabulary moved from the app's settings to the save location, to be shared with the meetings:
            // what was kept in the settings joins whatever the file has, once.
            if let kept = defaults.string(forKey: "vocabulary"), vocabularyProblem == nil {
                let joined = file.merging(terms: kept, corrections: "")
                vocabulary = joined.terms.joined(separator: "\n")
                if joined.write(in: root) { defaults.removeObject(forKey: "vocabulary") }
            } else {
                vocabulary = file.terms.joined(separator: "\n")
            }
            readingVocabulary = false
            foldedSections = Set(defaults.stringArray(forKey: "foldedSections") ?? [])
            key = KeyStore.read()
            let savedModel = defaults.string(forKey: "summaryModel")
            model = savedModel == "gpt-4.1-mini" ? "gpt-6-sol" : (savedModel ?? model)
            ready = false
            Task {
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
                    joined.write(in: newRoot)
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
        revisions[id] = revision
        meeting.revision = revision
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        do {
            savedSizes[id] = try await repository.save(meeting)
        } catch {
            dirtyIDs.insert(id)
            throw error
        }
    }
    // Rewriting a long meeting on every chunk grows with the square of its length. Writes are coalesced and,
    // for large meetings, limited to about 50 KB/s (at most every 10 seconds). A crash re-runs only the latest jobs.
    private func scheduleFlush(_ id: UUID) {
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
    func recover() async {
        defer { ready = true }
        do {
            let (saved, failures) = try await repository.load()
            meetings = saved
            for meeting in saved { revisions[meeting.id] = meeting.revision }
            await repository.writeMissingDocuments(saved)
            selected = meetings.first?.id
            if !failures.isEmpty { error = "一部の会議を読み込めませんでした。保存場所のデータは保持しています。\n" + failures.joined(separator: "\n") }
            for meeting in saved {
                let id = meeting.id
                let interrupted = meeting.capture == .recording
                if interrupted || meeting.jobs.contains(where: { $0.state == .running }) {
                    change(id) { m in
                        if interrupted {
                            m.capture = .interrupted
                            m.status = "録音中断・未処理を復旧中"
                        }
                        for i in m.jobs.indices where m.jobs[i].state == .running {
                            m.jobs[i].state = .pending
                            m.jobs[i].retryAfter = nil
                        }
                    }
                }
                if meeting.settings != nil {
                    // Settled meetings are left untouched; only unfinished work, or audio never inspected, is recovered.
                    let needsRecovery =
                        interrupted || (meeting.notes == nil && meeting.hasAudio == nil)
                        || meeting.finalReviewPending == true
                        || meeting.jobs.contains { $0.state == .pending || $0.state == .running }
                        || !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
                    guard needsRecovery else { continue }
                    do {
                        if interrupted || meeting.finalReviewPending != true || meeting.hasAudio == nil
                            || meeting.jobs.contains(where: { $0.state == .pending || $0.state == .running })
                        {
                            try await discoverJobs(id)
                        }
                        if hasKey {
                            try await checkpoint(id)
                            pipeline.resume(id, key: key)
                        } else {
                            change(id) { $0.status = "録音済み・APIキー設定後に未処理を再開" }
                            try await checkpoint(id)
                        }
                    } catch {
                        change(id) {
                            $0.status = "録音済み・復旧確認が必要"
                            $0.captureError = error.localizedDescription
                        }
                        try? await checkpoint(id)
                        self.error = error.localizedDescription
                    }
                } else if interrupted {
                    try await checkpoint(id)
                }
            }
            // The first launch that learns misheard words takes in the fixes already made in the meetings, joined with
            // whatever the list has (another Mac may have started it).
            if persistsSettings && vocabularyProblem == nil && !UserDefaults.standard.bool(forKey: "learnedWordsSeeded")
            {
                learnedWords = LearnedWords.merged(learnedWords, LearnedWords.seed(from: meetings))
                UserDefaults.standard.set(true, forKey: "learnedWordsSeeded")
            }
            // Only now are interrupted recordings marked and their audio found, so they get 録音.m4a on this launch.
            mixDown(meetings.filter { $0.capture != .recording && $0.hasAudio == true }.map(\.id), onlyMissing: true)
        } catch { self.error = error.localizedDescription }
        if persistsSettings {
            folderWatcher = FolderWatcher(root) { [weak self] in
                Task { @MainActor in
                    await self?.loadAddedMeetings()
                    await self?.reloadChangedMeetings()
                    self?.readVocabularyFile()
                }
            }
        }
    }
    /// Takes in listed meetings changed in the save location by something else, such as the same meeting edited on
    /// another Mac and synced. A meeting being recorded, processed or edited here, or with changes not yet saved,
    /// keeps this Mac's version, which its next save writes over the other.
    func reloadChangedMeetings() async {
        guard ready else { return }
        let listed = meetings.map { (id: $0.id, folder: $0.folderName ?? $0.id.uuidString) }
        var reloaded = 0
        for meeting in await repository.loadChanged(listed) {
            let id = meeting.id
            let open = selected == id && (editingNoteItem != nil || editingSegment != nil || editingTitle == id)
            guard id != activeID, !isProcessing(id), !dirtyIDs.contains(id), !open,
                let i = meetings.firstIndex(where: { $0.id == id })
            else { continue }
            // Each Mac counts its own saves: the higher count goes on, so this Mac's next save is not taken as stale.
            var meeting = meeting
            meeting.revision = max(meeting.revision, meetings[i].revision, revisions[id] ?? 0)
            meetings[i] = meeting
            revisions[id] = meeting.revision
            reloaded += 1
        }
        if reloaded > 0 { status = reloaded == 1 ? "ほかで更新された会議を読み込み直しました" : "ほかで更新された会議を\(reloaded)件読み込み直しました" }
    }
    /// Takes the lists from the save location when they changed there, as when another Mac or a hand edited them.
    /// Lists that read the same are kept as typed.
    func readVocabularyFile() {
        guard persistsSettings, let file = readVocabulary(in: root) else { return }
        readingVocabulary = true
        defer { readingVocabulary = false }
        let here = VocabularyFile(terms: vocabulary, corrections: learnedWords)
        if file.terms != here.terms { vocabulary = file.terms.joined(separator: "\n") }
        if file.corrections != here.corrections { learnedWords = LearnedWords.format(file.corrections) }
    }
    /// Lists meeting folders that appeared in the save location while the app runs, such as ones synced from another
    /// Mac or restored from a backup, without a restart. They are shown as they are: nothing is processed for them
    /// here, and a meeting already listed, or a copy of one, is not loaded again.
    func loadAddedMeetings() async {
        guard ready else { return }  // Loading at launch or after a move reads every folder anyway.
        let known = Set(meetings.map { $0.folderName ?? $0.id.uuidString })
        let found = await repository.loadAdded(skipping: known)
        // Checked against the list as it is after the read, not before it. A sync arrives as a burst of changes and
        // each starts a load of its own; one that began while another was reading found the same meeting unlisted,
        // and both added it.
        let listed = Set(meetings.map(\.id))
        var added: [Meeting] = []
        for meeting in found where !listed.contains(meeting.id) && !added.contains(where: { $0.id == meeting.id }) {
            added.append(meeting)
        }
        guard !added.isEmpty else { return }
        for meeting in added { revisions[meeting.id] = meeting.revision }
        meetings = (meetings + added).sorted { $0.date > $1.date }
        await repository.writeMissingDocuments(added)
        status = added.count == 1 ? "「\(added[0].title)」を読み込みました" : "会議を\(added.count)件読み込みました"
    }
    func discoverJobs(_ id: UUID) async throws {
        let path = folder(id)
        let inputs = try await Task.detached { try Processor.recordingInputs(folder: path, allowMissing: true) }.value
        change(id) { meeting in
            for input in inputs {
                let relative =
                    input.url.deletingLastPathComponent().lastPathComponent == "chunks"
                    ? "chunks/" + input.url.lastPathComponent : input.url.lastPathComponent
                if !meeting.jobs.contains(where: { $0.filename == relative }) {
                    meeting.jobs.append(
                        TranscriptionJob(
                            id: stableID(relative), filename: relative, offset: input.offset, source: input.source))
                }
            }
            meeting.jobs.sort { $0.offset < $1.offset }
        }
        let hasAudio = try await Task.detached { try Processor.hasRecordedAudio(folder: path) }.value
        change(id) { $0.hasAudio = hasAudio }
    }
    /// Records the selected prepared meeting, or a new one. `newMeeting` always starts a new one.
    func start(newMeeting forcesNew: Bool = false) async {
        guard canStartRecording() else { return }
        busy = true
        pendingCaptureError = nil
        defer { busy = false }
        // A prepared meeting that is selected is the one recorded, with its title, tags and agenda.
        let planned = forcesNew ? nil : selectedMeeting(where: { $0.capture == .planned })
        let id: UUID
        if let planned {
            id = planned.id
            change(id) { meeting in
                meeting.capture = .recording
                meeting.date = Date()
                meeting.settings = settings
                meeting.finalReviewPending = true
                meeting.status = "録音中"
            }
        } else {
            let meeting = newMeeting(capture: .recording)
            id = meeting.id
            meetings.insert(meeting, at: 0)
        }
        await record(id) { meeting in
            if let planned {
                // Still prepared: the agenda waits for the next try.
                meeting.capture = .planned
                meeting.date = planned.date
                meeting.settings = nil
                meeting.finalReviewPending = nil
                meeting.status = "準備中"
                meeting.agenda = planned.agenda
            } else {
                meeting.capture = .interrupted
                meeting.status = "録音開始失敗"
            }
        }
    }
    /// A finished meeting can take more recording once nothing is processing it.
    func canContinueRecording(_ meeting: Meeting) -> Bool {
        (meeting.capture == .stopped || meeting.capture == .interrupted) && meeting.id != activeID
            && !isProcessing(meeting.id) && !preparingIDs.contains(meeting.id)
    }
    /// Records more of a finished meeting, such as after a break: the new speech follows the earlier recording on
    /// the meeting's clock, the transcript and minutes grow, and stopping makes one 録音.m4a and reviews the whole
    /// meeting again.
    func continueRecording(_ id: UUID) async {
        guard canStartRecording(), let before = meetings.first(where: { $0.id == id }), canContinueRecording(before)
        else { return }
        busy = true
        pendingCaptureError = nil
        defer { busy = false }
        let base: Double
        do { base = try await prepareContinuation(id) } catch {
            self.error = error.localizedDescription
            return
        }
        change(id) { meeting in
            meeting.capture = .recording
            meeting.status = "録音中"
            meeting.settings = settings
            meeting.finalReviewPending = true
            meeting.notes?.reviewedSegmentIDs = nil
            meeting.notes?.finalizedAt = nil
            meeting.captureError = nil
            meeting.clockStart = Date().addingTimeInterval(-base)
        }
        await record(id, continuingAt: base) { meeting in
            meeting.capture = before.capture
            meeting.status = before.status
            meeting.settings = before.settings
            meeting.finalReviewPending = before.finalReviewPending
            meeting.notes?.reviewedSegmentIDs = before.notes?.reviewedSegmentIDs
            meeting.notes?.finalizedAt = before.notes?.finalizedAt
            meeting.clockStart = before.clockStart
        }
    }
    /// Gets a finished meeting ready to record more and returns where the new part starts on its clock. Its earlier
    /// audio has to stay in the working audio, so that 録音.m4a can be made again with both parts: when it was
    /// cleaned up, 録音.m4a is cut into chunks again, marked as transcribed already.
    func prepareContinuation(_ id: UUID) async throws -> Double {
        let folder = folder(id)
        if try await Task.detached(operation: { try Self.workingAudioMissing(folder) }).value {
            let mix = folder.appendingPathComponent(AudioMixdown.filename)
            guard FileManager.default.fileExists(atPath: mix.path) else {
                throw AppError.message("この会議の録音（録音.m4a）が見つからないため、続けて録音できません。")
            }
            let chunks = try await Task.detached {
                WorkingAudio.remove(in: folder)
                return try await AudioImport.split(mix, into: folder)
            }.value
            change(id) { meeting in
                for chunk in chunks {
                    let relative = "chunks/" + chunk.filename
                    meeting.jobs.removeAll { $0.filename == relative }
                    meeting.jobs.append(
                        TranscriptionJob(
                            id: stableID(relative), filename: relative, offset: chunk.offset, source: chunk.source,
                            state: .completed))
                }
            }
        }
        let length = try await Task.detached { try Processor.recordedLength(folder: folder) }.value
        let lastSpeech = meetings.first { $0.id == id }?.segments.map(\.time).max() ?? 0
        return max(length, lastSpeech + 1)
    }
    private func canStartRecording() -> Bool {
        guard ready, !recording, !busy, !shuttingDown else { return false }
        guard hasKey else {
            error = "録音するには、設定でOpenAI APIキーを保存してください。"
            return false
        }
        if !microphone.isEmpty && AVCaptureDevice(uniqueID: microphone) == nil {
            error = "設定で選んだマイクが見つかりません。接続を確認するか、設定でマイクを選び直してください。"
            return false
        }
        return true
    }
    /// Starts capturing into a meeting already marked as recording; on failure, `revert` puts the meeting back.
    private func record(_ id: UUID, continuingAt base: Double? = nil, revert: (inout Meeting) -> Void) async {
        showNewMeeting()
        selected = id
        activeID = id
        captureInputID = microphone.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : microphone
        do {
            try await checkpoint(id)
            pipeline.resume(id, key: key)
            try await recorder.start(
                folder: folder(id), microphone: microphone.isEmpty ? nil : microphone, continuingAt: base)
            recording = true
            status = "録音中 — Mac音声＋マイク"
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "会議音声を録音中")
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateLiveSummary() }
            }
            summaryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            lastSoundAt = Date()
            change(id) { $0.stoppedForSilence = nil }
            let silence = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.stopIfSilent() }
            }
            silenceTimer = silence
            RunLoop.main.add(silence, forMode: .common)
            if shuttingDown || pendingCaptureError != nil {
                busy = false
                if let message = pendingCaptureError { await interrupt(message) } else { await stop() }
            }
        } catch {
            change(id) { meeting in
                revert(&meeting)
                meeting.captureError = error.localizedDescription
            }
            activeID = nil
            captureInputID = nil
            self.error = error.localizedDescription
            try? await checkpoint(id)
        }
    }
    private func selectedMeeting(where condition: (Meeting) -> Bool) -> Meeting? {
        meetings.first { $0.id == selected && condition($0) }
    }
    /// A meeting titled by the time, in a new folder. Its title is changed by clicking it.
    private func newMeeting(capture: CaptureState) -> Meeting {
        var meeting = Meeting(title: "会議 \(Date().formatted(date: .numeric, time: .shortened))")
        meeting.capture = capture
        if capture == .planned {
            meeting.status = "準備中"
        } else {
            meeting.settings = settings
            meeting.finalReviewPending = true
        }
        meeting.folderName =
            MeetingRepository.uniqueFolder(
                in: root, name: meetingFolderName(date: meeting.date, title: "会議")
            ).lastPathComponent
        return meeting
    }
    // The new job is saved by the next coalesced checkpoint; the chunk is also listed in recording.json,
    // so recovery finds it even if the app stops before that write.
    func enqueueChunk(_ url: URL, offset: Double, source: String) {
        guard let id = activeID else { return }
        let relative = "chunks/" + url.lastPathComponent
        change(id) { meeting in
            if !meeting.jobs.contains(where: { $0.filename == relative }) {
                meeting.jobs.append(
                    TranscriptionJob(id: stableID(relative), filename: relative, offset: offset, source: source))
                meeting.jobs.sort { $0.offset < $1.offset }
            }
        }
        pipeline.pump()
    }
    func updateLiveSummary() { if recording, let id = activeID { pipeline.requestSummary(id) } }
    func interrupt(_ message: String) async {
        guard let id = activeID else { return }
        if busy {
            pendingCaptureError = message
            return
        }
        guard recording else { return }
        change(id) { $0.captureError = message }
        error = message
        await stop(interrupted: true)
    }
    func stop(interrupted: Bool = false) async {
        guard recording, !busy, let id = activeID else { return }
        busy = true
        stopping = true
        defer {
            busy = false
            stopping = false
        }
        summaryTimer?.invalidate()
        summaryTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        recording = false
        meter.reset()
        do { try await recorder.stop() } catch {
            change(id) { $0.captureError = error.localizedDescription }
            self.error = error.localizedDescription
        }
        activeID = nil
        captureInputID = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        change(id) {
            $0.capture = interrupted ? .interrupted : .stopped
            $0.status = "録音停止済み・残りを処理中"
            $0.agenda = MeetingAgenda.finish($0.agenda, at: Date().timeIntervalSince($0.recordingOrigin))
        }
        do { try await discoverJobs(id) } catch {
            self.error = error.localizedDescription
            change(id) { $0.captureError = error.localizedDescription }
        }
        do { try await checkpoint(id) } catch { self.error = error.localizedDescription }
        mixDown([id], onlyMissing: false)
        status = "録音を停止しました。残りはバックグラウンドで処理します。次の録音を開始できます。"
        pipeline.requestSummary(id, force: true)
        pipeline.pump()
    }
    func process(_ meetingID: UUID? = nil, rebuild: Bool = false) async {
        guard ready, !shuttingDown, let id = meetingID ?? selected, !busy, id != activeID, !isProcessing(id),
            meetings.first(where: { $0.id == id })?.capture != .planned
        else { return }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        guard hasKey else {
            error = "処理するには、設定でOpenAI APIキーを保存してください。"
            return
        }
        do {
            // A failed final review only needs text, even if working audio has already been removed.
            if !rebuild, let meeting = meetings.first(where: { $0.id == id }),
                meeting.finalReviewPending == true, !meeting.segments.isEmpty,
                meeting.jobs.allSatisfy({ $0.state == .completed })
            {
                try await checkpoint(id)
                pipeline.resume(id, key: key)
                pipeline.requestSummary(id, force: true)
                return
            }
            let folder = folder(id)
            // Without its working audio, a meeting is transcribed again from 録音.m4a (both tracks mixed).
            let fromMix = try await Task.detached { try Self.workingAudioMissing(folder) }.value
            var rebuild = rebuild || fromMix
            if let old = meetings.first(where: { $0.id == id }), rebuild || old.settings == nil {
                try await repository.backup(old)
                if old.settings == nil { rebuild = true }
            }
            if fromMix {
                let mix = folder.appendingPathComponent(AudioMixdown.filename)
                guard FileManager.default.fileExists(atPath: mix.path) else {
                    throw AppError.message("作業用の音声も録音.m4a もないため、再処理できません。")
                }
                _ = try await Task.detached {
                    WorkingAudio.remove(in: folder)
                    return try await AudioImport.split(mix, into: folder)
                }.value
                change(id) { $0.jobs = [] }
            }
            try await discoverJobs(id)
            change(id) { meeting in
                meeting.finalReviewPending = true
                if rebuild || meeting.settings == nil {
                    meeting.settings = settings
                    // Items edited by hand, and those deleted, carry over; the AI writes the rest again.
                    var kept = MinutesState()
                    for part in NotePart.allCases {
                        kept.content[part] = meeting.notes?.content[part].filter { $0.edited == true } ?? []
                    }
                    kept.dismissed = meeting.notes?.dismissed
                    let edited = NotePart.allCases.contains { !kept.content[$0].isEmpty } || kept.dismissed != nil
                    meeting.notes = edited ? kept : nil
                    meeting.segments = []
                    meeting.minutes = ""
                    for i in meeting.jobs.indices { meeting.jobs[i].state = .pending }
                }
                for i in meeting.jobs.indices where rebuild || meeting.jobs[i].state != .completed {
                    meeting.jobs[i].state = .pending
                    meeting.jobs[i].attempts = 0
                    meeting.jobs[i].retryAfter = nil
                    meeting.jobs[i].lastError = nil
                }
                meeting.status = "録音済み・未処理を再開中"
            }
            try await checkpoint(id)
            pipeline.resume(id, key: key)
            pipeline.requestSummary(id, force: true)
        } catch { self.error = error.localizedDescription }
    }
    /// Revisit the saved transcript without uploading or transcribing the audio again.
    func refineMinutes(_ id: UUID) async {
        guard ready, !shuttingDown, !busy, id != activeID, !isProcessing(id),
            let meeting = meetings.first(where: { $0.id == id }), !meeting.segments.isEmpty
        else { return }
        guard hasKey else {
            error = "議事録を仕上げるには、設定でOpenAI APIキーを保存してください。"
            return
        }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        change(id) {
            $0.finalReviewPending = true
            $0.notes?.reviewedSegmentIDs = nil
            $0.notes?.finalizedAt = nil
            $0.settings = settings
            $0.status = "録音済み・議事録を仕上げ中"
        }
        do {
            try await checkpoint(id)
            pipeline.resume(id, key: key)
            pipeline.requestSummary(id, force: true)
        } catch { self.error = error.localizedDescription }
    }
    /// True when some audio the meeting was cut into is gone (removed to save space, or deleted by hand).
    nonisolated static func workingAudioMissing(_ folder: URL) throws -> Bool {
        let inputs = try Processor.recordingInputs(folder: folder, allowMissing: true)
        return inputs.isEmpty || inputs.contains { !FileManager.default.fileExists(atPath: $0.url.path) }
    }
    func chooseRecordingFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.prompt = "議事録を作成"
        panel.message = "議事録を作る録音ファイル（音声・動画）を選んでください。"
        guard panel.runModal() == .OK else { return }
        importRecordings(panel.urls)
    }
    /// Queues files to import one after another; files dropped while an import runs wait their turn.
    func importRecordings(_ urls: [URL]) {
        importQueue += urls
        guard importTask == nil else { return }
        importTask = Task {
            while !importQueue.isEmpty { await importRecording(from: importQueue.removeFirst()) }
            importTask = nil
        }
    }
    // Minutes from a recording made elsewhere (Voice Memos, a Zoom recording, any audio or video file).
    // The original file is left untouched; the meeting folder gets the chunks, 録音.m4a and 議事録.md.
    func importRecording(from input: URL) async {
        guard ready, !shuttingDown else { return }
        guard hasKey else {
            error = "議事録を作るには、設定でOpenAI APIキーを保存してください。"
            return
        }
        importing = true
        defer { importing = false }
        status = "「\(input.lastPathComponent)」を読み込んでいます"
        let title = input.deletingPathExtension().lastPathComponent
        let date = (try? input.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let folderName =
            MeetingRepository.uniqueFolder(in: root, name: meetingFolderName(date: date, title: title))
            .lastPathComponent
        let folder = root.appendingPathComponent(folderName)
        let chunks: [RecordedChunk]
        do {
            chunks = try await Task.detached { try await AudioImport.split(input, into: folder) }.value
        } catch {
            try? FileManager.default.removeItem(at: folder)  // Only the folder created for this import.
            self.error = "「\(input.lastPathComponent)」から議事録を作れませんでした。\(error.localizedDescription)"
            status = "準備完了"
            return
        }
        var meeting = Meeting(title: title)
        meeting.date = date
        meeting.folderName = folderName
        meeting.settings = settings
        meeting.finalReviewPending = true
        meeting.capture = .stopped
        meeting.hasAudio = true
        meeting.status = "録音ファイルを文字起こし中"
        meeting.jobs = chunks.map { chunk in
            let relative = "chunks/" + chunk.filename
            return TranscriptionJob(
                id: stableID(relative), filename: relative, offset: chunk.offset, source: chunk.source)
        }
        meetings.insert(meeting, at: meetings.firstIndex { $0.date < date } ?? meetings.count)
        showNewMeeting()
        if !recording { selected = meeting.id }  // Keep the live meeting on screen.
        do { try await checkpoint(meeting.id) } catch { self.error = error.localizedDescription }
        mixDown([meeting.id], onlyMissing: false)
        pipeline.resume(meeting.id, key: key)
        status = "「\(title)」の文字起こしを始めました"
    }
    // Writes 録音.m4a next to the minutes in the background, one meeting at a time.
    // Work on meeting folders runs one step at a time, so working audio is never removed before 録音.m4a exists.
    private var backgroundWork: Task<Void, Never>?
    private func enqueueBackground(_ work: @escaping @MainActor () async -> Void) {
        let previous = backgroundWork
        backgroundWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
    private func mixDown(_ ids: [UUID], onlyMissing: Bool) {
        let folders = ids.map(folder).filter {
            !onlyMissing
                || !FileManager.default.fileExists(atPath: $0.appendingPathComponent(AudioMixdown.filename).path)
        }
        guard !folders.isEmpty else { return }
        enqueueBackground {
            await Task.detached(priority: .utility) {
                for folder in folders { try? await AudioMixdown.write(folder: folder) }
            }.value
        }
    }
    func waitForBackgroundWork() async {
        while let work = backgroundWork {
            await work.value
            if backgroundWork == work { return }
        }
    }
    func isComplete(_ meeting: Meeting) -> Bool {
        meeting.capture != .recording && !meeting.segments.isEmpty && meeting.jobs.allSatisfy { $0.state == .completed }
            && MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
            && meeting.finalReviewPending != true && !pipeline.summaryFailed(meeting.id)
    }
    /// Complete meetings whose working audio can go: 録音.m4a exists and nothing is working on them.
    func cleanableMeetings() -> [UUID] {
        meetings.filter { meeting in
            meeting.id != activeID && !isProcessing(meeting.id) && isComplete(meeting)
                && FileManager.default.fileExists(
                    atPath: folder(meeting.id).appendingPathComponent(AudioMixdown.filename).path)
        }.map(\.id)
    }
    /// Deletes the working audio of complete meetings and returns the bytes freed.
    @discardableResult func removeWorkingAudio(of ids: [UUID]) async -> Int64 {
        let ready = Set(cleanableMeetings())
        let claimed = ids.filter(ready.contains)
        guard !claimed.isEmpty else { return 0 }
        preparingIDs.formUnion(claimed)  // Holds off reprocessing and deletion while the files go.
        defer { preparingIDs.subtract(claimed) }
        let folders = claimed.map(folder)
        let freed = await Task.detached { folders.reduce(Int64(0)) { $0 + WorkingAudio.remove(in: $1) } }.value
        refreshStorageUsage()
        return freed
    }
    func refreshStorageUsage() {
        let root = root
        let folders = cleanableMeetings().map(folder)
        Task {
            let (usage, reclaimable) = await Task.detached {
                (StorageUsage.measure(root), folders.reduce(Int64(0)) { $0 + WorkingAudio.size(in: $1) })
            }.value
            storageUsage = usage
            reclaimableBytes = reclaimable
        }
    }
    func confirmWorkingAudioCleanup() {
        let ids = cleanableMeetings()
        guard !ids.isEmpty, reclaimableBytes > 0 else { return }
        let size = bytes(reclaimableBytes)
        let alert = NSAlert()
        alert.messageText = "作業用の音声を削除しますか？"
        alert.informativeText =
            "完了した会議 \(ids.count)件の作業用の音声（\(size)）を削除します。聞き返し用の録音.m4a と議事録は残ります。"
            + "全文を再処理するときは録音.m4a から文字起こしし直すため、Mac音声とマイクは区別されなくなります。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let freed = await removeWorkingAudio(of: ids)
            status = "作業用の音声を \(bytes(freed)) 削除しました"
        }
    }
    /// Retries only the failed transcription chunks, also while the meeting is still being recorded.
    func retryFailedJobs(_ id: UUID) {
        guard hasKey else {
            error = "再試行するには、設定でOpenAI APIキーを保存してください。"
            return
        }
        let folder = folder(id)
        let missing =
            meetings.first { $0.id == id }?.jobs.contains {
                $0.state == .failed
                    && !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.filename).path)
            } ?? false
        if missing && id != activeID {
            Task { await process(id, rebuild: true) }
            return
        }
        change(id) { meeting in
            for i in meeting.jobs.indices where meeting.jobs[i].state == .failed {
                meeting.jobs[i].state = .pending
                meeting.jobs[i].attempts = 0
                meeting.jobs[i].lastError = nil
                meeting.jobs[i].retryAfter = nil
            }
        }
        pipeline.resume(id, key: key)
    }
    func isProcessing(_ id: UUID) -> Bool { preparingIDs.contains(id) || pipeline.isProcessing(id) }
    func canDelete(_ id: UUID) -> Bool { ready && id != activeID && !busy && !isProcessing(id) }
    /// Moves the meeting's audio, transcript and minutes to the Trash.
    func delete(_ id: UUID) async {
        guard canDelete(id) else { return }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        do { try await repository.delete(meeting) } catch {
            self.error = "会議を削除できませんでした: " + error.localizedDescription
            return
        }
        pipeline.forget(id)
        dirtyIDs.remove(id)
        revisions[id] = nil
        savedSizes[id] = nil
        meetings.removeAll { $0.id == id }
        pruneTagFilter()
        if selected == id { selected = visibleMeetings.first?.id }
        status = "会議をゴミ箱に移動しました"
        refreshProcessingCounts()
    }
    func refreshProcessingCounts() {
        let pending = meetings.flatMap(\.jobs).filter { $0.state == .pending || $0.state == .running }.count
        if pendingChunks != pending { pendingChunks = pending }
        if recording {
            let text = "録音中（文字起こし待ち \(pending)件）"
            if status != text { status = text }
        }
    }
    func refreshCompletion(_ id: UUID, summaryFailed: Bool) {
        guard let meeting = meetings.first(where: { $0.id == id }), meeting.capture != .recording,
            meeting.capture != .planned, !meeting.jobs.contains(where: { $0.state == .pending || $0.state == .running })
        else { return }
        let result: String
        if meeting.hasAudio == false {
            result = "録音なし"
        } else if meeting.jobs.isEmpty && meeting.segments.isEmpty {
            result = "録音なし"
        } else if meeting.segments.isEmpty {
            result = meeting.jobs.contains { $0.state == .failed } ? "録音済み・文字起こし失敗" : "録音済み・認識結果なし"
        } else if summaryFailed {
            result = "録音済み・議事録作成失敗"
        } else if !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty {
            result = "録音済み・議事録を更新中"
        } else if meeting.finalReviewPending == true {
            result = "録音済み・議事録を仕上げ中"
        } else if meeting.jobs.contains(where: { $0.state == .failed }) || meeting.captureError != nil {
            result = "録音済み・一部処理失敗"
        } else if meeting.capture == .interrupted {
            result = "録音中断・保存済み"
        } else {
            result = "完了"
        }
        guard meeting.status != result else { return }
        change(id) { $0.status = result }
        if result == "完了" && removesWorkingAudio {
            enqueueBackground { [weak self] in await self?.removeWorkingAudio(of: [id]) }
        }
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

// MARK: - People

extension Store {
    /// Everyone named as an action's owner in any meeting, most often first: the list to pick an owner from, kept
    /// up to date by the minutes themselves. A name written with or without さん is one person, spelled as in the
    /// most recent meeting.
    var knownOwners: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        var order: [String] = []
        for meeting in meetings.sorted(by: { $0.date > $1.date }) {
            for owner in meeting.notes?.content.actions.filter({ $0.state != .cancelled }).flatMap(\.owners) ?? [] {
                let name = owner.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = Self.personKey(name)
                guard !key.isEmpty else { continue }
                if let entry = counts[key] {
                    counts[key] = (entry.name, entry.count + 1)
                } else {
                    counts[key] = (name, 1)
                    order.append(key)
                }
            }
        }
        return order.compactMap { counts[$0] }.enumerated()
            .sorted {
                $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
            }
            .map(\.element.name)
    }
    /// A name without spacing, width differences or a trailing honorific, to tell whether two names are one person.
    nonisolated static func personKey(_ name: String) -> String {
        var key = name.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil).filter { !$0.isWhitespace }
        for honorific in ["さん", "さま", "様", "氏", "くん", "君", "ちゃん"] where key.hasSuffix(honorific) {
            if key.count > honorific.count { key.removeLast(honorific.count) }
            break
        }
        return key
    }
}

// MARK: - Tags

extension Store {
    /// Every tag in use with the number of meetings that have it, most used first.
    /// A tag spelled differently across meetings is listed with its most recent meeting's spelling.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        var order: [String] = []
        for meeting in meetings {
            for tag in meeting.tags {
                let key = MeetingTags.key(tag)
                if let entry = counts[key] {
                    counts[key] = (entry.name, entry.count + 1)
                } else {
                    counts[key] = (tag, 1)
                    order.append(key)
                }
            }
        }
        return order.compactMap { counts[$0] }.enumerated()
            .sorted {
                $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
            }
            .map(\.element)
    }
    var visibleMeetings: [Meeting] {
        guard !tagFilter.isEmpty || !searchedTerms.isEmpty else { return meetings }
        return meetings.filter { meeting in
            tagFilter.allSatisfy { MeetingTags.contains(meeting.tags, $0) }
                && (searchedTerms.isEmpty || searchHits[meeting.id] != nil)
        }
    }
    /// Adds tags typed or picked for a meeting. A tag another meeting already has keeps that spelling.
    func addTags(_ text: String, to id: UUID) {
        let known = allTags.map(\.name)
        let tags = MeetingTags.parse(text).map { tag in
            known.first { MeetingTags.key($0) == MeetingTags.key(tag) } ?? tag
        }
        guard !tags.isEmpty else { return }
        change(id) { $0.tags = MeetingTags.adding(tags, to: $0.tags) }
    }
    func removeTag(_ tag: String, from id: UUID) {
        change(id) { meeting in meeting.tags.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) } }
        pruneTagFilter()
    }
    /// Narrows the list to meetings with the tag, or widens it again. A selection the list no longer shows
    /// moves to the first meeting it does.
    func toggleTagFilter(_ tag: String) {
        if MeetingTags.contains(tagFilter, tag) {
            tagFilter.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) }
        } else {
            tagFilter.append(tag)
        }
        selectVisibleMeeting()
    }
    func clearTagFilter() { tagFilter = [] }
    /// Renames a tag on every meeting. A name another tag already has merges the two, spelled as typed.
    /// Returns false when the name is empty or would be split into several tags by a comma.
    @discardableResult func renameTag(_ tag: String, to newName: String) -> Bool {
        let names = MeetingTags.parse(newName)
        guard names.count == 1, let name = names.first else { return false }
        let keys: Set = [MeetingTags.key(tag), MeetingTags.key(name)]
        for meeting in meetings where meeting.tags.contains(where: { keys.contains(MeetingTags.key($0)) }) {
            change(meeting.id) { meeting in
                meeting.tags = MeetingTags.adding(
                    meeting.tags.map { keys.contains(MeetingTags.key($0)) ? name : $0 }, to: [])
            }
        }
        tagFilter = MeetingTags.adding(tagFilter.map { keys.contains(MeetingTags.key($0)) ? name : $0 }, to: [])
        return true
    }
    /// Takes the tag off every meeting. The meetings themselves stay.
    func deleteTag(_ tag: String) {
        for meeting in meetings where MeetingTags.contains(meeting.tags, tag) {
            change(meeting.id) { meeting in meeting.tags.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) } }
        }
        pruneTagFilter()
    }
    /// A selection the list no longer shows moves to the first meeting it does.
    private func selectVisibleMeeting() {
        let visible = visibleMeetings
        if !visible.contains(where: { $0.id == selected }), let first = visible.first { selected = first.id }
    }
    /// A new meeting has no tags and matches no search yet; clear both so it shows in the list.
    private func showNewMeeting() {
        tagFilter = []
        if !searchText.isEmpty {
            searchText = ""
            refreshSearch()
        }
    }
    /// Finds the meetings that contain every keyword. A new query also moves the selection to its first result.
    func refreshSearch() {
        let terms = MeetingSearch.terms(searchText)
        var hits: [UUID: SearchHit] = [:]
        if !terms.isEmpty {
            for meeting in meetings {
                if let hit = MeetingSearch.search(meeting, terms: terms) { hits[meeting.id] = hit }
            }
        }
        if hits != searchHits { searchHits = hits }
        guard terms != searchedTerms else { return }
        searchedTerms = terms
        selectVisibleMeeting()
    }
    /// A tag no meeting has any more cannot narrow the list.
    private func pruneTagFilter() {
        let used = Set(meetings.flatMap { $0.tags.map(MeetingTags.key) })
        tagFilter.removeAll { !used.contains(MeetingTags.key($0)) }
    }
}

// MARK: - Editing minutes

struct CorrectionOffer: Equatable {
    var meetingID: UUID
    var from: String
    var to: String
    var count: Int
    var inTranscript = false  // Shown beside the transcript, where the edit was made.
}
struct CorrectionRequest: Identifiable {
    let id = UUID()
    var meetingID: UUID
    var from = ""
    var to = ""
}
extension Store {
    /// Minutes are edited by hand once the AI is not writing them: not while recording or processing.
    func canEditMinutes(_ meeting: Meeting) -> Bool {
        meeting.notes != nil && meeting.capture != .recording && meeting.capture != .planned
            && meeting.id != activeID && !pipeline.isProcessing(meeting.id)
    }
    /// Changes an item and marks it edited by hand, so AI updates leave it alone. An item edited to name another
    /// summary topic moves under it. Fixing a word offers to fix it elsewhere in the meeting, unless
    /// `offersCorrection` is false, as when a person is picked from the list (choosing someone else is not a
    /// misheard name), or the edit moved the item (it says what the item is about, not how a word sounded).
    func updateNoteItem(
        _ meetingID: UUID, part: NotePart, id: String, offersCorrection: Bool = true, _ update: (inout NoteItem) -> Void
    ) {
        var offer: CorrectionOffer?
        var offersCorrection = offersCorrection
        change(meetingID) { m in
            guard var item = m.notes?.content[part].first(where: { $0.id == id }),
                let i = m.notes?.content[part].firstIndex(where: { $0.id == id })
            else { return }
            let before = item
            update(&item)
            if part != .summary, item.text != before.text, let summary = m.notes?.content.summary {
                let known = Dictionary(m.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let current = MinutesEngine.topicIndex(of: before, in: summary, known: known)
                if let topic = MinutesEngine.topicNamedByEdit(
                    from: before.text, to: item.text, current: current, summary: summary)
                {
                    item.topic = topic
                    offersCorrection = false
                }
            }
            guard item != before else { return }
            item.edited = true
            m.notes?.content[part][i] = item
            if let notes = m.notes { m.minutes = MinutesEngine.render(notes, segments: m.segments) }
            // Points and opinions are also compared line by line, so a line added in the same edit does not hide a
            // fixed word.
            let edits = [NoteField.text, .owner, .reason, .nextStep, .points, .opinions].flatMap { field in
                guard let old = before[field], let new = item[field] else { return [(String, String)]() }
                let lines = zip(old.components(separatedBy: "\n"), new.components(separatedBy: "\n")).filter {
                    $0 != $1
                }
                return [(old, new)] + (field == .points || field == .opinions ? lines : [])
            }
            for (old, new) in edits where offersCorrection {
                guard let term = TermMatcher.changedTerm(from: old, to: new) else { continue }
                let count = m.occurrences(of: term.from, correctedTo: term.to).count
                if count > 0 {
                    offer = CorrectionOffer(meetingID: meetingID, from: term.from, to: term.to, count: count)
                    break
                }
            }
        }
        correctionOffer = offer
    }
    func openAsk() {
        guard !askOpen else { return }
        viewedBeforeAsking = selected
        selected = nil
        askOpen = true
    }
    /// Asks the AI about the meetings: it reads every meeting as it needs and answers in the conversation.
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, askTask == nil else { return }
        asked.append(AskMessage(role: .question, text: question))
        guard hasKey else {
            asked.append(AskMessage(role: .failure, text: "設定で OpenAI の APIキーを入れると、質問できます。"))
            return
        }
        let conversation = asked
        let tags = askScope
        let inScope = { (meeting: Meeting) in tags.isEmpty || tags.contains { MeetingTags.contains(meeting.tags, $0) } }
        let instructions = MeetingAgent.instructions(
            today: Date(),
            open: meetings.first { $0.id == (selected ?? viewedBeforeAsking) }.flatMap { inScope($0) ? $0 : nil },
            recording: recording ? meetings.first { $0.id == activeID }.flatMap { inScope($0) ? $0 : nil } : nil,
            tags: tags)
        let tools = MCPHandler(store: self, everything: true, tags: tags)
        let key = key
        let model = model
        askProgress = "考えています"
        askDraft = ""
        askTask = Task {
            do {
                let answer = try await MeetingAgent.answer(
                    conversation, instructions: instructions, model: model,
                    send: { try await MeetingAgent.stream($0, key: key, text: $1) },
                    run: { MeetingAgent.text(ofTool: tools.callTool($0, arguments: $1)) },
                    progress: { [weak self] in self?.askProgress = $0 },
                    writing: { [weak self] text in
                        self?.askDraft = text
                        if !text.isEmpty { self?.askProgress = "答えを書いています" }
                    })
                asked.append(AskMessage(role: .answer, text: answer))
            } catch {
                let stopped = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                // What was written before it stopped stays, marked as unfinished.
                if !askDraft.isEmpty {
                    asked.append(AskMessage(role: .answer, text: askDraft + "\n\n（ここまでで止まりました）"))
                }
                if !stopped || askDraft.isEmpty {
                    asked.append(AskMessage(role: .failure, text: stopped ? "止めました。" : error.localizedDescription))
                }
            }
            askDraft = ""
            askProgress = nil
            askTask = nil
        }
    }
    func stopAsking() { askTask?.cancel() }
    /// The tags questions are narrowed to, as they are now: one renamed or removed since it was chosen no longer counts.
    var askScope: [String] {
        askTags.filter { tag in allTags.contains { MeetingTags.key($0.name) == MeetingTags.key(tag) } }
    }
    /// How many meetings questions read.
    var askScopeCount: Int {
        let tags = askScope
        return meetings.filter { meeting in tags.isEmpty || tags.contains { MeetingTags.contains(meeting.tags, $0) } }
            .count
    }
    func toggleAskTag(_ tag: String) {
        if let i = askTags.firstIndex(where: { MeetingTags.key($0) == MeetingTags.key(tag) }) {
            askTags.remove(at: i)
        } else {
            askTags.append(tag)
        }
    }
    /// Starts a new conversation.
    func clearAsked() {
        stopAsking()
        asked = []
    }
    /// Follows a link in an answer: opens the meeting in place of the questions, and shows the utterance it points to
    /// in the transcript.
    /// False for a link that is not to a meeting here.
    func openAskLink(_ url: URL) -> Bool {
        guard let link = AskLink(url), let meeting = meetings.first(where: { $0.id == link.meetingID }) else {
            return false
        }
        selected = meeting.id
        if let seconds = link.seconds {
            // The utterance under way at that moment, or the first one after it.
            let ordered = meeting.segments.sorted { $0.time < $1.time }
            if let segment = ordered.last(where: { $0.time <= seconds + 1 }) ?? ordered.first {
                revealed = (meeting.id, segment.id)
                showsTranscript = true
            }
        }
        return true
    }
    /// Moves a decision, open issue or action under a summary topic by hand, where AI updates then keep it.
    func moveNoteItem(_ meetingID: UUID, part: NotePart, id: String, toTopic index: Int) {
        guard part != .summary, let meeting = meetings.first(where: { $0.id == meetingID }),
            let summary = meeting.notes?.content.summary, summary.indices.contains(index),
            let item = meeting.notes?.content[part].first(where: { $0.id == id })
        else { return }
        let known = Dictionary(meeting.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard MinutesEngine.topicIndex(of: item, in: summary, known: known) != index else { return }
        updateNoteItem(meetingID, part: part, id: id, offersCorrection: false) {
            $0.topic = MinutesEngine.topicName(summary[index])
        }
    }
    /// The transcript can be corrected whenever it exists, also during the recording: transcription only adds
    /// lines, and the minutes refer to lines by ID.
    func canEditTranscript(_ meeting: Meeting) -> Bool { meeting.capture != .planned && !meeting.segments.isEmpty }
    /// Corrects one line of the transcript. When the change fixed a word that appears elsewhere in the meeting,
    /// offers to fix it there too.
    func updateSegment(_ meetingID: UUID, id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var offer: CorrectionOffer?
        change(meetingID) { m in
            guard let i = m.segments.firstIndex(where: { $0.id == id }), m.segments[i].text != text else { return }
            let old = m.segments[i].text
            m.segments[i].text = text
            m.segments[i].edited = true
            Self.markRevised(id, in: &m)
            if let term = TermMatcher.changedTerm(from: old, to: text) {
                let count = m.occurrences(of: term.from, correctedTo: term.to).count
                if count > 0 {
                    offer = CorrectionOffer(
                        meetingID: meetingID, from: term.from, to: term.to, count: count, inTranscript: true)
                }
            }
        }
        correctionOffer = offer
    }
    /// Deletes a line, such as speech invented for noise. Minutes citing it keep their other evidence.
    func removeSegment(_ meetingID: UUID, id: String) {
        change(meetingID) { m in
            m.segments.removeAll { $0.id == id }
            Self.markRevised(id, in: &m)
        }
        if editingSegment == id { editingSegment = nil }
    }
    /// Remembers a line corrected or deleted by hand, so minutes citing it are shown to need checking.
    private static func markRevised(_ id: String, in meeting: inout Meeting) {
        guard var notes = meeting.notes else { return }
        notes.revisedSegmentIDs = (notes.revisedSegmentIDs ?? []).union([id])
        meeting.notes = notes
    }
    /// Keeps the minutes as they are after lines they cite were corrected: the items are no longer marked.
    func keepMinutesDespiteRevisions(_ meetingID: UUID) {
        change(meetingID) { $0.notes?.revisedSegmentIDs = nil }
    }
    /// The meeting's 録音.m4a, for listening back, once recording is over and it has been made.
    func recordingFile(_ meeting: Meeting) -> URL? {
        guard meeting.id != activeID, meeting.capture != .recording else { return nil }
        let url = folder(meeting.id).appendingPathComponent(AudioMixdown.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// Plays one utterance from the meeting's recording, or stops it when it is playing.
    func play(_ segment: Segment, in meetingID: UUID) {
        guard let meeting = meetings.first(where: { $0.id == meetingID }), let file = recordingFile(meeting) else {
            return
        }
        do { try player.toggle(segment, in: meeting.segments, file: file) } catch {
            self.error = error.localizedDescription
        }
    }
    @discardableResult func addNoteItem(_ meetingID: UUID, part: NotePart, text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, meetings.first(where: { $0.id == meetingID })?.notes != nil else { return nil }
        let id = "user-" + UUID().uuidString
        change(meetingID) { m in
            m.notes?.content[part].append(NoteItem(id: id, text: text, evidence: [], edited: true))
            if let notes = m.notes { m.minutes = MinutesEngine.render(notes, segments: m.segments) }
        }
        return id
    }
    /// Deletes an item. One the AI wrote is remembered, so a later update does not bring it back.
    func removeNoteItem(_ meetingID: UUID, part: NotePart, id: String) {
        change(meetingID) { m in
            guard let item = m.notes?.content[part].first(where: { $0.id == id }) else { return }
            m.notes?.content[part].removeAll { $0.id == id }
            if !id.hasPrefix("user-") {
                let dismissed = (m.notes?.dismissed ?? []) + [MinutesEngine.normalized(item.text)]
                m.notes?.dismissed = dismissed
            }
            if let notes = m.notes { m.minutes = MinutesEngine.render(notes, segments: m.segments) }
        }
        if editingNoteItem == part.rawValue + "/" + id { editingNoteItem = nil }
    }
    /// Fixes the chosen occurrences of a misheard word, and optionally adds the right spelling to the vocabulary.
    func applyCorrection(
        _ meetingID: UUID, occurrences: [TermOccurrence], to replacement: String, addToVocabulary: Bool
    ) {
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !occurrences.isEmpty, !replacement.isEmpty else { return }
        var learnt: [String] = []
        change(meetingID) { m in
            learnt = m.correct(occurrences, to: replacement).variants
            if let notes = m.notes { m.minutes = MinutesEngine.render(notes, segments: m.segments) }
        }
        // Fixed once, fixed in every meeting from now on: the misheard spellings are learned.
        learnedWords = LearnedWords.learning(learnt, to: replacement, in: learnedWords)
        if addToVocabulary && !TranscriptionHints.terms(vocabulary).contains(replacement) {
            vocabulary += (vocabulary.isEmpty || vocabulary.hasSuffix("\n") ? "" : "\n") + replacement
        }
        correctionOffer = nil
    }
    /// The offer's "fix them all": every occurrence, same spelling or same reading.
    func applyOfferedCorrection() {
        guard let offer = correctionOffer, let meeting = meetings.first(where: { $0.id == offer.meetingID }) else {
            return
        }
        applyCorrection(
            offer.meetingID, occurrences: meeting.occurrences(of: offer.from, correctedTo: offer.to), to: offer.to,
            addToVocabulary: true)
    }
    func undoCorrection(_ meetingID: UUID, _ id: UUID) {
        change(meetingID) { m in
            // A learned word undone here is not applied to this meeting again; other meetings keep using it.
            if let learned = m.corrections.first(where: { $0.id == id && $0.learned == true }) {
                m.ignoredLearned = (m.ignoredLearned ?? []) + [learned.to]
            }
            m.undo(id)
            if let notes = m.notes { m.minutes = MinutesEngine.render(notes, segments: m.segments) }
        }
    }
}

// MARK: - Agenda

extension Store {
    /// Prepares a meeting: it waits in the list, with its agenda, until 録音を開始. Its title is edited in place.
    func planMeeting() {
        guard ready else { return }
        let meeting = newMeeting(capture: .planned)
        meetings.insert(meeting, at: 0)
        showNewMeeting()
        selected = meeting.id
        addingAgenda = meeting.id  // Ready to type or paste the agenda.
        Task { try? await checkpoint(meeting.id) }
    }
    /// Renames a meeting; 議事録.md follows on the next save. A blank title keeps the old one, and the folder keeps
    /// its name, so files open in Finder stay where they are.
    func renameMeeting(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            .joined(separator: " ")
        guard !title.isEmpty, let meeting = meetings.first(where: { $0.id == id }), meeting.title != title else {
            return
        }
        change(id) { $0.title = title }
    }
    func renamePlannedMeeting(_ id: UUID, to title: String) {
        guard meetings.first(where: { $0.id == id })?.capture == .planned else { return }
        change(id) { $0.title = title }
    }
    /// Adds the topics in typed or pasted text, one per line.
    func addAgenda(_ text: String, to id: UUID) {
        let items = MeetingAgenda.parse(text)
        guard !items.isEmpty else { return }
        change(id) { $0.agenda += items }
    }
    func updateAgendaItem(_ item: UUID, in id: UUID, _ update: (inout AgendaItem) -> Void) {
        change(id) { meeting in
            guard let index = meeting.agenda.firstIndex(where: { $0.id == item }) else { return }
            update(&meeting.agenda[index])
        }
    }
    func removeAgendaItem(_ item: UUID, from id: UUID) {
        change(id) { $0.agenda.removeAll { $0.id == item } }
    }
    func moveAgendaItem(_ item: UUID, in id: UUID, by offset: Int) {
        change(id) { meeting in
            guard let index = meeting.agenda.firstIndex(where: { $0.id == item }),
                meeting.agenda.indices.contains(index + offset)
            else { return }
            meeting.agenda.swapAt(index, index + offset)
        }
    }
    /// The minutes model's judgment of the topic being discussed, applied while the meeting is recorded.
    func followAgenda(_ id: UUID, _ topic: AgendaTopic) {
        guard id == activeID else { return }
        change(id) { $0.agenda = MeetingAgenda.follow($0.agenda, topic) }
    }
}

// MARK: - MCP

extension Store {
    /// Opens or closes the local MCP socket to match the setting. Only the app itself (not tests) serves it.
    func updateMCPServer() {
        guard persistsSettings else { return }
        if mcpEnabled, mcpServer == nil {
            let server = MCPSocketServer(path: MCPPaths.socket.path) { [unowned self] in MCPHandler(store: self) }
            server.onConnectionsChanged = { [weak self] count in self?.mcpConnections = count }
            do {
                try server.start()
                mcpServer = server
                mcpProblem = nil
            } catch {
                mcpProblem = error.localizedDescription
            }
        } else if !mcpEnabled, let server = mcpServer {
            server.stop()
            mcpServer = nil
            mcpConnections = 0
        }
    }
    func stopMCPServer() {
        mcpServer?.stop()
        mcpServer = nil
    }
    func recordMCPAccess(client: String, tool: String, detail: String) {
        mcpAccesses.insert(MCPAccess(date: Date(), client: client, tool: tool, detail: detail), at: 0)
        if mcpAccesses.count > 50 { mcpAccesses.removeLast(mcpAccesses.count - 50) }
    }
    func toggleMCPHiddenTag(_ tag: String) {
        if MeetingTags.contains(mcpHiddenTags, tag) {
            mcpHiddenTags.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) }
        } else {
            mcpHiddenTags.append(tag)
        }
    }
}
/// What a decision, open issue or action carries when it is dragged to another topic: its meeting, section and id,
/// as tab-separated text that dropped text from elsewhere does not match.
struct NoteItemDrag: Equatable {
    let meetingID: UUID
    let part: NotePart
    let id: String
    init(meetingID: UUID, part: NotePart, id: String) {
        self.meetingID = meetingID
        self.part = part
        self.id = id
    }
    init?(payload: String) {
        let fields = payload.components(separatedBy: "\t")
        guard fields.count == 4, fields[0] == "gijilog-item", let meetingID = UUID(uuidString: fields[1]),
            let part = NotePart(rawValue: fields[2]), !fields[3].isEmpty
        else { return nil }
        self.init(meetingID: meetingID, part: part, id: fields[3])
    }
    var payload: String { ["gijilog-item", meetingID.uuidString, part.rawValue, id].joined(separator: "\t") }
}
