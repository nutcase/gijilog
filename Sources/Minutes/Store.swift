import AVFoundation
import AppKit
import SwiftUI

@MainActor final class Store: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selected: UUID?
    @Published var recording = false
    @Published var busy = false  // Only capture setup/flush; AI processing does not block another meeting.
    @Published var ready = true
    @Published var status = "準備完了"
    @Published var error: String?
    @Published var level: Float = 0
    @Published var tab = "議事録"
    @Published var title = ""
    @Published var processingMode = "hybrid"
    var cloud: Bool { processingMode == "cloud" }
    var cloudSummary: Bool { processingMode != "local" }
    @Published var key = ""
    @Published var model = "gpt-6-sol"
    @Published var localModel = ""
    @Published var microphone = ""
    @Published var pendingChunks = 0
    @Published var liveFailures = 0
    @Published private(set) var preparingIDs: Set<UUID> = []
    let recorder: Recorder
    let root: URL
    let repository: MeetingRepository
    var activeID: UUID?
    lazy var pipeline = ProcessingPipeline(store: self)
    private var summaryTimer: Timer?
    private var activity: NSObjectProtocol?
    private var shuttingDown = false
    private var pendingCaptureError: String?
    private var observers: [NSObjectProtocol] = []
    private(set) var pendingWrites = 0
    var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
    }
    init(root: URL? = nil, recorder: Recorder = Recorder(), loadSettings: Bool = true) {
        self.recorder = recorder
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes/Meetings")
        repository = MeetingRepository(root: self.root)
        if loadSettings {
            localModel = UserDefaults.standard.string(forKey: "localSummaryModel") ?? ""
            key = KeyStore.read()
            let savedModel = UserDefaults.standard.string(forKey: "summaryModel")
            model = savedModel == "gpt-4.1-mini" ? "gpt-6-sol" : (savedModel ?? model)
            ready = false
            Task { await recover() }
        }
        recorder.onError = { [weak self] message in
            Task { @MainActor in await self?.interrupt(message) }
        }
        recorder.onChunk = { [weak self] url, offset, source in
            await self?.enqueueChunk(url, offset: offset, source: source)
        }
        recorder.onLevel = { [weak self] value in Task { @MainActor in self?.level = value } }
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
                    let id = (note.object as? AVCaptureDevice)?.uniqueID
                    Task { @MainActor in
                        guard let self, self.microphone.isEmpty || self.microphone == id else { return }
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
    var settings: SessionSettings { SessionSettings(mode: processingMode, model: model, localModel: localModel) }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    func change(_ id: UUID, _ update: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        update(&meetings[i])
    }
    func persist(_ meeting: Meeting) async throws { try await repository.save(meeting) }
    func checkpoint(_ id: UUID) async throws {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].revision += 1
        try await repository.save(meetings[i])
    }
    func recover() async {
        defer { ready = true }
        do {
            let (saved, failures) = try await repository.load()
            meetings = saved
            selected = meetings.first?.id
            if !failures.isEmpty { error = "一部の会議を読み込めませんでした。保存場所のデータは保持しています。\n" + failures.joined(separator: "\n") }
            for id in meetings.map(\.id) {
                guard let meeting = meetings.first(where: { $0.id == id }) else { continue }
                let interrupted = meeting.capture == .recording
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
                if let settings = meeting.settings {
                    let needsRecovery =
                        interrupted || meeting.notes == nil
                        || meeting.jobs.contains { $0.state == .pending || $0.state == .running }
                        || !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
                    guard needsRecovery else { continue }
                    do {
                        try await discoverJobs(id)
                        if !settings.cloudSummary || !key.isEmpty {
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
        if cloudSummary && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = "クラウド要約には設定でOpenAI APIキーを入力してください。"
            return
        }
        busy = true
        pendingCaptureError = nil
        defer { busy = false }
        var meeting = Meeting(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "会議 \(Date().formatted(date: .numeric, time: .shortened))" : title)
        meeting.settings = settings
        meetings.insert(meeting, at: 0)
        selected = meeting.id
        activeID = meeting.id
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
            self.error = error.localizedDescription
            try? await checkpoint(meeting.id)
        }
    }
    func enqueueChunk(_ url: URL, offset: Double, source: String) async {
        guard let id = activeID else { return }
        let relative = "chunks/" + url.lastPathComponent
        change(id) { meeting in
            if !meeting.jobs.contains(where: { $0.filename == relative }) {
                meeting.jobs.append(
                    TranscriptionJob(id: stableID(relative), filename: relative, offset: offset, source: source))
                meeting.jobs.sort { $0.offset < $1.offset }
            }
        }
        do {
            try await checkpoint(id)
            pipeline.pump()
        } catch {
            self.error = error.localizedDescription
            // Do not await stop inside a delivery callback: stop waits for deliveries itself.
            Task { await interrupt("処理状態を保存できませんでした。録音を停止します。") }
        }
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
        level = 0
        do { try await recorder.stop() } catch {
            change(id) { $0.captureError = error.localizedDescription }
            self.error = error.localizedDescription
        }
        activeID = nil
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
        status = "録音を停止しました。残りはバックグラウンドで処理します。次の録音を開始できます。"
        pipeline.requestSummary(id)
        pipeline.pump()
    }
    func process(rebuild: Bool = false) async {
        guard ready, !shuttingDown, let id = selected, !busy, id != activeID, !isProcessing(id) else { return }
        preparingIDs.insert(id)
        defer { preparingIDs.remove(id) }
        let chosen = rebuild ? settings : (meetings.first { $0.id == id }?.settings ?? settings)
        guard !chosen.cloudSummary || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "設定でOpenAI APIキーを入力してください。"
            return
        }
        do {
            if let old = meetings.first(where: { $0.id == id }), rebuild || old.settings == nil {
                try await repository.backup(old)
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
            pipeline.requestSummary(id)
        } catch { self.error = error.localizedDescription }
    }
    func isProcessing(_ id: UUID) -> Bool { preparingIDs.contains(id) || pipeline.isProcessing(id) }
    func refreshProcessingCounts() {
        pendingChunks = meetings.flatMap(\.jobs).filter { $0.state == .pending || $0.state == .running }.count
        liveFailures = meetings.flatMap(\.jobs).filter { $0.state == .failed }.count
        if recording { status = "録音中 · 文字起こし待機 \(pendingChunks)件 / 要約は30秒ごとに更新" }
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
            result =
                "完了・\(meeting.settings?.cloud == true ? "クラウド" : (meeting.settings?.cloudSummary == true ? "Mac内認識＋クラウド要約" : "端末内"))"
        }
        guard meeting.status != result else { return }
        change(id) { $0.status = result }
        pendingWrites += 1
        Task {
            defer { pendingWrites -= 1 }
            do { try await checkpoint(id) } catch { self.error = error.localizedDescription }
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
        for id in meetings.map(\.id) {
            do { try await checkpoint(id) } catch { self.error = error.localizedDescription }
        }
        await repository.flush()
    }
    func saveSettings() {
        do {
            try KeyStore.save(key)
            UserDefaults.standard.set(model, forKey: "summaryModel")
            UserDefaults.standard.set(localModel, forKey: "localSummaryModel")
            status = "設定を保存しました"
        } catch { self.error = error.localizedDescription }
    }
    func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "議事録.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let transcript = meeting.segments.map { "[\(Int($0.time))秒 / \($0.source)] \($0.text)" }.joined(
            separator: "\n\n")
        let minutes =
            meeting.notes.map { MinutesEngine.render($0, segments: meeting.segments, transcript: transcript) }
            ?? "## 文字起こし\n\n\(transcript)\n\n\(meeting.minutes)"
        do { try "# \(meeting.title)\n\n\(minutes)".write(to: url, atomically: true, encoding: .utf8) } catch {
            self.error = error.localizedDescription
        }
    }
}
