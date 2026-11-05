import AVFoundation
import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor final class CalendarIntegration: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var refreshing = false
    @Published private(set) var account = ""
    @Published private(set) var calendars: [GoogleCalendarInfo] = []
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var preferences = CalendarPreferences() { didSet { savePreferences() } }
    @Published private(set) var pending: CalendarCountdown?
    @Published private(set) var message: String?
    @Published private(set) var client: GoogleOAuthClient?
    @Published private(set) var lastRefresh: Date?
    private weak var store: Store?
    private let defaults: UserDefaults?
    private let api: GoogleCalendarClient
    private let login = CalendarLogin()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    private var lastTick: Date?
    private var lastAttempt = Date.distantPast
    private var suspended = false
    private var starting = false
    @Published private(set) var completingTitles: Set<UUID> = []
    private let beginRecording: (@MainActor (UUID) async -> Void)?
    private let saveMeeting: (@MainActor (UUID) async throws -> Void)?
    init(
        store: Store, defaults: UserDefaults?, api: GoogleCalendarClient = GoogleCalendarClient(),
        beginRecording: (@MainActor (UUID) async -> Void)? = nil,
        saveMeeting: (@MainActor (UUID) async throws -> Void)? = nil
    ) {
        self.store = store
        self.defaults = defaults
        self.api = api
        self.beginRecording = beginRecording
        self.saveMeeting = saveMeeting
        if let data = defaults?.data(forKey: "calendar.preferences"),
            let saved = try? JSONDecoder().decode(CalendarPreferences.self, from: data)
        {
            preferences = saved
        }
        account = defaults?.string(forKey: "calendar.account") ?? ""
        if let file = Bundle.main.url(forResource: "GoogleCalendarOAuth", withExtension: "json"),
            let data = try? Data(contentsOf: file)
        {
            client = try? GoogleOAuthClient.imported(data)
        }
    }
    var automatic: Bool { preferences.automaticMac != nil && preferences.automaticMac == store?.thisMac }
    var today: [CalendarEvent] { events.filter { Calendar.current.isDateInToday($0.start) && $0.end > Date() } }
    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults?.set(data, forKey: "calendar.preferences")
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.suspended = true
                        self?.clearPending()
                    }
                })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.suspended = false
                        self?.lastRefresh = nil
                        self?.lastTick = nil
                        Task { await self?.refresh() }
                    }
                })
        }
        Task { await restoreConnection() }
    }
    func restoreConnection() async {
        let epoch = generation
        do {
            let restored = try await api.restore()
            guard epoch == generation else { return }
            connected = restored
            if restored { await refresh() }
        } catch { if epoch == generation { message = error.localizedDescription } }
    }
    func shutdown() {
        generation += 1
        login.cancel()
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        clearPending()
    }
    func connect() async {
        guard !connecting, !connected, let client else { return }
        connecting = true
        message = nil
        generation += 1
        let epoch = generation
        defer { if epoch == generation { connecting = false } }
        do {
            let code = try await login.authorize(client)
            guard epoch == generation else { return }
            try await api.connect(client: client, code: code.value, verifier: code.verifier, redirect: code.redirect)
            guard epoch == generation else { return }
            connected = true
            await refresh()
        } catch is CancellationError {
        } catch { if epoch == generation { message = error.localizedDescription } }
    }
    func cancelLogin() async {
        generation += 1
        let epoch = generation
        login.cancel()
        do { try await api.disconnect() } catch {
            if epoch == generation { message = error.localizedDescription }
        }
        if epoch == generation { connecting = false }
    }
    func disconnect() async {
        generation += 1
        login.cancel()
        clearPending()
        connected = false
        connecting = false
        events = []
        calendars = []
        preferences = CalendarPreferences()
        account = ""
        defaults?.removeObject(forKey: "calendar.account")
        lastRefresh = nil
        do {
            try await api.disconnect()
            message = nil
        } catch { message = error.localizedDescription }
    }
    @discardableResult func refresh() async -> Bool {
        guard connected, !refreshing else { return false }
        refreshing = true
        lastAttempt = Date()
        let epoch = generation
        defer { refreshing = false }
        do {
            let list = try await api.calendars()
            guard epoch == generation, connected else { return false }
            guard let primary = list.first(where: { $0.primary == true }) else {
                throw AppError.message("メインのカレンダーを取得できません。Google連携をやり直してください。")
            }
            if primary.id != account {
                account = primary.id
                defaults?.set(account, forKey: "calendar.account")
                preferences = CalendarPreferences(selectedCalendars: [primary.id])
                clearPending()
            }
            calendars = list
            let selected = preferences.selectedCalendars.intersection(Set(list.map(\.id)))
            let items = try await api.events(calendars: selected)
            guard epoch == generation, connected,
                selected == preferences.selectedCalendars.intersection(Set(calendars.map(\.id)))
            else { return false }
            events = items
            lastRefresh = Date()
            message = nil
            if let pending, !items.contains(pending.event) { clearPending() }
            return true
        } catch {
            if epoch == generation {
                lastRefresh = nil
                clearPending()
                message = error.localizedDescription
            }
            return false
        }
    }
    func selectCalendar(_ id: String, selected: Bool) {
        if selected { preferences.selectedCalendars.insert(id) } else { preferences.selectedCalendars.remove(id) }
        clearPending()
        lastRefresh = nil
        Task { await refresh() }
    }
    func useTitle(_ enabled: Bool) { preferences.useTitle = enabled }
    func titleSuggestions(for meeting: Meeting) async throws -> [CalendarEvent] {
        guard connected, preferences.useTitle else { return [] }
        let epoch = generation
        let selected = preferences.selectedCalendars
        guard !selected.isEmpty else { return [] }
        let items = try await api.events(calendars: selected, now: meeting.date, window: 15 * 60)
        guard !Task.isCancelled, connected, epoch == generation, preferences.useTitle,
            selected == preferences.selectedCalendars
        else { return [] }
        return CalendarTitleMatch.suggestions(at: meeting.date, events: items)
    }
    /// Query around the original recording date, even for a meeting saved on a previous day.
    /// This runs after capture starts so Calendar latency never delays recording.
    func completeTitle(for id: UUID, reportResult: Bool = false) async {
        guard connected, preferences.useTitle, let store, !store.shuttingDown,
            let before = store.meetings.first(where: { $0.id == id }), before.needsCalendarTitle,
            before.capture != .planned, store.editingTitle != id, !completingTitles.contains(id)
        else { return }
        let epoch = generation
        let selected = preferences.selectedCalendars
        guard !selected.isEmpty else {
            if reportResult { store.error = "設定でタイトル補完に使うカレンダーを選んでください。" }
            return
        }
        completingTitles.insert(id)
        defer { completingTitles.remove(id) }
        do {
            let items = try await api.events(calendars: selected, now: before.date, window: 15 * 60)
            guard epoch == generation, connected, preferences.useTitle,
                selected == preferences.selectedCalendars, !store.shuttingDown,
                let current = store.meetings.first(where: { $0.id == id }),
                current.title == before.title, current.date == before.date, store.editingTitle != id
            else { return }
            guard let event = CalendarTitleMatch.event(at: before.date, events: items) else {
                if reportResult {
                    store.error = "録音開始時刻に対応する予定を1件に絞れませんでした。予定がないか、同じ時間帯に複数の予定があります。"
                }
                return
            }
            store.renameMeeting(id, to: event.title)
            // A manually started meeting must not be recorded again by the scheduler.
            if preferences.meetings[event.id] == nil { preferences.meetings[event.id] = id }
            skip(event)
            try await store.checkpoint(id)
            if reportResult { store.status = "カレンダーの予定名で会議タイトルを補完しました。" }
        } catch {
            if reportResult, epoch == generation { store.error = error.localizedDescription }
        }
    }
    func setAutomatic(_ enabled: Bool) {
        preferences.automaticMac = enabled ? store?.thisMac : nil
        clearPending()
        if enabled, Bundle.main.bundleURL.pathExtension == "app" {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
    }
    func setEvent(_ event: CalendarEvent, enabled: Bool, series: Bool = false) {
        if series, let id = event.seriesKey {
            if enabled { preferences.automaticSeries.insert(id) } else { preferences.automaticSeries.remove(id) }
        } else {
            if enabled {
                preferences.automaticEvents.insert(event.id)
            } else {
                preferences.automaticEvents.remove(event.id)
            }
        }
        clearPending()
    }
    func skip(_ event: CalendarEvent) {
        preferences.skipped[event.id] = Date()
        clearPending()
    }
    func undoSkip(_ event: CalendarEvent) { preferences.skipped[event.id] = nil }
    private func clearPending() {
        pending = nil
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["calendar-start"])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["calendar-start"])
        }
    }
    private func announce(_ event: CalendarEvent) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = "ギジログ：まもなく録音を開始します"
        content.body =
            "「\(event.title)」を\(event.start.formatted(date: .omitted, time: .shortened))から録音します。今回は録音しない場合はギジログでスキップしてください。"
        Task {
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "calendar-start", content: content, trigger: nil))
        }
    }
    func tick(now: Date = Date()) async {
        guard connected, !suspended, let store, store.ready, !store.shuttingDown else { return }
        let gap = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now
        if gap > 10 || gap < 0 {
            clearPending()
            lastRefresh = nil
        }
        if now.timeIntervalSince(lastAttempt) >= 60, !refreshing { await refresh() }
        guard !starting else { return }
        let available = !store.recording && !store.busy && store.hasKey && !suspended
        guard automatic, available else {
            clearPending()
            return
        }
        if let countdown = pending {
            let event = countdown.event
            guard events.contains(event), preferences.selectedCalendars.contains(event.calendarID),
                preferences.enabled(event),
                preferences.skipped[event.id] == nil
            else {
                clearPending()
                return
            }
            if now >= event.start {
                guard !refreshing else { return }
                starting = true
                defer { starting = false }
                // Fetch again at the boundary: cancellations, rescheduling and lost access cancel the start.
                let refreshed = await refresh()
                guard refreshed, pending == countdown, automatic, !suspended,
                    Date() >= event.start,
                    Date().timeIntervalSince(event.start) < 30,
                    events.contains(event), !store.recording, !store.busy,
                    !CalendarSchedule.conflicts(event, events: events, preferences: preferences)
                else {
                    clearPending()
                    return
                }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    skip(event)
                    message = "自動録音にはマイクの許可が必要です。先に一度、手動で録音してください。"
                    return
                }
                await record(event, automatically: true)
            }
        } else if let event = CalendarSchedule.candidate(
            events: events, preferences: preferences, mac: store.thisMac,
            now: now, freshAt: lastRefresh, available: available)
        {
            pending = CalendarCountdown(event: event, announcedAt: now)
            announce(event)
        }
    }
    func record(_ event: CalendarEvent, automatically: Bool = false) async {
        guard let store, store.ready, !store.recording, !store.busy, store.hasKey, !store.shuttingDown else { return }
        if let id = preferences.meetings[event.id], store.meetings.contains(where: { $0.id == id }) {
            store.selected = id
            message = "この予定の会議は作成済みです。続きは会議の「続けて録音」から開始できます。"
            skip(event)
            return
        }
        // Reserve capture before saving: another event or a manual recording must not win this await.
        store.busy = true
        defer { store.busy = false }
        let epoch = generation
        let selected = preferences.selectedCalendars
        skip(event)  // Persist before awaiting: stopping or restarting must never launch this instance again.
        let skippedAt = preferences.skipped[event.id]
        let id = store.prepareCalendarMeeting(title: preferences.useTitle ? event.title : nil)
        preferences.meetings[event.id] = id
        do {
            if let saveMeeting { try await saveMeeting(id) } else { try await store.checkpoint(id) }
        } catch {
            store.error = error.localizedDescription
            return
        }
        guard epoch == generation, !suspended, !store.shuttingDown, !store.recording,
            selected == preferences.selectedCalendars, preferences.skipped[event.id] == skippedAt
        else { return }
        if automatically {
            guard connected, automatic, preferences.enabled(event), events.contains(event),
                Date().timeIntervalSince(event.start) < 30
            else { return }
        }
        store.busy = false  // Store.start claims capture synchronously before its first suspension.
        if let beginRecording { await beginRecording(id) } else { await store.start(prepared: id) }
    }
}

extension Store {
    func prepareCalendarMeeting(title: String?) -> UUID {
        var meeting = newMeeting(capture: .planned)
        if let title { meeting.title = title }
        meetings.insert(meeting, at: 0)
        return meeting.id
    }
}
