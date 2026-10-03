import Foundation

// Helpers that only the regression tests use. The app itself processes audio through ProcessingPipeline.
extension Processor {
    // Replays a saved recording through the same silence gate and recognition path as live processing.
    static func transcribe(folder: URL, key: String, progress: @escaping (String) async -> Void) async throws
        -> [Segment]
    {
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.json").path) {
            await progress("旧録音を再処理中（トラック間の開始時刻は不明）")
        }
        var all: [Segment] = []
        for input in try recordingInputs(folder: folder) {
            await progress("\(input.source) \(Int(input.offset))秒〜を文字起こし中")
            all.append(
                contentsOf: try await recognizeChunk(input.url, offset: input.offset, source: input.source, key: key))
        }
        return all.sorted { $0.time < $1.time }
    }
}

extension MinutesEngine {
    // A deterministic stand-in for the AI summary (and the former keyword-extraction mode) in tests.
    static func extract(_ segments: [Segment]) -> NotesDelta {
        func item(_ segment: Segment) -> NoteItem { NoteItem(id: "", text: segment.text, evidence: [segment.id]) }
        var delta = NotesDelta(summary: segments.prefix(5).map(item))
        delta.decisions = segments.filter { s in ["決定", "決まり", "合意", "にします"].contains { s.text.contains($0) } }
            .map(item)
        delta.unresolved = segments.filter { s in ["検討", "未定", "次回", "保留"].contains { s.text.contains($0) } }.map(item)
        delta.actions = segments.filter { s in ["対応", "お願い", "までに", "確認します"].contains { s.text.contains($0) } }
            .map(item)
        return delta
    }
    static let stubReview: ProcessingPipeline.Summarize = { state, _, _, _ in state }
    static let stubSummary: ProcessingPipeline.Summarize = { state, segments, _, _ in
        let batch = MinutesEngine.batch(segments, state: state)
        return MinutesEngine.merge(state, delta: MinutesEngine.extract(batch), batch: batch, segments: segments)
    }
}

// Fails any request that a test did not mock, so the regression tests can never reach the real API.
final class BlockNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(
            self, didFailWithError: AppError.message("unmocked network request: \(request.url?.absoluteString ?? "")"))
    }
    override func stopLoading() {}
}

extension Store {
    /// Waits for queued work, then writes pending checkpoints at once instead of waiting for the coalescing delay.
    func waitUntilIdle(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(pipeline.isIdle && !hasPendingWrites) {
            if Date() > deadline { throw AppError.message("処理キューの検証がタイムアウトしました。") }
            if pipeline.isIdle { await flushCheckpoints() } else { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
    }
    func savedMeeting(_ id: UUID) throws -> Meeting {
        try JSONDecoder().decode(
            Meeting.self, from: Data(contentsOf: folder(id).appendingPathComponent("meeting.json")))
    }
}
