import Foundation

struct GoogleOAuthClient: Codable, Sendable {
    let clientID: String
    let clientSecret: String?
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
    static func imported(_ data: Data) throws -> Self {
        struct File: Decodable { let installed: GoogleOAuthClient }
        let client = try JSONDecoder().decode(File.self, from: data).installed
        guard client.clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw AppError.message("デスクトップアプリ用のGoogle接続設定を選んでください。")
        }
        return client
    }
}
struct GoogleCalendarInfo: Decodable, Identifiable, Sendable {
    let id: String
    let summary: String?
    let primary: Bool?
    var title: String { summary ?? id }
}
struct CalendarEvent: Identifiable, Equatable, Sendable {
    let calendarID: String
    let eventID: String
    let seriesID: String?
    let title: String
    let start: Date
    let end: Date
    let meetingURL: URL?
    var id: String { Self.key([calendarID, eventID]) }
    var seriesKey: String? { seriesID.map { Self.key([calendarID, $0]) } }
    static func key(_ parts: [String]) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
}
// Untimed, declined, cancelled and non-meeting event types never enter the recording scheduler.
struct GoogleEvent: Decodable {
    struct Time: Decodable { let dateTime: String? }
    struct Attendee: Decodable {
        let isSelf: Bool?
        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
        let responseStatus: String?
    }
    struct Conference: Decodable {
        struct Entry: Decodable {
            let entryPointType: String?
            let uri: String?
        }
        let entryPoints: [Entry]?
    }
    let id: String
    let summary: String?
    let status: String?
    let eventType: String?
    let start: Time?
    let end: Time?
    let recurringEventId: String?
    let attendees: [Attendee]?
    let hangoutLink: String?
    let location: String?
    let conferenceData: Conference?
    func event(calendarID: String) -> CalendarEvent? {
        guard status != "cancelled", eventType == nil || eventType == "default",
            attendees?.contains(where: { $0.isSelf == true && $0.responseStatus == "declined" }) != true,
            let start = Self.date(start?.dateTime), let end = Self.date(end?.dateTime), end > start
        else { return nil }
        let candidates =
            [hangoutLink] + (conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.map(\.uri) + [
                location
            ]
        let url = candidates.compactMap { $0.flatMap(Self.safeURL) }.first
        let name = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            calendarID: calendarID, eventID: id, seriesID: recurringEventId,
            title: name.flatMap { $0.isEmpty ? nil : $0 } ?? "タイトルなしの予定", start: start, end: end, meetingURL: url)
    }
    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
// Local to this Mac, never part of a synced meeting folder. The hardware ID prevents settings copied to another
// Mac from enabling automatic recording there too. Finished/skipped instances are persisted before starting.
struct CalendarPreferences: Codable {
    var selectedCalendars: Set<String> = []
    var useTitle = true
    var automaticMac: String?
    var automaticEvents: Set<String> = []
    var automaticSeries: Set<String> = []
    var skipped: [String: Date] = [:]
    var meetings: [String: UUID] = [:]
    func enabled(_ event: CalendarEvent) -> Bool {
        automaticEvents.contains(event.id) || event.seriesKey.map { automaticSeries.contains($0) } == true
    }
}
struct CalendarCountdown: Equatable {
    let event: CalendarEvent
    let announcedAt: Date
}
enum CalendarTitleMatch {
    static func suggestions(at date: Date, events: [CalendarEvent]) -> [CalendarEvent] {
        // Keep the actual time window across midnight; never fall back to unrelated same-day events.
        events.filter {
            $0.start <= date.addingTimeInterval(15 * 60) && $0.end >= date.addingTimeInterval(-15 * 60)
        }.filter { !$0.title.isEmpty && $0.title != "タイトルなしの予定" }.sorted {
            let left = $0.start <= date && date < $0.end
            let right = $1.start <= date && date < $1.end
            if left != right { return left }
            let lhs =
                left
                ? abs($0.start.timeIntervalSince(date))
                : max($0.start.timeIntervalSince(date), date.timeIntervalSince($0.end))
            let rhs =
                right
                ? abs($1.start.timeIntervalSince(date))
                : max($1.start.timeIntervalSince(date), date.timeIntervalSince($1.end))
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }
    /// Prefer a meeting already in progress, then one starting within five minutes.
    /// Overlapping candidates require a human choice, regardless of their titles.
    static func event(at date: Date, events: [CalendarEvent]) -> CalendarEvent? {
        let ongoing = events.filter { $0.start <= date && date < $0.end }
        let candidates =
            ongoing.isEmpty
            ? events.filter { $0.start > date && $0.start.timeIntervalSince(date) <= 300 }
            : ongoing
        guard candidates.count == 1, let event = candidates.first,
            !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            event.title != "タイトルなしの予定"
        else { return nil }
        return event
    }
}

extension Meeting {
    static func defaultTitle(at date: Date) -> String {
        "会議 \(date.formatted(date: .numeric, time: .shortened))"
    }
    var needsCalendarTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == Self.defaultTitle(at: date)
    }
}

enum CalendarSchedule {
    static func conflicts(_ event: CalendarEvent, events: [CalendarEvent], preferences: CalendarPreferences) -> Bool {
        events.contains {
            $0.id != event.id && preferences.enabled($0)
                && preferences.selectedCalendars.contains($0.calendarID) && preferences.skipped[$0.id] == nil
                && $0.start < event.end && $0.end > event.start
        }
    }
    static func candidate(
        events: [CalendarEvent], preferences: CalendarPreferences, mac: String,
        now: Date, freshAt: Date?, available: Bool
    ) -> CalendarEvent? {
        guard available, preferences.automaticMac == mac, let freshAt,
            now.timeIntervalSince(freshAt) >= 0, now.timeIntervalSince(freshAt) < 90
        else { return nil }
        let upcoming = events.filter {
            preferences.selectedCalendars.contains($0.calendarID) && preferences.enabled($0)
                && preferences.skipped[$0.id] == nil && $0.start > now && $0.start.timeIntervalSince(now) <= 30
        }.sorted { $0.start < $1.start }
        // Overlapping auto-enabled meetings require the user to choose one; never pick an arbitrary title.
        guard let first = upcoming.first, !conflicts(first, events: events, preferences: preferences)
        else { return nil }
        return first
    }
}
