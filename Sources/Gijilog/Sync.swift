import Foundation

// Macs sharing a save location through a sync service (iCloud Drive and the like) each write meeting.json, and the
// service keeps whichever arrived last. To tell which version is the later one, each meeting carries how many times
// each Mac has saved it. A version that arrives is compared by those counts: one that has every save this Mac knows
// of, and more, is newer and is taken in; one missing saves this Mac has is older and is refused; one with saves of
// its own while missing some of this Mac's was changed on two Macs at once, and both versions are kept.

/// How many times each Mac (Store.thisMac) has saved a meeting. A file written before these counts existed counts as
/// one Mac, "legacy", with its save count.
struct SaveCounts: Codable, Equatable {
    var counts: [String: UInt64]
    static let legacy = "legacy"
    init(_ counts: [String: UInt64] = [:]) { self.counts = counts }
    init(from decoder: Decoder) throws { counts = try decoder.singleValueContainer().decode([String: UInt64].self) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counts)
    }
    static func of(_ meeting: Meeting) -> SaveCounts { meeting.saveCounts ?? SaveCounts([legacy: meeting.revision]) }
    /// Whether this version has every save the other has.
    func includes(_ other: SaveCounts) -> Bool { other.counts.allSatisfy { counts[$0.key, default: 0] >= $0.value } }
    /// The saves of both: a version saved after it includes each of them.
    func merged(with other: SaveCounts) -> SaveCounts {
        SaveCounts(counts.merging(other.counts) { max($0, $1) })
    }
    func adding(_ mac: String) -> SaveCounts {
        var next = self
        next.counts[mac, default: 0] += 1
        return next
    }
}

/// What a version found in the save location is, next to the one this Mac has.
enum SyncVerdict: Equatable {
    case same  // Nothing this Mac has not seen.
    case newer  // It has every save this Mac has, and more.
    case older  // It lacks saves this Mac has, and has none this Mac lacks: written from a copy that was behind.
    case both  // Changed on two Macs at once: each has saves the other lacks.

    static func of(_ incoming: Meeting, here: SaveCounts, hereRevision: UInt64) -> SyncVerdict {
        // Written by a version of ギジログ before the counts: only its save count tells.
        guard let theirs = incoming.saveCounts else { return incoming.revision >= hereRevision ? .newer : .older }
        if theirs == here { return .same }
        if theirs.includes(here) { return .newer }
        if here.includes(theirs) { return .older }
        return .both
    }
}

/// A version of the meeting kept aside when it was changed on two Macs at once (meeting.conflict.json beside
/// meeting.json): which Mac saved it, and when it was found.
struct MeetingConflict: Codable, Equatable {
    var savedOn: String?
    var found: Date
}

extension Meeting {
    /// Recording, transcription or minutes still to finish, as a quit or a crash can leave them.
    var hasUnfinishedWork: Bool {
        capture == .recording || finalReviewPending == true
            || jobs.contains { $0.state == .pending || $0.state == .running }
            || (settings != nil && !MinutesEngine.batch(segments, state: notes ?? MinutesState()).isEmpty)
    }
}

// The Store's side of sharing a save location: taking in what other Macs changed, keeping both versions when two
// changed a meeting at once, and taking up work another Mac left unfinished.
extension Store {
    /// Takes in listed meetings changed in the save location by something else, such as the same meeting edited on
    /// another Mac and synced. An older version is refused and this Mac's saved over it. A meeting changed both there
    /// and here (being recorded, processed or edited here, or with changes not yet saved) keeps this Mac's version,
    /// and the other is kept aside to choose from.
    func reloadChangedMeetings() async {
        guard ready else { return }
        let listed = meetings.map { (id: $0.id, folder: $0.folderName ?? $0.id.uuidString) }
        var reloaded = 0
        var refused = 0
        var kept = 0
        for (meeting, date) in await repository.loadChanged(listed) {
            let id = meeting.id
            guard let i = meetings.firstIndex(where: { $0.id == id }) else { continue }
            let here = savedCounts[id] ?? SaveCounts.of(meetings[i])
            let hereRevision = max(meetings[i].revision, revisions[id] ?? 0)
            let verdict = SyncVerdict.of(meeting, here: here, hereRevision: hereRevision)
            guard owns(meetings[i]) else {
                // Another Mac's meeting is only read here: the version it saved is shown. An older one that comes
                // back is that Mac's to put right, not this one's to write over.
                await repository.markSeen(id, at: date)
                guard verdict == .newer || verdict == .both else { continue }
                meetings[i] = meeting
                revisions[id] = meeting.revision
                savedCounts[id] = SaveCounts.of(meeting)
                await repository.keepCopy(meeting)
                reloaded += 1
                continue
            }
            let busy = id == activeID || isProcessing(id) || dirtyIDs.contains(id)
            let open = selected == id && (editingNoteItem != nil || editingSegment != nil || editingTitle == id)
            switch verdict {
            case .same:
                await repository.markSeen(id, at: date)
            case .older:
                // Taken in, it would undo what was done since: this Mac's version goes back over it.
                await repository.markSeen(id, at: date)
                try? await checkpoint(id)
                refused += 1
            case .newer where !busy:
                // While an edit is open it waits: taken in after the edit closes, unless the edit changed the meeting.
                guard !open else { continue }
                meetings[i] = meeting
                revisions[id] = meeting.revision
                savedCounts[id] = SaveCounts.of(meeting)
                await repository.markSeen(id, at: date)
                await repository.keepCopy(meeting)
                reloaded += 1
            case .newer, .both:
                await keepAside(meeting, found: date, here: here, hereRevision: hereRevision)
                kept += 1
            }
        }
        if kept > 0 {
            status = "ほかの Mac でも同時に直された会議があります。もう一方の版を別に残しました"
        } else if refused > 0 {
            status = "ほかから届いた古い版の会議は取り込まず、この Mac の版を保存し直しました"
        } else if reloaded > 0 {
            status = reloaded == 1 ? "ほかで更新された会議を読み込み直しました" : "ほかで更新された会議を\(reloaded)件読み込み直しました"
        }
    }
    /// Keeps the other Mac's version of a meeting changed on both beside this Mac's, which stays, and saves this
    /// Mac's counted past both, so the other Mac takes it in rather than keeping a version aside in turn.
    func keepAside(_ other: Meeting, found: Date, here: SaveCounts, hereRevision: UInt64) async {
        let id = other.id
        guard (try? await repository.keepAside(other)) != nil else { return }
        savedCounts[id] = here.merged(with: SaveCounts.of(other))
        revisions[id] = max(hereRevision, other.revision)
        await repository.markSeen(id, at: found)
        change(id) { $0.conflict = MeetingConflict(savedOn: other.savedOn, found: found) }
    }
    /// Puts the version kept aside in place of the one shown, and keeps the one shown aside instead, so either can
    /// be chosen again until the other is let go.
    func swapConflict(_ id: UUID) async {
        guard id != activeID, !isProcessing(id), let i = meetings.firstIndex(where: { $0.id == id }),
            var other = await repository.versionAside(of: meetings[i])
        else { return }
        let shown = meetings[i]
        guard (try? await repository.keepAside(shown)) != nil else { return }
        other.folderName = shown.folderName
        other.workingMac = shown.workingMac  // The Mac that chose keeps the meeting.
        other.conflict = MeetingConflict(savedOn: shown.savedOn ?? Self.computerName, found: Date())
        savedCounts[id] = (savedCounts[id] ?? SaveCounts.of(shown)).merged(with: SaveCounts.of(other))
        revisions[id] = max(revisions[id] ?? 0, shown.revision, other.revision)
        meetings[i] = other
        change(id) { _ in }
    }
    /// Keeps the version shown and lets the one kept aside go.
    func dismissConflict(_ id: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        await repository.removeAside(of: meeting)
        change(id) { $0.conflict = nil }
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
        for meeting in added {
            revisions[meeting.id] = meeting.revision
            savedCounts[meeting.id] = SaveCounts.of(meeting)
        }
        meetings = (meetings + added).sorted { $0.date > $1.date }
        // Only accepted meetings get a copy: a duplicate folder must not replace the listed meeting's backup.
        for meeting in added { await repository.keepCopy(meeting) }
        await repository.writeMissingDocuments(added)
        status = added.count == 1 ? "「\(added[0].title)」を読み込みました" : "会議を\(added.count)件読み込みました"
    }
    /// Takes a meeting another Mac records (or one that names no Mac) for this Mac to change. From then on the other
    /// Mac only reads it.
    func editHere(_ id: UUID) {
        claim(id)
        status = "この Mac で編集できるようにしました"
    }
    /// Takes up, on this Mac, work another Mac left unfinished (or a file that names no Mac), when the user says that
    /// Mac will not finish it: from then on this Mac records and processes the meeting.
    func continueHere(_ id: UUID) async {
        guard id != activeID, !isProcessing(id), let meeting = meetings.first(where: { $0.id == id }),
            meeting.workingMac != thisMac, meeting.hasUnfinishedWork
        else { return }
        claim(id)
        do {
            try await takeUpUnfinishedWork(meeting)
        } catch {
            self.error = error.localizedDescription
        }
    }
    /// The name of this Mac as the user sees it, saved with each version, so a version kept aside can say where it
    /// was made.
    static let computerName = Host.current().localizedName
}
