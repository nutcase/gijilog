import AVFoundation
import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - People

extension Store {
    /// Everyone named as an action's owner in any meeting, most often first: the list to pick an owner from, kept
    /// up to date by the minutes themselves. A name written with or without さん is one person, spelled as in the
    /// most recent meeting.
    var knownOwners: [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        var order: [String] = []
        for meeting in meetings.sorted(by: { $0.date > $1.date }) {
            for owner in meeting.notes?.content.actions.filter({ $0.state != .cancelled }).flatMap(\.owners) ?? [] {
                let name = owner.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = Self.personKey(name)
                guard !key.isEmpty else { continue }
                if let entry = counts[key] {
                    counts[key] = (entry.name, entry.count + 1)
                } else {
                    counts[key] = (name, 1)
                    order.append(key)
                }
            }
        }
        return order.compactMap { counts[$0] }.enumerated()
            .sorted {
                $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
            }
            .map(\.element.name)
    }
    /// A name without spacing, width differences or a trailing honorific, to tell whether two names are one person.
    nonisolated static func personKey(_ name: String) -> String {
        var key = name.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil).filter { !$0.isWhitespace }
        for honorific in ["さん", "さま", "様", "氏", "くん", "君", "ちゃん"] where key.hasSuffix(honorific) {
            if key.count > honorific.count { key.removeLast(honorific.count) }
            break
        }
        return key
    }
}

// MARK: - Tags

extension Store {
    /// Every tag in use with the number of meetings that have it, most used first.
    /// A tag spelled differently across meetings is listed with its most recent meeting's spelling.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        var order: [String] = []
        for meeting in meetings {
            for tag in meeting.tags {
                let key = MeetingTags.key(tag)
                if let entry = counts[key] {
                    counts[key] = (entry.name, entry.count + 1)
                } else {
                    counts[key] = (tag, 1)
                    order.append(key)
                }
            }
        }
        return order.compactMap { counts[$0] }.enumerated()
            .sorted {
                $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset
            }
            .map(\.element)
    }
    var visibleMeetings: [Meeting] {
        guard !tagFilter.isEmpty || !searchedTerms.isEmpty else { return meetings }
        return meetings.filter { meeting in
            tagFilter.allSatisfy { MeetingTags.contains(meeting.tags, $0) }
                && (searchedTerms.isEmpty || searchHits[meeting.id] != nil)
        }
    }
    /// Adds tags typed or picked for a meeting. A tag another meeting already has keeps that spelling.
    func addTags(_ text: String, to id: UUID) {
        let known = allTags.map(\.name)
        let tags = MeetingTags.parse(text).map { tag in
            known.first { MeetingTags.key($0) == MeetingTags.key(tag) } ?? tag
        }
        guard !tags.isEmpty else { return }
        change(id) { $0.tags = MeetingTags.adding(tags, to: $0.tags) }
    }
    func removeTag(_ tag: String, from id: UUID) {
        change(id) { meeting in meeting.tags.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) } }
        pruneTagFilter()
    }
    /// Narrows the list to meetings with the tag, or widens it again. A selection the list no longer shows
    /// moves to the first meeting it does.
    func toggleTagFilter(_ tag: String) {
        if MeetingTags.contains(tagFilter, tag) {
            tagFilter.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) }
        } else {
            tagFilter.append(tag)
        }
        selectVisibleMeeting()
    }
    func clearTagFilter() { tagFilter = [] }
    /// Renames a tag on every meeting. A name another tag already has merges the two, spelled as typed.
    /// Returns false when the name is empty or would be split into several tags by a comma.
    @discardableResult func renameTag(_ tag: String, to newName: String) -> Bool {
        let names = MeetingTags.parse(newName)
        guard names.count == 1, let name = names.first else { return false }
        let keys: Set = [MeetingTags.key(tag), MeetingTags.key(name)]
        for meeting in meetings where meeting.tags.contains(where: { keys.contains(MeetingTags.key($0)) }) {
            change(meeting.id) { meeting in
                meeting.tags = MeetingTags.adding(
                    meeting.tags.map { keys.contains(MeetingTags.key($0)) ? name : $0 }, to: [])
            }
        }
        tagFilter = MeetingTags.adding(tagFilter.map { keys.contains(MeetingTags.key($0)) ? name : $0 }, to: [])
        return true
    }
    /// Takes the tag off every meeting. The meetings themselves stay.
    func deleteTag(_ tag: String) {
        for meeting in meetings where MeetingTags.contains(meeting.tags, tag) {
            change(meeting.id) { meeting in meeting.tags.removeAll { MeetingTags.key($0) == MeetingTags.key(tag) } }
        }
        pruneTagFilter()
    }
    /// A selection the list no longer shows moves to the first meeting it does.
    private func selectVisibleMeeting() {
        let visible = visibleMeetings
        if !visible.contains(where: { $0.id == selected }), let first = visible.first { selected = first.id }
    }
    /// A new meeting has no tags and matches no search yet; clear both so it shows in the list.
    func showNewMeeting() {
        tagFilter = []
        if !searchText.isEmpty {
            searchText = ""
            refreshSearch()
        }
    }
    /// Finds the meetings that contain every keyword. A new query also moves the selection to its first result.
    func refreshSearch() {
        let terms = MeetingSearch.terms(searchText)
        var hits: [UUID: SearchHit] = [:]
        if !terms.isEmpty {
            for meeting in meetings {
                if let hit = MeetingSearch.search(meeting, terms: terms) { hits[meeting.id] = hit }
            }
        }
        if hits != searchHits { searchHits = hits }
        guard terms != searchedTerms else { return }
        searchedTerms = terms
        selectVisibleMeeting()
    }
    /// A tag no meeting has any more cannot narrow the list.
    func pruneTagFilter() {
        let used = Set(meetings.flatMap { $0.tags.map(MeetingTags.key) })
        tagFilter.removeAll { !used.contains(MeetingTags.key($0)) }
    }
}
