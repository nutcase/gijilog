import Foundation

private final class CalendarMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ data: Data?) { self.data = data }
    func read() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
    func write(_ value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }
    var vault: CalendarVault { CalendarVault(read: { self.read() }, write: { self.write($0) }) }
}
private final class CalendarHTTP: URLProtocol {
    static let lock = NSLock()
    static var respond: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.googleapis.com" || request.url?.host == "oauth2.googleapis.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.respond
            Self.lock.unlock()
            guard let handler, let url = request.url else { throw URLError(.badURL) }
            let (code, body) = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func use(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> URLSession {
        lock.lock()
        respond = handler
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarHTTP.self]
        return URLSession(configuration: config)
    }
}
extension ProcessingTests {
    @MainActor func testCalendarStartReservationAndCancellation() async throws {
        for action in ["disconnect", "disable", "unselect", "skip", "normal"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = Store(root: root, loadSettings: false)
            store.key = "TEST"
            let start = Date().addingTimeInterval(-1)
            let formatter = ISO8601DateFormatter()
            let session = CalendarHTTP.use { request in
                if request.url?.path.hasSuffix("calendarList") == true {
                    return (200, #"{"items":[{"id":"primary","primary":true}]}"#)
                }
                return (
                    200,
                    "{\"items\":[{\"id\":\"one\",\"summary\":\"定例\",\"start\":{\"dateTime\":\"\(formatter.string(from: start))\"},\"end\":{\"dateTime\":\"\(formatter.string(from: start.addingTimeInterval(3600)))\"}}]}"
                )
            }
            defer { session.invalidateAndCancel() }
            let credential = GoogleCredential(
                accessToken: "synthetic", refreshToken: "synthetic", expires: Date().addingTimeInterval(3600),
                client: GoogleOAuthClient(clientID: "test.apps.googleusercontent.com", clientSecret: nil))
            let memory = CalendarMemory(try JSONEncoder().encode(credential))
            var duringSave: (@MainActor () async -> Void)?
            var started: [UUID] = []
            let calendar = CalendarIntegration(
                store: store, defaults: nil,
                api: GoogleCalendarClient(session: session, vault: memory.vault),
                beginRecording: { started.append($0) },
                saveMeeting: { id in
                    try Self.check(store.busy, "calendar reserves recording while saving")
                    try await store.checkpoint(id)
                    await duringSave?()
                })
            await calendar.restoreConnection()
            let event = try Self.require(calendar.events.first, "event to start")
            calendar.setAutomatic(true)
            calendar.setEvent(event, enabled: true)
            duringSave = {
                await calendar.record(self.calendarEvent("second", start: start))
                switch action {
                case "disconnect": await calendar.disconnect()
                case "disable": calendar.setAutomatic(false)
                case "unselect": calendar.setEvent(event, enabled: false)
                case "skip": calendar.skip(event)
                default: break
                }
            }
            await calendar.record(event, automatically: true)
            duringSave = nil
            try Self.check(
                started.count == (action == "normal" ? 1 : 0),
                "settings changed during saving cancel capture: \(action)")
            try Self.check(
                store.meetings.count == 1 && !store.busy,
                "a second event cannot create a skipped phantom meeting, and reservation is released")
            await calendar.disconnect()
            await store.flushCheckpoints()
        }
    }
    func testCalendarTitleMatching() throws {
        let now = try Self.require(GoogleEvent.date("2026-11-05T12:00:00+09:00"), "fixed recording time")
        let ongoing = calendarEvent(start: now.addingTimeInterval(-1200))
        let soon = calendarEvent("soon", start: now.addingTimeInterval(180))
        try Self.check(
            CalendarTitleMatch.event(at: now, events: [soon, ongoing]) == ongoing,
            "a meeting already in progress wins over the next meeting")
        try Self.check(
            CalendarTitleMatch.event(at: soon.start.addingTimeInterval(-300), events: [soon]) == soon
                && CalendarTitleMatch.event(at: soon.start.addingTimeInterval(-301), events: [soon]) == nil,
            "early recording matches only within five minutes")
        try Self.check(
            CalendarTitleMatch.event(at: ongoing.end, events: [ongoing]) == nil,
            "an event ending exactly at recording start is not a match")
        let overlap = calendarEvent("overlap", start: now.addingTimeInterval(-600))
        try Self.check(
            CalendarTitleMatch.event(at: now, events: [ongoing, overlap]) == nil,
            "overlapping meetings with identical titles still require a choice")
        let tomorrow = calendarEvent("tomorrow", start: now.addingTimeInterval(86400))
        let suggestions = CalendarTitleMatch.suggestions(at: now, events: [tomorrow, soon, ongoing])
        try Self.check(
            suggestions.first == ongoing && !suggestions.contains(tomorrow),
            "manual suggestions prioritize the recording time and exclude other days")
    }
    func testCalendarSuggestionTimeWindow() throws {
        let date = try Self.require(GoogleEvent.date("2026-11-05T12:00:00+09:00"), "recording time")
        let ongoing = calendarEvent("ongoing", start: date.addingTimeInterval(-1800))
        let justEnded = calendarEvent("ended", start: date.addingTimeInterval(-3600 - 900))
        let tooOld = calendarEvent("old", start: date.addingTimeInterval(-3600 - 901))
        let soon = calendarEvent("soon", start: date.addingTimeInterval(900))
        let tooLate = calendarEvent("late", start: date.addingTimeInterval(901))
        let yesterday = calendarEvent("yesterday", start: date.addingTimeInterval(-86400))
        let tomorrow = calendarEvent("tomorrow", start: date.addingTimeInterval(86400))
        let result = CalendarTitleMatch.suggestions(
            at: date, events: [tooLate, tooOld, yesterday, tomorrow, soon, justEnded, ongoing])
        try Self.check(
            result.first == ongoing && Set(result.map(\.id)) == Set([ongoing.id, justEnded.id, soon.id]),
            "suggestions include only ongoing events and the inclusive fifteen-minute boundaries")
        try Self.check(
            CalendarTitleMatch.suggestions(at: date, events: [tooOld, tooLate]).isEmpty,
            "no nearby match does not fall back to other same-day events")
        let midnight = try Self.require(GoogleEvent.date("2026-11-06T00:05:00+09:00"), "midnight recording")
        let overnight = calendarEvent("overnight", start: midnight.addingTimeInterval(-1800))
        let recentlyEnded = calendarEvent("previous-day", start: midnight.addingTimeInterval(-3600 - 600))
        try Self.check(
            CalendarTitleMatch.suggestions(at: midnight, events: [recentlyEnded, overnight]).count == 2,
            "nearby events across midnight remain candidates")
    }
    @MainActor func testCalendarTitleCompletionAndSuggestions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        let date = try Self.require(GoogleEvent.date("2026-10-15T09:10:00+09:00"), "recorded date")
        var meeting = Meeting(title: Meeting.defaultTitle(at: date))
        meeting.date = date
        meeting.capture = .stopped
        meeting.clockStart = date.addingTimeInterval(86400)
        store.meetings = [meeting]
        let mode = CalendarMemory(Data("ok".utf8))
        let expectedMin = ISO8601DateFormatter().string(from: date.addingTimeInterval(-901))
        let session = CalendarHTTP.use { request in
            if request.url?.path.hasSuffix("calendarList") == true {
                return (200, #"{"items":[{"id":"primary","primary":true}]}"#)
            }
            let query = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)
            // Background upcoming refresh is allowed; completion must query the historical recording date.
            if query?.queryItems?.first(where: { $0.name == "timeMin" })?.value != expectedMin {
                return (200, #"{"items":[]}"#)
            }
            try Self.check(
                query?.queryItems?.first(where: { $0.name == "timeMax" })?.value
                    == ISO8601DateFormatter().string(from: date.addingTimeInterval(901)),
                "title lookup fetches only the recording time window")
            let state = String(decoding: mode.read() ?? Data(), as: UTF8.self)
            if state == "fail" { return (503, "{}") }
            let event =
                #"{"id":"event","summary":"設計レビュー","start":{"dateTime":"2026-10-15T09:00:00+09:00"},"end":{"dateTime":"2026-10-15T10:00:00+09:00"}}"#
            return (
                200,
                "{\"items\":[" + event
                    + (state == "overlap" ? "," + event.replacingOccurrences(of: "event", with: "other") : "") + "]}"
            )
        }
        defer { session.invalidateAndCancel() }
        let credential = GoogleCredential(
            accessToken: "synthetic", refreshToken: "synthetic", expires: Date().addingTimeInterval(3600),
            client: GoogleOAuthClient(clientID: "test.apps.googleusercontent.com", clientSecret: nil))
        let memory = CalendarMemory(try JSONEncoder().encode(credential))
        let calendar = CalendarIntegration(
            store: store, defaults: nil, api: GoogleCalendarClient(session: session, vault: memory.vault))
        await calendar.restoreConnection()
        let candidates = try await calendar.titleSuggestions(for: meeting)
        try Self.check(candidates.first?.title == "設計レビュー", "manual suggestions use the original recording date")
        await calendar.completeTitle(for: meeting.id)
        try Self.check(store.meetings.first?.title == "設計レビュー", "saved default titles are completed from Calendar")
        try Self.check(
            calendar.preferences.meetings[candidates[0].id] == meeting.id
                && calendar.preferences.skipped[candidates[0].id] != nil,
            "inferred events are linked and cannot start another automatic recording")
        store.renameMeeting(meeting.id, to: "自分で入力した名前")
        await calendar.completeTitle(for: meeting.id)
        try Self.check(store.meetings.first?.title == "自分で入力した名前", "manual titles are preserved")
        store.renameMeeting(meeting.id, to: meeting.title)
        calendar.useTitle(false)
        await calendar.completeTitle(for: meeting.id)
        let disabled = try await calendar.titleSuggestions(for: meeting)
        try Self.check(
            store.meetings.first?.title == meeting.title && disabled.isEmpty, "title opt-out disables both paths")
        calendar.useTitle(true)
        mode.write(Data("overlap".utf8))
        await calendar.completeTitle(for: meeting.id)
        let ambiguous = try await calendar.titleSuggestions(for: meeting)
        try Self.check(
            store.meetings.first?.title == meeting.title && ambiguous.count == 2,
            "ambiguous events are offered manually without automatic renaming")
        mode.write(Data("fail".utf8))
        await calendar.completeTitle(for: meeting.id)
        try Self.check(store.meetings.first?.title == meeting.title, "Calendar failures preserve the title")
        await calendar.disconnect()
        await store.flushCheckpoints()
    }
    @MainActor func testCalendarLoopbackLogin() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var callbackTask: Task<Void, Error>?
        let login = CalendarLogin { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
                let state = items.first(where: { $0.name == "state" })?.value,
                let callback = URL(string: redirect + "?code=synthetic-code&state=" + state)
            else { return false }
            callbackTask = Task {
                let (_, response) = try await session.data(from: callback)
                try Self.check((response as? HTTPURLResponse)?.statusCode == 200, "loopback callback returns success")
            }
            return true
        }
        let code = try await login.authorize(
            GoogleOAuthClient(clientID: "test.apps.googleusercontent.com", clientSecret: nil))
        try await callbackTask?.value
        try Self.check(
            code.value == "synthetic-code" && code.verifier.count == 43, "loopback delivers the code and PKCE verifier")
        let blocked = CalendarLogin { _ in false }
        var failed = false
        do {
            _ = try await blocked.authorize(
                GoogleOAuthClient(clientID: "test.apps.googleusercontent.com", clientSecret: nil))
        } catch { failed = true }
        try Self.check(failed, "a browser-open failure ends authorization")
    }
    @MainActor func testCalendarRefreshCancelsPendingStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        store.key = "TEST"
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: now.addingTimeInterval(20))
        let end = formatter.string(from: now.addingTimeInterval(3600))
        let snapshot = CalendarMemory(Data("present".utf8))
        let session = CalendarHTTP.use { request in
            if request.url?.path.hasSuffix("calendarList") == true {
                return (200, #"{"items":[{"id":"me@example.test","primary":true}]}"#)
            }
            let mode = String(decoding: snapshot.read() ?? Data(), as: UTF8.self)
            if mode == "failure" { return (503, "{}") }
            if mode == "cancelled" { return (200, #"{"items":[]}"#) }
            return (
                200,
                "{\"items\":[{\"id\":\"event\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}]}"
            )
        }
        defer { session.invalidateAndCancel() }
        let credential = GoogleCredential(
            accessToken: "synthetic", refreshToken: "synthetic", expires: now.addingTimeInterval(3600),
            client: GoogleOAuthClient(clientID: "test.apps.googleusercontent.com", clientSecret: nil))
        let memory = CalendarMemory(try JSONEncoder().encode(credential))
        let api = GoogleCalendarClient(session: session, vault: memory.vault)
        var started: [UUID] = []
        let calendar = CalendarIntegration(
            store: store, defaults: nil, api: api, beginRecording: { started.append($0) })
        await calendar.restoreConnection()
        let event = try Self.require(calendar.events.first, "loaded calendar event")
        calendar.setAutomatic(true)
        calendar.setEvent(event, enabled: true)
        await calendar.tick()
        try Self.check(calendar.pending?.event == event, "a fresh enabled event announces")
        snapshot.write(Data("cancelled".utf8))
        await calendar.refresh()
        try Self.check(
            calendar.pending == nil && calendar.events.isEmpty && started.isEmpty,
            "cancelling an event clears the countdown")
        snapshot.write(Data("present".utf8))
        await calendar.refresh()
        await calendar.tick()
        try Self.check(calendar.pending != nil, "restoring the event permits a new countdown")
        snapshot.write(Data("failure".utf8))
        await calendar.refresh()
        try Self.check(
            calendar.pending == nil && calendar.lastRefresh == nil && calendar.message != nil,
            "a failed refresh invalidates the countdown and snapshot")
        await calendar.disconnect()
        try Self.check(
            !calendar.connected && !calendar.automatic && calendar.events.isEmpty && memory.read() == nil,
            "disconnect disables scheduling and clears credentials")
    }
    private func calendarEvent(_ id: String = "one", start: Date, calendar: String = "primary", series: String? = nil)
        -> CalendarEvent
    {
        CalendarEvent(
            calendarID: calendar, eventID: id, seriesID: series, title: "週次定例", start: start,
            end: start.addingTimeInterval(3600), meetingURL: nil)
    }
    @MainActor func testCalendarOAuthConfigurationAndCallback() throws {
        let config = try GoogleOAuthClient.imported(
            Data(
                #"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"public-desktop-config"}}"#
                    .utf8))
        let url = try CalendarLogin.authorizationURL(
            client: config, redirect: "http://127.0.0.1:1234/oauth/callback",
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "unique-state")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        try Self.check(
            items.first { $0.name == "code_challenge" }?.value == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "PKCE matches the RFC 7636 vector")
        try Self.check(CalendarLogin.scopes.allSatisfy { $0.hasSuffix(".readonly") }, "calendar access is read-only")
        let accepted = try CalendarLogin.callback(
            "/oauth/callback?code=valid&state=unique-state", state: "unique-state")
        let rejected = try CalendarLogin.callback("/oauth/callback?code=bad&state=someone-else", state: "unique-state")
        let duplicate = try CalendarLogin.callback(
            "/oauth/callback?code=a&code=b&state=unique-state", state: "unique-state")
        try Self.check(
            accepted == "valid" && rejected == nil && duplicate == nil,
            "only one code with this login's state is accepted")
        var cancelled = false
        do {
            _ = try CalendarLogin.callback(
                "/oauth/callback?error=access_denied&state=unique-state", state: "unique-state")
        } catch { cancelled = true }
        try Self.check(cancelled, "denying consent ends login")
        let form = String(decoding: GoogleCalendarClient.form(["code": "a+b&c=d"]), as: UTF8.self)
        try Self.check(
            form.contains("%2B") && form.contains("%26"), "form encoding cannot turn code characters into parameters")
    }
    func testCalendarEventFilteringAndTimeZones() throws {
        let base =
            #"{"id":"instance","summary":"定例","start":{"dateTime":"2026-11-05T09:00:00+09:00"},"end":{"dateTime":"2026-11-05T01:00:00Z"},"recurringEventId":"series","hangoutLink":"https://meet.google.com/abc-defg-hij"}"#
        let event = try Self.require(
            try JSONDecoder().decode(GoogleEvent.self, from: Data(base.utf8)).event(calendarID: "work"), "timed event")
        try Self.check(
            event.end.timeIntervalSince(event.start) == 3600 && event.meetingURL?.host == "meet.google.com",
            "offset dates and meeting URL survive")
        let variants = [
            base.replacingOccurrences(of: #""summary":"定例""#, with: #""status":"cancelled""#),
            base.replacingOccurrences(of: #""summary":"定例""#, with: #""eventType":"outOfOffice""#),
            base.replacingOccurrences(
                of: #""summary":"定例""#, with: #""attendees":[{"self":true,"responseStatus":"declined"}]"#),
            #"{"id":"all-day","start":{"date":"2026-11-05"},"end":{"date":"2026-11-06"}}"#,
        ]
        for value in variants {
            let ignored = try JSONDecoder().decode(GoogleEvent.self, from: Data(value.utf8)).event(calendarID: "work")
            try Self.check(ignored == nil, "cancelled, declined, all-day and out-of-office events are excluded")
        }
        try Self.check(
            GoogleEvent.safeURL("file:///etc/passwd") == nil && GoogleEvent.safeURL("javascript:alert(1)") == nil,
            "calendar links cannot launch arbitrary schemes")
        try Self.check(
            CalendarEvent.key(["a:b", "c"]) != CalendarEvent.key(["a", "b:c"]),
            "event keys cannot collide across calendars")
    }
    func testCalendarSchedulingGuards() throws {
        let now = Date()
        let event = calendarEvent(start: now.addingTimeInterval(20), series: "weekly")
        var prefs = CalendarPreferences(
            selectedCalendars: ["primary"], automaticMac: "this-mac", automaticSeries: [event.seriesKey ?? ""])
        func candidate(
            _ events: [CalendarEvent] = [], mac: String = "this-mac", at: Date? = nil, fresh: Date? = nil,
            available: Bool = true
        ) -> CalendarEvent? {
            CalendarSchedule.candidate(
                events: events.isEmpty ? [event] : events, preferences: prefs, mac: mac,
                now: at ?? now, freshAt: fresh ?? now, available: available)
        }
        try Self.check(candidate() == event, "an enabled recurring instance announces before its start")
        try Self.check(
            candidate(mac: "another-mac") == nil && candidate(available: false) == nil,
            "another device or recording cannot start")
        try Self.check(candidate(at: now.addingTimeInterval(21)) == nil, "waking after the start does not catch up")
        try Self.check(candidate(fresh: now.addingTimeInterval(-100)) == nil, "stale schedules cannot start")
        let overlapping = calendarEvent("two", start: now.addingTimeInterval(25))
        prefs.automaticEvents.insert(overlapping.id)
        try Self.check(candidate([event, overlapping]) == nil, "overlapping meetings require a choice")
        prefs.skipped[overlapping.id] = now
        try Self.check(candidate([event, overlapping]) == event, "skipping the other meeting resolves an overlap")
        prefs.skipped[event.id] = now
        let restored = try JSONDecoder().decode(CalendarPreferences.self, from: JSONEncoder().encode(prefs))
        try Self.check(
            restored.skipped[event.id] != nil && candidate() == nil,
            "stopped or skipped instances stay skipped after restart")
        prefs.skipped = [:]
        prefs.selectedCalendars = []
        try Self.check(candidate() == nil, "unselected calendars cannot start")
    }
    func testGoogleCalendarPaginationAndRefresh() async throws {
        let saved = GoogleCredential(
            accessToken: "expired", refreshToken: "synthetic-refresh", expires: .distantPast,
            client: GoogleOAuthClient(clientID: "test.apps.googleusercontent.com", clientSecret: nil))
        let memory = CalendarMemory(try JSONEncoder().encode(saved))
        let session = CalendarHTTP.use { request in
            if request.url?.host == "oauth2.googleapis.com" {
                return (200, #"{"access_token":"fresh","expires_in":3600}"#)
            }
            try Self.check(
                request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh", "requests use the refreshed token"
            )
            if request.url?.path.hasSuffix("calendarList") == true {
                if request.url?.query?.contains("pageToken=next") == true {
                    return (200, #"{"items":[{"id":"other","summary":"共有"}]}"#)
                }
                return (200, #"{"items":[{"id":"me@example.test","primary":true}],"nextPageToken":"next"}"#)
            }
            if request.url?.query?.contains("pageToken=events2") == true { return (200, #"{"items":[]}"#) }
            return (
                200,
                #"{"items":[{"id":"e","summary":"定例","start":{"dateTime":"2026-11-05T09:00:00+09:00"},"end":{"dateTime":"2026-11-05T10:00:00+09:00"}}],"nextPageToken":"events2"}"#
            )
        }
        defer { session.invalidateAndCancel() }
        let api = GoogleCalendarClient(session: session, vault: memory.vault)
        let exists = try await api.restore()
        let list = try await api.calendars()
        let events = try await api.events(calendars: ["me@example.test"])
        try Self.check(exists && list.count == 2 && events.count == 1, "all calendar and event pages are read")
        let stored = try JSONDecoder().decode(
            GoogleCredential.self, from: Self.require(memory.read(), "saved refreshed token"))
        try Self.check(
            stored.refreshToken == "synthetic-refresh" && stored.accessToken == "fresh",
            "refresh retains an omitted refresh token")
        try await api.disconnect()
        try Self.check(memory.read() == nil, "disconnect removes this Mac's credential")
    }
    @MainActor func testCalendarRecordingUsesExplicitMeetingAndKeepsEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root, loadSettings: false)
        store.key = "TEST"
        let unrelated = store.prepareCalendarMeeting(title: "いま見ている別会議")
        store.selected = unrelated
        var started: [UUID] = []
        let calendar = CalendarIntegration(store: store, defaults: nil, beginRecording: { started.append($0) })
        let event = calendarEvent(start: Date())
        await calendar.record(event)
        let id = try Self.require(started.first, "explicit recording target")
        try Self.check(
            id != unrelated && store.meetings.first { $0.id == id }?.title == event.title,
            "the scheduled meeting starts regardless of the selected meeting")
        store.renameMeeting(id, to: "手で変更したタイトル")
        await calendar.record(event)
        try Self.check(
            started.count == 1 && store.meetings.first { $0.id == id }?.title == "手で変更したタイトル",
            "repeated clicks neither duplicate the meeting nor overwrite a hand edit")
        await store.flushCheckpoints()
    }
}
