import Foundation

// A bounded worker pool. The disk checkpoint, rather than a chain of Tasks, owns job state.
@MainActor final class ProcessingPipeline {
    typealias Recognize = (URL, Double, String, Bool, String) async throws -> [Segment]
    typealias Summarize = (MinutesState, [Segment], SessionSettings, String) async throws -> MinutesState
    private weak var store: Store?
    private var keys: [UUID: String] = [:]  // Credentials are never written into a meeting.
    private var allowed: Set<UUID> = []
    private var workers: [String: Task<Void, Never>] = [:]
    private var localWorkers: Set<String> = []
    private var requestedSummaries: Set<UUID> = []
    private var summaryTask: Task<Void, Never>?
    private var summarizingID: UUID?
    private var retryWake: Task<Void, Never>?
    private var suspended = false
    private var closing = false
    private var summaryFailures: Set<UUID> = []
    private var lastScheduledID: UUID?
    private var lastSummaryID: UUID?
    private let recognize: Recognize
    private let summarize: Summarize
    private let retryDelay: (Int) -> TimeInterval
    init(
        store: Store,
        recognize: @escaping Recognize = {
            try await Processor.recognizeChunk($0, offset: $1, source: $2, cloud: $3, key: $4)
        },
        summarize: @escaping Summarize = { try await MinutesEngine.update($0, segments: $1, settings: $2, key: $3) },
        retryDelay: @escaping (Int) -> TimeInterval = { pow(2, Double($0)) }
    ) {
        self.store = store
        self.recognize = recognize
        self.summarize = summarize
        self.retryDelay = retryDelay
    }
    func resume(_ id: UUID, key: String) {
        guard !closing else { return }
        suspended = false
        allowed.insert(id)
        keys[id] = key
        summaryFailures.remove(id)
        pump()
    }
    func requestSummary(_ id: UUID) {
        guard allowed.contains(id), !suspended else { return }
        guard !summaryFailures.contains(id) else { return }
        requestedSummaries.insert(id)
        pump()
    }
    func pause(terminal: Bool = false) {
        suspended = true
        closing = closing || terminal
        retryWake?.cancel()
        retryWake = nil
    }
    func isProcessing(_ id: UUID) -> Bool {
        workers.keys.contains { $0.hasPrefix(id.uuidString + "/") } || summarizingID == id
            || requestedSummaries.contains(id)
            || (!suspended && allowed.contains(id)
                && store?.meetings.first(where: { $0.id == id })?.jobs.contains(where: { $0.state == .pending }) == true)
    }
    func waitUntilIdle(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !workers.isEmpty || summaryTask != nil || retryWake != nil || !requestedSummaries.isEmpty
            || (store?.pendingWrites ?? 0) > 0
        {
            if Date() > deadline { throw AppError.message("処理キューの検証がタイムアウトしました。") }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func pump() {
        guard !suspended, let store else { return }
        retryWake?.cancel()
        retryWake = nil
        while workers.count < 2 {
            var candidate: (Meeting, TranscriptionJob)?
            var ordered = store.meetings.filter { allowed.contains($0.id) }
            if let i = ordered.firstIndex(where: { $0.id == lastScheduledID }) {
                ordered = Array(ordered.dropFirst(i + 1)) + Array(ordered.prefix(i + 1))
            }
            for meeting in ordered {
                let settings = meeting.settings ?? SessionSettings(mode: "local")
                if !settings.cloud && !localWorkers.isEmpty { continue }
                if let job = meeting.jobs.first(where: {
                    $0.state == .pending && ($0.retryAfter ?? .distantPast) <= Date()
                }) {
                    candidate = (meeting, job)
                    break
                }
            }
            guard let (meeting, job) = candidate else { break }
            lastScheduledID = meeting.id
            let token = meeting.id.uuidString + "/" + job.id
            let settings = meeting.settings ?? SessionSettings(mode: "local")
            let key = keys[meeting.id] ?? ""
            // Reserve synchronously so the next pump cannot schedule this job twice.
            store.change(meeting.id) { m in
                if let i = m.jobs.firstIndex(where: { $0.id == job.id }) {
                    m.jobs[i].state = .running
                    m.jobs[i].attempts += 1
                }
            }
            if !settings.cloud { localWorkers.insert(token) }
            workers[token] = Task { [weak self] in
                guard let self, let store = self.store else { return }
                do {
                    try await store.checkpoint(meeting.id)
                    let url = store.folder(meeting.id).appendingPathComponent(job.filename)
                    let result = try await self.recognize(url, job.offset, job.source, settings.cloud, key)
                    let segments = result.enumerated().map { index, segment in
                        Segment(
                            id: job.id + ":" + String(index), time: segment.time, source: segment.source,
                            text: segment.text)
                    }
                    store.change(meeting.id) { m in
                        m.segments.removeAll { $0.id.hasPrefix(job.id + ":") }
                        m.segments.append(contentsOf: segments)
                        m.segments.sort { $0.time < $1.time }
                        if let i = m.jobs.firstIndex(where: { $0.id == job.id }) {
                            m.jobs[i].state = .completed
                            m.jobs[i].lastError = nil
                            m.jobs[i].retryAfter = nil
                        }
                    }
                    try await store.checkpoint(meeting.id)
                } catch {
                    let retry = Processor.isRetryable(error)
                    store.change(meeting.id) { m in
                        if let i = m.jobs.firstIndex(where: { $0.id == job.id }) {
                            let again = retry && m.jobs[i].attempts < 3
                            m.jobs[i].state = again ? .pending : .failed
                            m.jobs[i].lastError = error.localizedDescription
                            m.jobs[i].retryAfter =
                                again ? Date().addingTimeInterval(self.retryDelay(m.jobs[i].attempts)) : nil
                        }
                    }
                    do { try await store.checkpoint(meeting.id) } catch {
                        store.error = error.localizedDescription
                        self.pause()
                    }
                }
                self.workers.removeValue(forKey: token)
                self.localWorkers.remove(token)
                self.pump()
            }
        }
        let wake = store.meetings.filter { allowed.contains($0.id) }.flatMap(\.jobs)
            .filter { $0.state == .pending && ($0.retryAfter ?? .distantPast) > Date() }.compactMap(\.retryAfter).min()
        if let wake {
            retryWake = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.01, wake.timeIntervalSinceNow) * 1_000_000_000))
                } catch { return }
                self?.retryWake = nil
                self?.pump()
            }
        }
        for meeting in store.meetings where allowed.contains(meeting.id) && meeting.capture != .recording {
            if !meeting.jobs.contains(where: { $0.state == .pending || $0.state == .running }) {
                if !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
                    && !summaryFailures.contains(meeting.id)
                {
                    requestedSummaries.insert(meeting.id)
                }
                store.refreshCompletion(meeting.id, summaryFailed: summaryFailures.contains(meeting.id))
            }
        }
        requestedSummaries = requestedSummaries.filter { id in
            guard let meeting = store.meetings.first(where: { $0.id == id }) else { return false }
            return !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
        }
        var summaryOrder = store.meetings.filter { requestedSummaries.contains($0.id) }
        if let i = summaryOrder.firstIndex(where: { $0.id == lastSummaryID }) {
            summaryOrder = Array(summaryOrder.dropFirst(i + 1)) + Array(summaryOrder.prefix(i + 1))
        }
        if summaryTask == nil, let id = summaryOrder.first?.id {
            lastSummaryID = id
            requestedSummaries.remove(id)
            if let meeting = store.meetings.first(where: { $0.id == id }),
                !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
            {
                summarizingID = id
                summaryTask = Task { [weak self] in
                    guard let self, let store = self.store else { return }
                    do {
                        var result: MinutesState?
                        for attempt in 1...3 {
                            do {
                                result = try await self.summarize(
                                    meeting.notes ?? MinutesState(), meeting.segments,
                                    meeting.settings ?? SessionSettings(mode: "local"), self.keys[id] ?? "")
                                break
                            } catch {
                                guard Processor.isRetryable(error), attempt < 3, !self.closing else { throw error }
                                try await Task.sleep(
                                    nanoseconds: UInt64(max(0.01, self.retryDelay(attempt)) * 1_000_000_000))
                            }
                        }
                        guard let notes = result else { throw AppError.message("議事録の更新に失敗しました。") }
                        // Only this task updates notes for this meeting; transcription may append newer utterances meanwhile.
                        store.change(id) { m in
                            m.notes = notes
                            m.minutes = MinutesEngine.render(notes, segments: m.segments)
                        }
                        try await store.checkpoint(id)
                    } catch {
                        self.summaryFailures.insert(id)
                        requestedSummaries.remove(id)
                        store.error = error.localizedDescription
                    }
                    self.summaryTask = nil
                    self.summarizingID = nil
                    self.pump()
                }
            }
        }
        store.refreshProcessingCounts()
    }
}
