import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

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
        var offers: [CorrectionOffer] = []
        var offersCorrection = offersCorrection
        change(meetingID) { m in
            guard var item = m.notes?.content[part].first(where: { $0.id == id }),
                let i = m.notes?.content[part].firstIndex(where: { $0.id == id })
            else { return }
            let before = item
            update(&item)
            // Among the topics the minutes show: a cancelled one is no place to move to.
            if part != .summary, item.text != before.text,
                let summary = m.notes?.content.summary.filter({ $0.state != .cancelled })
            {
                let current = MinutesEngine.topicIndex(of: before, in: summary, known: m.segments.byID)
                if let topic = MinutesEngine.topicNamedByEdit(
                    from: before.text, to: item.text, current: current, summary: summary)
                {
                    item.topic = topic
                    item.topicID = summary.first { MinutesEngine.summaryTopic($0.text) == topic }?.id
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
                for term in TermMatcher.changedTerms(from: old, to: new)
                where !offers.contains(where: { $0.from == term.from }) {
                    let count = m.occurrences(of: term.from, correctedTo: term.to).count
                    if count > 0 {
                        offers.append(CorrectionOffer(meetingID: meetingID, from: term.from, to: term.to, count: count))
                    }
                }
            }
        }
        offerCorrections(offers)
    }
    /// Moves a decision, open issue or action by hand under the summary topic with that ID, where AI updates then keep
    /// it. Topics are found among those the minutes show, not cancelled ones; two of the same name stay apart.
    func moveNoteItem(_ meetingID: UUID, part: NotePart, id: String, toTopic topicID: String) {
        guard part != .summary, let meeting = meetings.first(where: { $0.id == meetingID }),
            let summary = meeting.notes?.content.summary.filter({ $0.state != .cancelled }),
            let target = summary.firstIndex(where: { $0.id == topicID }),
            let item = meeting.notes?.content[part].first(where: { $0.id == id })
        else { return }
        guard MinutesEngine.topicIndex(of: item, in: summary, known: meeting.segments.byID) != target else { return }
        updateNoteItem(meetingID, part: part, id: id, offersCorrection: false) {
            $0.topic = MinutesEngine.topicName(summary[target])
            $0.topicID = topicID
        }
    }
    /// An item dropped on a topic after being dragged from the minutes: it moves when what was dropped is that item's
    /// text, so text dragged in from elsewhere (or left from a drag that was given up) moves nothing.
    @discardableResult func dropNoteItem(_ texts: [String], on topicID: String, in meetingID: UUID, part: NotePart)
        -> Bool
    {
        guard let drag = draggedNoteItem, drag.meetingID == meetingID, drag.part == part,
            let item = meetings.first(where: { $0.id == meetingID })?.notes?.content[part].first(where: {
                $0.id == drag.id
            }),
            texts.contains(item.text)
        else { return false }
        draggedNoteItem = nil
        moveNoteItem(meetingID, part: part, id: drag.id, toTopic: topicID)
        return true
    }
    /// The transcript can be corrected whenever it exists, also during the recording: transcription only adds
    /// lines, and the minutes refer to lines by ID.
    func canEditTranscript(_ meeting: Meeting) -> Bool {
        meeting.capture != .planned && !meeting.segments.isEmpty
    }
    /// Corrects one line of the transcript. When the change fixed a word that appears elsewhere in the meeting,
    /// offers to fix it there too.
    func updateSegment(_ meetingID: UUID, id: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var offers: [CorrectionOffer] = []
        change(meetingID) { m in
            guard let i = m.segments.firstIndex(where: { $0.id == id }), m.segments[i].text != text else { return }
            let old = m.segments[i].text
            m.segments[i].text = text
            m.segments[i].edited = true
            Self.markRevised(id, in: &m)
            // Each word the edit changed, one offer at a time.
            for term in TermMatcher.changedTerms(from: old, to: text) {
                let count = m.occurrences(of: term.from, correctedTo: term.to).count
                if count > 0 {
                    offers.append(
                        CorrectionOffer(
                            meetingID: meetingID, from: term.from, to: term.to, count: count, inTranscript: true))
                }
            }
        }
        offerCorrections(offers)
    }
    /// Offers to fix each changed word elsewhere too, one after another: the next shows once one is answered.
    func offerCorrections(_ offers: [CorrectionOffer]) {
        pendingOffers = Array(offers.dropFirst())
        correctionOffer = offers.first
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
        guard var notes = meeting.notes else {
            // No minutes yet: the first ones take the mark, if they were written from the line as it was.
            meeting.revisedBeforeMinutes = (meeting.revisedBeforeMinutes ?? []).union([id])
            return
        }
        notes.revisedSegmentIDs = (notes.revisedSegmentIDs ?? []).union([id])
        meeting.notes = notes
    }
    /// Keeps the minutes as they are after lines they cite were corrected: the items are no longer marked.
    func keepMinutesDespiteRevisions(_ meetingID: UUID) {
        change(meetingID) {
            $0.notes?.revisedSegmentIDs = nil
            $0.notes?.uncheckedItemIDs = nil
        }
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
