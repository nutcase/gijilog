import Foundation

// A bounded worker pool. The disk checkpoint, rather than a chain of Tasks, owns job state.
@MainActor final class ProcessingPipeline {
    typealias Recognize = (URL, Double, String, String, TranscriptionHints) async throws -> [Segment]
    typealias Summarize = (MinutesState, [Segment], SessionSettings, String) async throws -> MinutesState
    private weak var store: Store?
    private var keys: [UUID: String] = [:]  // Credentials are never written into a meeting.
    private var allowed: Set<UUID> = []
    private var workers: [String: Task<Void, Never>] = [:]
    private var requestedSummaries: Set<UUID> = []
    private var summaryTask: Task<Void, Never>?
    private var summarizingID: UUID?
    private var retryWake: Task<Void, Never>?
    private var suspended = false
    private var closing = false
    // Consecutive summary failures per meeting. Live (timer) requests back off after a failure;
    // stop and resume retry at once. Automatic re-requests stay off until a summary succeeds.
    private var summaryFailures: [UUID: Int] = [:]
    private var summaryRetryAt: [UUID: Date] = [:]
    private var summaryErrors: [UUID: String] = [:]
    private var lastScheduledID: UUID?
    private var lastSummaryID: UUID?
    private let recognize: Recognize
    private let summarize: Summarize
    private let review: Summarize
    private let retryDelay: (Int) -> TimeInterval
    init(
        store: Store,
        review: Summarize? = nil,
        recognize: @escaping Recognize = {
            try await Processor.recognizeChunk($0, offset: $1, source: $2, key: $3, hints: $4)
        },
        summarize: @escaping Summarize = { try await MinutesEngine.update($0, segments: $1, settings: $2, key: $3) },
        retryDelay: @escaping (Int) -> TimeInterval = { min(60, pow(2, Double($0))) }
    ) {
        self.store = store
        self.recognize = recognize
        self.summarize = summarize
        self.review = review ?? { try await MinutesEngine.review($0, segments: $1, settings: $2, key: $3) }
        self.retryDelay = retryDelay
    }
    func resume(_ id: UUID, key: String) {
        guard !closing else { return }
        suspended = false
        allowed.insert(id)
        keys[id] = key
        summaryFailures[id] = nil
        summaryRetryAt[id] = nil
        summaryErrors[id] = nil
        pump()
    }
    func requestSummary(_ id: UUID, force: Bool = false) {
        guard allowed.contains(id), !suspended else { return }
        if !force, let retryAt = summaryRetryAt[id], retryAt > Date() { return }
        summaryRetryAt[id] = nil
        requestedSummaries.insert(id)
        pump()
    }
    func summaryFailed(_ id: UUID) -> Bool { summaryFailures[id] != nil }
    /// Why the last minutes update for the meeting failed, while it keeps failing.
    func summaryError(_ id: UUID) -> String? { summaryErrors[id] }
    func isSummarizing(_ id: UUID) -> Bool { summarizingID == id }
    func forget(_ id: UUID) {
        allowed.remove(id)
        keys[id] = nil
        summaryFailures[id] = nil
        summaryRetryAt[id] = nil
        summaryErrors[id] = nil
        requestedSummaries.remove(id)
    }
    func pause(terminal: Bool = false) {
        suspended = true
        closing = closing || terminal
        retryWake?.cancel()
        retryWake = nil
    }
    var isIdle: Bool { workers.isEmpty && summaryTask == nil && retryWake == nil && requestedSummaries.isEmpty }
    func isProcessing(_ id: UUID) -> Bool {
        workers.keys.contains { $0.hasPrefix(id.uuidString + "/") } || summarizingID == id
            || requestedSummaries.contains(id)
            || (!suspended && allowed.contains(id)
                && store?.meetings.first(where: { $0.id == id })?.jobs.contains(where: { $0.state == .pending }) == true)
    }
    private func needsSummary(_ meeting: Meeting) -> Bool {
        !MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
            || (meeting.finalReviewPending == true && meeting.capture != .recording && !meeting.segments.isEmpty
                && !meeting.jobs.contains { $0.state == .pending || $0.state == .running })
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
            let key = keys[meeting.id] ?? ""
            let hints = TranscriptionHints(
                meeting: meeting, before: job.offset, vocabulary: store.hintVocabulary(for: meeting))
            // Reserve synchronously so the next pump cannot schedule this job twice.
            // Job progress is persisted by the store's coalesced checkpoints; a crash re-runs only the latest jobs.
            store.change(meeting.id) { m in
                if let i = m.jobs.firstIndex(where: { $0.id == job.id }) {
                    m.jobs[i].state = .running
                    m.jobs[i].attempts += 1
                }
            }
            workers[token] = Task { [weak self] in
                guard let self, let store = self.store else { return }
                do {
                    let url = store.folder(meeting.id).appendingPathComponent(job.filename)
                    let result = try await self.recognize(url, job.offset, job.source, key, hints)
                    let segments = result.enumerated().map { index, segment in
                        Segment(
                            id: job.id + ":" + String(index), time: segment.time, source: segment.source,
                            text: segment.text)
                    }
                    let learned = store.learned
                    store.change(meeting.id) { m in
                        m.segments.removeAll { $0.id.hasPrefix(job.id + ":") }
                        // Words the user corrected earlier in the meeting are corrected in new speech too, and so are
                        // words learned from fixes in earlier meetings.
                        m.segments.append(
                            contentsOf: segments.map { segment in
                                var segment = segment
                                segment.text = m.corrected(segment.text)
                                m.applyLearned(learned, to: &segment)
                                return segment
                            })
                        m.segments.sort { $0.time < $1.time }
                        if m.finalReviewPending != nil {
                            m.finalReviewPending = true
                            m.notes?.reviewedSegmentIDs = nil
                            m.notes?.finalizedAt = nil
                        }
                        if let i = m.jobs.firstIndex(where: { $0.id == job.id }) {
                            m.jobs[i].state = .completed
                            m.jobs[i].lastError = nil
                            m.jobs[i].retryAfter = nil
                        }
                    }
                } catch {
                    let retry = Processor.isRetryable(error)
                    store.change(meeting.id) { m in
                        if let i = m.jobs.firstIndex(where: { $0.id == job.id }) {
                            let again = retry && m.jobs[i].attempts < Processor.maxAttempts
                            m.jobs[i].state = again ? .pending : .failed
                            m.jobs[i].lastError = error.localizedDescription
                            m.jobs[i].retryAfter =
                                again
                                ? Date().addingTimeInterval(
                                    Processor.retryDelay(
                                        after: error, attempt: m.jobs[i].attempts, base: self.retryDelay))
                                : nil
                        }
                    }
                }
                self.workers.removeValue(forKey: token)
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
                if needsSummary(meeting) && summaryFailures[meeting.id] == nil {
                    requestedSummaries.insert(meeting.id)
                }
                store.refreshCompletion(meeting.id, summaryFailed: summaryFailures[meeting.id] != nil)
            }
        }
        requestedSummaries = requestedSummaries.filter { id in
            guard let meeting = store.meetings.first(where: { $0.id == id }) else { return false }
            return needsSummary(meeting)
        }
        var summaryOrder = store.meetings.filter { requestedSummaries.contains($0.id) }
        if let i = summaryOrder.firstIndex(where: { $0.id == lastSummaryID }) {
            summaryOrder = Array(summaryOrder.dropFirst(i + 1)) + Array(summaryOrder.prefix(i + 1))
        }
        if summaryTask == nil, let id = summaryOrder.first?.id {
            lastSummaryID = id
            requestedSummaries.remove(id)
            if let meeting = store.meetings.first(where: { $0.id == id }),
                needsSummary(meeting)
            {
                let reviewing = MinutesEngine.batch(meeting.segments, state: meeting.notes ?? MinutesState()).isEmpty
                summarizingID = id
                summaryTask = Task { [weak self] in
                    guard let self, let store = self.store else { return }
                    do {
                        var result: MinutesState?
                        // While recording, the update also judges which agenda topic is being discussed; the final
                        // review organizes the minutes by the agenda's topics.
                        var previous = meeting.notes ?? MinutesState()
                        if reviewing || meeting.capture == .recording { previous.agenda = meeting.agenda }
                        previous.corrections = meeting.corrections
                        for attempt in 1...3 {
                            do {
                                let operation = reviewing ? self.review : self.summarize
                                result = try await operation(
                                    previous, meeting.segments, meeting.settings ?? SessionSettings(),
                                    self.keys[id] ?? "")
                                break
                            } catch {
                                guard Processor.isRetryable(error), attempt < 3, !self.closing else { throw error }
                                let delay = Processor.retryDelay(after: error, attempt: attempt, base: self.retryDelay)
                                try await Task.sleep(nanoseconds: UInt64(max(0.01, delay) * 1_000_000_000))
                            }
                        }
                        guard var notes = result else { throw AppError.message("議事録の更新に失敗しました。") }
                        let topic = notes.topic
                        notes.agenda = []
                        notes.topic = nil
                        notes.corrections = []
                        if let topic { store.followAgenda(id, topic) }
                        // A failed chunk can be retried while a review request is in flight. Never publish that stale review.
                        if reviewing, let current = store.meetings.first(where: { $0.id == id }),
                            current.segments != meeting.segments
                                || current.jobs.contains(where: { $0.state == .pending || $0.state == .running })
                        {
                            self.summaryTask = nil
                            self.summarizingID = nil
                            self.pump()
                            return
                        }
                        if reviewing {
                            let batch = MinutesEngine.reviewBatch(
                                meeting.segments, state: meeting.notes ?? MinutesState())
                            notes.reviewedSegmentIDs = (meeting.notes?.reviewedSegmentIDs ?? []).union(batch.map(\.id))
                            if MinutesEngine.reviewBatch(meeting.segments, state: notes).isEmpty {
                                notes.finalizedAt = Date()
                            }
                        }
                        // Only this task updates notes for this meeting; transcription may append newer utterances meanwhile.
                        store.change(id) { m in
                            m.notes = m.corrected(notes)
                            if reviewing { m.finalReviewPending = notes.finalizedAt == nil }
                            m.minutes = MinutesEngine.render(m.notes ?? notes, segments: m.segments)
                        }
                        try await store.checkpoint(id)
                        self.summaryFailures[id] = nil
                        self.summaryErrors[id] = nil
                    } catch {
                        let failures = (self.summaryFailures[id] ?? 0) + 1
                        self.summaryFailures[id] = failures
                        self.summaryRetryAt[id] = Date().addingTimeInterval(min(300, 30 * pow(2, Double(failures - 1))))
                        requestedSummaries.remove(id)
                        // Shown in the meeting's own notice, not an alert: this is background work, and an alert
                        // would pull windows forward, possibly during another meeting.
                        self.summaryErrors[id] = error.localizedDescription
                        store.objectWillChange.send()
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
