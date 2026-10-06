import Foundation

// Fixing a misheard word once fixes it across the meeting: the minutes, the transcript, the title and the agenda.
// Other spellings that read the same (森バス, もりばす for モリバス) are found by their reading, on the Mac.
// The fix is kept as a rule, so minutes the AI writes later and speech transcribed later are corrected too.

enum NotePart: String, Codable, CaseIterable, Sendable { case summary, decisions, unresolved, actions }
enum NoteField: String, Codable, CaseIterable, Sendable { case text, owner, due, reason, nextStep, points, opinions }
/// A piece of text in a meeting that a correction can change.
enum TextPlace: Hashable, Codable, Sendable {
    case title
    case agendaTitle(UUID)
    case agendaGoal(UUID)
    case item(NotePart, String, NoteField)
    case segment(String)
}
struct TextChange: Codable, Equatable, Sendable {
    var place: TextPlace
    var before: String
    var after: String
}
struct TermCorrection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var variants: [String]  // The spellings replaced; later AI output with them is corrected the same way.
    var to: String
    var changes: [TextChange] = []  // What this correction changed, to undo it.
    var date = Date()
}
struct TermOccurrence: Identifiable, Hashable, Sendable {
    var place: TextPlace
    var range: NSRange
    var found: String
    var exact: Bool  // The same spelling; otherwise only the reading matches.
    var id: String { "\(place)#\(range.location)" }
}

extension NotesDelta {
    subscript(part: NotePart) -> [NoteItem] {
        get {
            switch part {
            case .summary: summary
            case .decisions: decisions
            case .unresolved: unresolved
            case .actions: actions
            }
        }
        set {
            switch part {
            case .summary: summary = newValue
            case .decisions: decisions = newValue
            case .unresolved: unresolved = newValue
            case .actions: actions = newValue
            }
        }
    }
}
extension NoteItem {
    /// A field as text. A summary topic's points and opinions read one per line.
    subscript(field: NoteField) -> String? {
        get {
            switch field {
            case .text: text
            case .owner: owner
            case .due: due
            case .reason: reason
            case .nextStep: nextStep
            case .points: points?.joined(separator: "\n")
            case .opinions: opinions?.joined(separator: "\n")
            }
        }
        set {
            switch field {
            case .text: text = newValue ?? text
            case .owner: owner = newValue
            case .due: due = newValue
            case .reason: reason = newValue
            case .nextStep: nextStep = newValue
            case .points: points = Self.lines(newValue)
            case .opinions: opinions = Self.lines(newValue)
            }
        }
    }
    /// Text written one entry per line, without blank lines; nil when nothing is left.
    static func lines(_ text: String?) -> [String]? {
        let lines = (text ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines
    }
}

enum TermMatcher {
    private static let options: NSString.CompareOptions = [.caseInsensitive, .widthInsensitive]
    /// The words of a text with their readings in Latin letters, from the system's Japanese dictionary.
    static func words(_ text: String) -> [(range: NSRange, reading: String)] {
        let length = (text as NSString).length
        guard length > 0 else { return [] }
        let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRange(location: 0, length: length), kCFStringTokenizerUnitWord,
            Locale(identifier: "ja_JP") as CFLocale)
        var result: [(NSRange, String)] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let latin =
                CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription)
                as? String
            result.append((NSRange(location: range.location, length: range.length), normalized(latin ?? "")))
        }
        return result
    }
    private static func normalized(_ reading: String) -> String {
        reading.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
    /// "森バス", "もりばす" and "モリバス" all read "moribasu".
    static func reading(_ text: String) -> String { words(text).map(\.reading).joined() }
    enum Script { case kanji, katakana, latin, other }
    static func script(_ character: Character) -> Script {
        guard let value = character.unicodeScalars.first?.value else { return .other }
        if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || value == 0x3005 { return .kanji }
        if (0x30A0...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) || (0xFF66...0xFF9F).contains(value) {
            return .katakana
        }
        if (character.isASCII && (character.isLetter || character.isNumber)) || (0xFF10...0xFF5A).contains(value) {
            return .latin
        }
        return .other
    }

    /// Where a term appears: the same spelling (ignoring case and width), and, when asked, other spellings with the
    /// same reading. A reading is compared only when it is long enough not to match common words by chance.
    static func ranges(of term: String, in text: String, sameReading: Bool) -> [(range: NSRange, exact: Bool)] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        guard !term.isEmpty, ns.length > 0 else { return [] }
        var result: [(range: NSRange, exact: Bool)] = []
        var start = 0
        while start < ns.length {
            let found = ns.range(of: term, options: options, range: NSRange(location: start, length: ns.length - start))
            guard found.location != NSNotFound else { break }
            result.append((found, true))
            start = found.location + max(found.length, 1)
        }
        let target = reading(term)
        guard sameReading, target.count >= 4 else { return result }
        let words = words(text)
        for i in words.indices {
            var combined = ""
            for j in i..<min(words.count, i + 6) {
                guard !words[j].reading.isEmpty else { break }
                combined += words[j].reading
                if combined == target {
                    let range = NSUnionRange(words[i].range, words[j].range)
                    if !result.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                        result.append((range, false))
                    }
                    break
                }
                if !target.hasPrefix(combined) { break }
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
    /// Replaces each variant with the correction, except where the correct spelling is already there: fixing 郡 to
    /// 郡司 leaves "郡司" alone.
    static func replacing(_ variants: [String], with replacement: String, in text: String) -> String {
        var ns = text as NSString
        for variant in variants where !variant.isEmpty {
            let correct = ranges(of: replacement, in: ns as String, sameReading: false).map(\.range)
            let found = ranges(of: variant, in: ns as String, sameReading: false).map(\.range)
                .filter { range in !correct.contains { NSIntersectionRange($0, range).length > 0 } }
            guard !found.isEmpty else { continue }
            let copy = NSMutableString(string: ns)
            for range in found.reversed() { copy.replaceCharacters(in: range, with: replacement) }
            ns = copy
        }
        return ns as String
    }
    /// The word changed in an edit, as whole words: "森バスのコスト" → "モリバスのコスト" changes 森バス to モリバス,
    /// not just 森 to モリ. Nil when nothing, or more than one short phrase, changed.
    static func changedTerm(from old: String, to new: String) -> (from: String, to: String)? {
        let a = Array(old)
        let b = Array(new)
        guard a != b else { return nil }
        var prefix = 0
        while prefix < min(a.count, b.count) && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        // Widen the change to the run of kanji, katakana or Latin letters it sits in, on either side, since a word
        // is spelled in one script ("森" in 森バス, "松" in 高松); hiragana is mostly particles and stops it.
        func widened(_ characters: [Character], _ prefix: Int, _ suffix: Int) -> (Int, Int) {
            var low = prefix
            var high = characters.count - suffix
            let left = low > 0 ? script(characters[low - 1]) : nil
            let first = low < high ? script(characters[low]) : left
            while low > 0, let kind = first, kind != .other, script(characters[low - 1]) == kind { low -= 1 }
            let last = low < high ? script(characters[high - 1]) : first
            while high < characters.count, let kind = last, kind != .other, script(characters[high]) == kind {
                high += 1
            }
            return (low, characters.count - high)
        }
        let (oldPrefix, oldSuffix) = widened(a, prefix, suffix)
        let (newPrefix, newSuffix) = widened(b, prefix, suffix)
        let p = min(oldPrefix, newPrefix)
        let s = min(oldSuffix, newSuffix)
        let from = String(a[p..<(a.count - s)]).trimmingCharacters(in: .whitespacesAndNewlines)
        let to = String(b[p..<(b.count - s)]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...24).contains(from.count), !to.isEmpty, to.count <= 24, !from.contains(where: \.isNewline),
            !to.contains(where: \.isNewline)
        else { return nil }
        return (from, to)
    }
}

extension Meeting {
    /// Every piece of text a correction may change, in reading order.
    var textPlaces: [TextPlace] {
        var places: [TextPlace] = [.title]
        for item in agenda {
            places.append(.agendaTitle(item.id))
            if item.goal != nil { places.append(.agendaGoal(item.id)) }
        }
        if let content = notes?.content {
            for part in NotePart.allCases {
                for item in content[part] {
                    places += NoteField.allCases.filter { item[$0] != nil }.map { .item(part, item.id, $0) }
                }
            }
        }
        return places + segments.sorted { $0.time < $1.time }.map { .segment($0.id) }
    }
    func text(at place: TextPlace) -> String? {
        switch place {
        case .title: title
        case .agendaTitle(let id): agenda.first { $0.id == id }?.title
        case .agendaGoal(let id): agenda.first { $0.id == id }?.goal
        case .item(let part, let id, let field): notes?.content[part].first { $0.id == id }?[field]
        case .segment(let id): segments.first { $0.id == id }?.text
        }
    }
    mutating func setText(_ text: String, at place: TextPlace) {
        switch place {
        case .title: title = text
        case .agendaTitle(let id):
            if let i = agenda.firstIndex(where: { $0.id == id }) { agenda[i].title = text }
        case .agendaGoal(let id):
            if let i = agenda.firstIndex(where: { $0.id == id }) { agenda[i].goal = text }
        case .item(let part, let id, let field):
            if let i = notes?.content[part].firstIndex(where: { $0.id == id }) { notes?.content[part][i][field] = text }
        case .segment(let id):
            if let i = segments.firstIndex(where: { $0.id == id }) { segments[i].text = text }
        }
    }
    /// Where a misheard term appears, leaving out text already spelled the correct way.
    func occurrences(of term: String, correctedTo replacement: String) -> [TermOccurrence] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.compare(replacement, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame
        else { return [] }
        return textPlaces.flatMap { place -> [TermOccurrence] in
            guard let text = text(at: place) else { return [] }
            let ns = text as NSString
            let correct = replacement.isEmpty ? [] : TermMatcher.ranges(of: replacement, in: text, sameReading: false)
            return TermMatcher.ranges(of: term, in: text, sameReading: true).compactMap { match in
                guard !correct.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else {
                    return nil
                }
                return TermOccurrence(
                    place: place, range: match.range, found: ns.substring(with: match.range), exact: match.exact)
            }
        }
    }
    /// Replaces the chosen occurrences and keeps the correction, so it can be undone and applied to later text.
    @discardableResult mutating func correct(_ occurrences: [TermOccurrence], to replacement: String) -> TermCorrection
    {
        var changes: [TextChange] = []
        for place in Set(occurrences.map(\.place)) {
            guard let before = text(at: place) else { continue }
            let text = NSMutableString(string: before)
            for occurrence in occurrences.filter({ $0.place == place }).sorted(by: {
                $0.range.location > $1.range.location
            })
            where NSMaxRange(occurrence.range) <= text.length
                && text.substring(with: occurrence.range) == occurrence.found
            {
                text.replaceCharacters(in: occurrence.range, with: replacement)
            }
            let after = text as String
            if after != before {
                setText(after, at: place)
                changes.append(TextChange(place: place, before: before, after: after))
            }
        }
        var variants: [String] = []
        for found in occurrences.map(\.found) where !variants.contains(found) { variants.append(found) }
        let correction = TermCorrection(variants: variants, to: replacement, changes: changes)
        corrections.append(correction)
        return correction
    }
    /// Restores what a correction changed, where nothing has changed the text since, and forgets the correction.
    mutating func undo(_ id: UUID) {
        guard let correction = corrections.first(where: { $0.id == id }) else { return }
        for change in correction.changes.reversed() where text(at: change.place) == change.after {
            setText(change.before, at: change.place)
        }
        corrections.removeAll { $0.id == id }
    }
    /// Text written after a correction, by transcription or the AI, gets the same correction.
    func corrected(_ text: String) -> String {
        corrections.reduce(text) { TermMatcher.replacing($1.variants, with: $1.to, in: $0) }
    }
    func corrected(_ notes: MinutesState) -> MinutesState {
        guard !corrections.isEmpty else { return notes }
        var notes = notes
        for part in NotePart.allCases {
            for i in notes.content[part].indices {
                for field in NoteField.allCases {
                    if let text = notes.content[part][i][field] { notes.content[part][i][field] = corrected(text) }
                }
            }
        }
        return notes
    }
}
