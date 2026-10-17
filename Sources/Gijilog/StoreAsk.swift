import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

// ギジログAI: questions about the meetings, and following an answer's links into a meeting's transcript.
extension Store {
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
        askGeneration += 1
        let generation = askGeneration
        let stream = askStream
        stream.progress = "考えています"
        stream.draft = ""
        askTask = Task {
            var outcome: [AskMessage] = []
            do {
                let answer = try await MeetingAgent.answer(
                    conversation, instructions: instructions, model: model,
                    send: { try await MeetingAgent.stream($0, key: key, text: $1) },
                    run: { MeetingAgent.text(ofTool: tools.callTool($0, arguments: $1)) },
                    progress: { [weak self] in if self?.askGeneration == generation { stream.progress = $0 } },
                    writing: { [weak self] text in
                        guard self?.askGeneration == generation else { return }
                        stream.draft = text
                        if !text.isEmpty { stream.progress = "答えを書いています" }
                    })
                outcome = [AskMessage(role: .answer, text: answer)]
            } catch {
                let stopped = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                // What was written before it stopped stays, marked as unfinished.
                if !stream.draft.isEmpty {
                    outcome.append(AskMessage(role: .answer, text: stream.draft + "\n\n（ここまでで止まりました）"))
                }
                if !stopped || stream.draft.isEmpty {
                    outcome.append(AskMessage(role: .failure, text: stopped ? "止めました。" : error.localizedDescription))
                }
            }
            // A conversation started again meanwhile has nothing to do with this answer.
            guard askGeneration == generation else { return }
            asked += outcome
            stream.draft = ""
            stream.progress = nil
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
    /// Starts a new conversation. An answer still being written is stopped and dropped, not added to the new one.
    func clearAsked() {
        askTask?.cancel()
        askTask = nil
        askGeneration += 1
        askStream.progress = nil
        askStream.draft = ""
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
        // The utterance under way at that moment, or the first one after it; a link to the whole meeting marks none.
        let ordered = meeting.segments.sorted { $0.time < $1.time }
        if let seconds = link.seconds, let segment = ordered.last(where: { $0.time <= seconds + 1 }) ?? ordered.first {
            reveal(segment.id, in: meeting.id)
        } else {
            revealed = nil
        }
        return true
    }
    /// Shows an utterance in the transcript and marks it: beside the minutes in the full window, or on the
    /// transcript's tab in the compact one. Asked for again, even the same one, it is scrolled to again.
    func reveal(_ segmentID: String, in meetingID: UUID, compact: Bool = false) {
        revealed = Reveal(
            meetingID: meetingID, segmentID: segmentID, compact: compact, count: (revealed?.count ?? 0) + 1)
        if compact {
            liveTab = "文字起こし"
        } else {
            showsTranscript = true
            if transcriptFind.open { transcriptFind = FindState() }  // Its match would hold the panel where it is.
        }
    }
    /// The compact window's transcript follows the speech again once its tabs are switched by hand.
    func forgetCompactReveal() {
        if revealed?.compact == true { revealed = nil }
    }
}
