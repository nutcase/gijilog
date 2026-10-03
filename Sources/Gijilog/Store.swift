import AVFoundation
import AppKit
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
    @Published var selected: UUID?
    @Published var recording = false
    @Published var busy = false  // Only capture setup/flush; AI processing does not block another meeting.
    @Published var ready = true
    @Published var status = "準備完了"
    @Published var error: String?
    @Published var tab = "議事録"
    @Published var title = ""
    @Published var deletion: Meeting?  // Awaiting confirmation in the UI.
    @Published var showsTranscript = true  // The live transcript panel beside the minutes.
    @Published var pinsLiveWindow = true  // Keep the compact live window above the video call.
    @Published var dropTargeted = false  // A file is being dragged over the window.
    // Once a meeting is complete and 録音.m4a exists, its chunks are only needed to reprocess per track.
    @Published var removesWorkingAudio = true {
        didSet { if persistsSettings { UserDefaults.standard.set(removesWorkingAudio, forKey: "removesWorkingAudio") } }
    }
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
    let repository: MeetingRepository
    private let persistsSettings: Bool
    var activeID: UUID?
    lazy var pipeline = ProcessingPipeline(store: self)
    private var captureInputID: String?  // The microphone in use, so unrelated devices cannot stop a recording.
    private var summaryTimer: Timer?
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
        if loadSettings {
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
                        || meeting.jobs.contains { $0.state == .pending || $0.state == .running }
                        || !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
                    guard needsRecovery else { continue }
                    do {
                        try await discoverJobs(id)
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
            // Only now are interrupted recordings marked and their audio found, so they get 録音.m4a on this launch.
            mixDown(meetings.filter { $0.capture != .recording && $0.hasAudio == true }.map(\.id), onlyMissing: true)
        } catch { self.error = error.localizedDescription }
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
    func start() async {
        guard ready, !recording, !busy, !shuttingDown else { return }
        guard hasKey else {
            error = "録音するには、設定でOpenAI APIキーを保存してください。"
            return
        }
        if !microphone.isEmpty && AVCaptureDevice(uniqueID: microphone) == nil {
            error = "設定で選んだマイクが見つかりません。接続を確認するか、設定でマイクを選び直してください。"
            return
        }
        busy = true
        pendingCaptureError = nil
        defer { busy = false }
        let untitled = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var meeting = Meeting(title: untitled ? "会議 \(Date().formatted(date: .numeric, time: .shortened))" : title)
        meeting.settings = settings
        meeting.folderName =
            MeetingRepository.uniqueFolder(
                in: root, name: meetingFolderName(date: meeting.date, title: untitled ? "会議" : meeting.title)
            ).lastPathComponent
        meetings.insert(meeting, at: 0)
        selected = meeting.id
        activeID = meeting.id
        captureInputID = microphone.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : microphone
        do {
            try await checkpoint(meeting.id)
            pipeline.resume(meeting.id, key: key)
            try await recorder.start(folder: folder(meeting.id), microphone: microphone.isEmpty ? nil : microphone)
            recording = true
            title = ""
            status = "録音中 — Mac音声＋マイク"
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "会議音声を録音中")
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateLiveSummary() }
            }
            summaryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            if shuttingDown || pendingCaptureError != nil {
                busy = false
                if let message = pendingCaptureError { await interrupt(message) } else { await stop() }
            }
        } catch {
            change(meeting.id) {
                $0.capture = .interrupted
                $0.captureError = error.localizedDescription
                $0.status = "録音開始失敗"
            }
            activeID = nil
            captureInputID = nil
            self.error = error.localizedDescription
            try? await checkpoint(meeting.id)
        }
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
        defer { busy = false }
        summaryTimer?.invalidate()
        summaryTimer = nil
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
        guard ready, !shuttingDown, let id = meetingID ?? selected, !busy, id != activeID, !isProcessing(id) else {
            return
        }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        guard hasKey else {
            error = "処理するには、設定でOpenAI APIキーを保存してください。"
            return
        }
        do {
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
                if rebuild || meeting.settings == nil {
                    meeting.settings = settings
                    meeting.notes = nil
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
        meeting.capture = .stopped
        meeting.hasAudio = true
        meeting.status = "録音ファイルを文字起こし中"
        meeting.jobs = chunks.map { chunk in
            let relative = "chunks/" + chunk.filename
            return TranscriptionJob(
                id: stableID(relative), filename: relative, offset: chunk.offset, source: chunk.source)
        }
        meetings.insert(meeting, at: meetings.firstIndex { $0.date < date } ?? meetings.count)
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
            && !pipeline.summaryFailed(meeting.id)
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
        if selected == id { selected = meetings.first?.id }
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
            !meeting.jobs.contains(where: { $0.state == .pending || $0.state == .running })
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
        pipeline.pause(terminal: true)
        recorder.cancelPendingStart()
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
    func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.exportFilename(meeting.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (MinutesEngine.document(meeting) ?? "# \(meeting.title)\n").write(
                to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = error.localizedDescription
        }
    }
    nonisolated static func exportFilename(_ title: String) -> String { fileSafeName(title, fallback: "議事録") + ".md" }
}
