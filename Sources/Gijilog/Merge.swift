import Foundation

// A meeting changed on two Macs at once is merged from the last version both had (the base, see
// MeetingRepository.base): what only one Mac changed comes from it, what both changed alike stays, and what both
// changed differently keeps this Mac's, and is listed as a spot for the user to choose. Things are told apart by
// their IDs: transcript lines, minutes items, agenda items and word fixes. What processing writes (the transcription
// queue, which lines the minutes have taken in) comes whole from the Mac that records and processes the meeting.

/// A place two Macs changed differently: what it is, and each Mac's version, as the notice shows them.
struct ConflictSpot: Codable, Equatable, Identifiable {
    var id: String  // "title", "segment:<id>", "note:<part>:<id>", "agenda:<id>", "correction:<id>".
    var label: String
    var kept: String  // Shown in the meeting now; "" when it is not there (deleted).
    var other: String  // In the version kept aside.
}

enum MeetingMerge {
    struct Result {
        var meeting: Meeting
        var spots: [ConflictSpot]
    }
    /// The merged meeting, and the spots both versions changed differently (where `ours` is kept). `oursProcesses`
    /// says which side's processing state is the one that goes on.
    static func merge(base: Meeting, ours: Meeting, theirs: Meeting, oursProcesses: Bool) -> Result {
        var merged = ours
        var spots: [ConflictSpot] = []
        let (title, titleDiffers) = pick(base.title, ours.title, theirs.title)
        merged.title = title
        if titleDiffers {
            spots.append(ConflictSpot(id: "title", label: "タイトル", kept: ours.title, other: theirs.title))
        }
        merged.date = pick(base.date, ours.date, theirs.date).value
        merged.tags = orderedSet(base.tags, ours.tags, theirs.tags)
        merged.ignoredLearned = optionalOrderedSet(base.ignoredLearned, ours.ignoredLearned, theirs.ignoredLearned)
        merged.revisedBeforeMinutes = optionalSet(
            base.revisedBeforeMinutes, ours.revisedBeforeMinutes, theirs.revisedBeforeMinutes)
        merged.workingMac = pick(base.workingMac, ours.workingMac, theirs.workingMac).value
        merged.agenda = keyed(
            base.agenda, ours.agenda, theirs.agenda, spots: &spots,
            spot: { ConflictSpot(id: "agenda:\($0.id)", label: "アジェンダ「\(short($0.title))」", kept: "", other: "") },
            text: \.title)
        merged.corrections = keyed(
            base.corrections, ours.corrections, theirs.corrections, spots: &spots,
            spot: { ConflictSpot(id: "correction:\($0.id)", label: "語句の直し「\(short($0.to))」", kept: "", other: "") },
            text: { "\($0.variants.joined(separator: "、")) → \($0.to)" })
        merged.segments = keyed(
            base.segments, ours.segments, theirs.segments, spots: &spots,
            spot: { ConflictSpot(id: "segment:\($0.id)", label: "文字起こし \(clock($0.time))", kept: "", other: "") },
            text: \.text
        ).enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        // A notice dismissed on either Mac stays dismissed; one that came up since the base stays up.
        merged.stoppedForSilence =
            base.stoppedForSilence != nil && (ours.stoppedForSilence == nil || theirs.stoppedForSilence == nil)
            ? nil : pick(base.stoppedForSilence, ours.stoppedForSilence, theirs.stoppedForSilence).value
        // Processing goes on from the Mac that does it.
        let worker = oursProcesses ? ours : theirs
        merged.status = worker.status
        merged.capture = worker.capture
        merged.jobs = worker.jobs
        merged.settings = worker.settings
        merged.captureError = worker.captureError
        merged.hasAudio = worker.hasAudio
        merged.finalReviewPending = worker.finalReviewPending
        merged.clockStart = worker.clockStart
        merged.minutes = worker.minutes
        merged.notes = mergeNotes(base.notes, ours.notes, theirs.notes, worker: worker.notes, spots: &spots)
        merged.revision = max(ours.revision, theirs.revision)
        return Result(meeting: merged, spots: spots)
    }
    private static func mergeNotes(
        _ base: MinutesState?, _ ours: MinutesState?, _ theirs: MinutesState?, worker: MinutesState?,
        spots: inout [ConflictSpot]
    ) -> MinutesState? {
        guard ours != nil || theirs != nil else { return nil }
        let empty = MinutesState()
        let (b, o, t) = (base ?? empty, ours ?? empty, theirs ?? empty)
        var merged = worker ?? o  // Processing state: what the minutes have taken in, reviewed, when updated.
        for part in NotePart.allCases {
            merged.content[part] = keyed(
                b.content[part], o.content[part], t.content[part], spots: &spots,
                spot: {
                    ConflictSpot(
                        id: "note:\(part.rawValue):\($0.id)", label: "\(name(part))「\(short($0.text))」", kept: "",
                        other: "")
                },
                text: \.text)
        }
        merged.dismissed = optionalOrderedSet(b.dismissed, o.dismissed, t.dismissed)
        merged.revisedSegmentIDs = optionalSet(b.revisedSegmentIDs, o.revisedSegmentIDs, t.revisedSegmentIDs)
        merged.uncheckedItemIDs = optionalSet(b.uncheckedItemIDs, o.uncheckedItemIDs, t.uncheckedItemIDs)
        return merged
    }

    /// The value after both changes: one side's change, or the change both made alike; `differs` when both changed it
    /// differently, and then ours.
    static func pick<V: Equatable>(_ base: V, _ ours: V, _ theirs: V) -> (value: V, differs: Bool) {
        if ours == theirs || theirs == base { return (ours, false) }
        if ours == base { return (theirs, false) }
        return (ours, true)
    }
    /// Lists of things with IDs, in ours' order with theirs' additions placed after what came before them there.
    /// Added on either side stays; deleted on one side and untouched on the other goes; changed on both, or
    /// deleted on one and changed on the other, keeps ours (or the changed one) and is listed.
    static func keyed<T: Identifiable & Equatable>(
        _ base: [T], _ ours: [T], _ theirs: [T], spots: inout [ConflictSpot], spot: (T) -> ConflictSpot,
        text: (T) -> String
    ) -> [T] {
        let before = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let there = Dictionary(theirs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [T] = []
        func differ(_ kept: T?, _ other: T?, about item: T) {
            var listed = spot(item)
            listed.kept = kept.map(text) ?? ""
            listed.other = other.map(text) ?? ""
            spots.append(listed)
        }
        for item in ours {
            switch (before[item.id], there[item.id]) {
            case (nil, nil):
                result.append(item)  // Added here.
            case (nil, let other?):
                result.append(item)  // Added on both with the same ID.
                if other != item { differ(item, other, about: item) }
            case (let old?, nil):
                // Deleted there: gone, unless changed here meanwhile.
                if item != old {
                    result.append(item)
                    differ(item, nil, about: item)
                }
            case (let old?, let other?):
                let (value, differs) = pick(old, item, other)
                result.append(value)
                if differs { differ(item, other, about: item) }
            }
        }
        let here = Set(ours.map(\.id))
        for (index, item) in theirs.enumerated() where !here.contains(item.id) {
            if let old = before[item.id] {
                // Deleted here: gone, unless changed there meanwhile.
                guard item != old else { continue }
                differ(nil, item, about: item)
            }
            let previous = theirs[..<index].last { earlier in result.contains { $0.id == earlier.id } }
            let at = previous.flatMap { earlier in result.firstIndex { $0.id == earlier.id } }.map { $0 + 1 } ?? 0
            result.insert(item, at: at)
        }
        return result
    }
    /// Puts the other version's take of one place (a ConflictSpot ID) into the meeting: its title, or the transcript
    /// line, minutes item, agenda item or word fix with that ID, added, replaced or removed as it is there.
    static func take(_ spot: String, from other: Meeting, into meeting: inout Meeting) {
        let parts = spot.split(separator: ":", maxSplits: 1).map(String.init)
        guard let kind = parts.first else { return }
        let rest = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "title":
            meeting.title = other.title
        case "segment":
            replace(rest, in: &meeting.segments, from: other.segments)
            meeting.segments = meeting.segments.enumerated().sorted {
                ($0.element.time, $0.offset) < ($1.element.time, $1.offset)
            }.map(\.element)
        case "agenda":
            replace(rest, in: &meeting.agenda, from: other.agenda, id: { $0.id.uuidString })
        case "correction":
            replace(rest, in: &meeting.corrections, from: other.corrections, id: { $0.id.uuidString })
        case "note":
            let place = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard place.count == 2, let part = NotePart(rawValue: place[0]) else { return }
            var notes = meeting.notes ?? MinutesState()
            replace(place[1], in: &notes.content[part], from: other.notes?.content[part] ?? [])
            meeting.notes = notes
        default:
            return
        }
    }
    private static func replace<T: Identifiable>(_ key: String, in list: inout [T], from other: [T])
    where T.ID == String {
        replace(key, in: &list, from: other, id: { $0.id })
    }
    private static func replace<T>(_ key: String, in list: inout [T], from other: [T], id: (T) -> String) {
        let there = other.firstIndex { id($0) == key }
        if let here = list.firstIndex(where: { id($0) == key }) {
            if let there { list[here] = other[there] } else { list.remove(at: here) }
        } else if let there {
            // Placed after what comes before it in the other version, as a merge places additions.
            let previous = other[..<there].last { earlier in list.contains { id($0) == id(earlier) } }
            let at = previous.flatMap { earlier in list.firstIndex { id($0) == id(earlier) } }.map { $0 + 1 } ?? 0
            list.insert(other[there], at: at)
        }
    }
    /// Kept when both have it, or one added it; gone when one removed it and the other did not add it back.
    static func orderedSet(_ base: [String], _ ours: [String], _ theirs: [String]) -> [String] {
        let (b, o, t) = (Set(base), Set(ours), Set(theirs))
        func keeps(_ value: String) -> Bool {
            (o.contains(value) && t.contains(value)) || (!b.contains(value) && (o.contains(value) || t.contains(value)))
        }
        var result = ours.filter(keeps)
        for value in theirs where keeps(value) && !result.contains(value) { result.append(value) }
        return result
    }
    private static func optionalOrderedSet(_ base: [String]?, _ ours: [String]?, _ theirs: [String]?) -> [String]? {
        let merged = orderedSet(base ?? [], ours ?? [], theirs ?? [])
        return merged.isEmpty ? nil : merged
    }
    private static func optionalSet(_ base: Set<String>?, _ ours: Set<String>?, _ theirs: Set<String>?) -> Set<String>?
    {
        let merged = Set(orderedSet(Array(base ?? []), Array(ours ?? []), Array(theirs ?? [])))
        return merged.isEmpty ? nil : merged
    }
    private static func short(_ text: String) -> String { text.count > 24 ? String(text.prefix(24)) + "…" : text }
    private static func name(_ part: NotePart) -> String {
        switch part {
        case .summary: "要約"
        case .decisions: "決定事項"
        case .unresolved: "未決事項"
        case .actions: "アクション"
        }
    }
}
