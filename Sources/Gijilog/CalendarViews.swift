import AppKit
import SwiftUI

struct CalendarSettings: View {
    @ObservedObject var calendar: CalendarIntegration
    var body: some View {
        Form {
            Section("Googleアカウント") {
                if calendar.connected {
                    LabeledContent("接続中", value: calendar.account.isEmpty ? "接続を確認中…" : calendar.account)
                    HStack {
                        Button("予定を更新") { Task { await calendar.refresh() } }.disabled(calendar.refreshing)
                        Button("このMacの連携を解除") { Task { await calendar.disconnect() } }
                    }
                } else {
                    Button(calendar.connecting ? "ブラウザで認証してください…" : "Googleと連携") { Task { await calendar.connect() } }
                        .disabled(calendar.client == nil || calendar.connecting)
                    if calendar.connecting { Button("キャンセル") { Task { await calendar.cancelLogin() } } }
                    Text("カレンダーと予定の読み取りだけを許可します。Googleの予定を書き換えることはありません。")
                        .font(.caption).foregroundStyle(.secondary)
                    if calendar.client == nil {
                        Text("このバージョンではGoogle連携を利用できません。Google連携に対応したアプリに更新してください。")
                            .font(.callout)
                    }
                }
                if let message = calendar.message {
                    Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text("取り込んだ予定名は会議タイトルとして保存され、文字起こしやAI機能の利用時にOpenAIへ送信される場合があります。「予定名を会議タイトルに使う」をOFFにすると取り込みを止められます。")
                    .font(.caption).foregroundStyle(.secondary)
                if let privacy = URL(string: "https://nutcase.github.io/gijilog/privacy.html") {
                    Link("プライバシーポリシー", destination: privacy)
                }
            }
            if calendar.connected {
                Section("対象カレンダー") {
                    ForEach(calendar.calendars) { item in
                        Toggle(
                            item.title,
                            isOn: Binding(
                                get: { calendar.preferences.selectedCalendars.contains(item.id) },
                                set: { calendar.selectCalendar(item.id, selected: $0) }))
                    }
                }
                Section {
                    Toggle(
                        "予定名を会議タイトルに使う", isOn: Binding(get: { calendar.preferences.useTitle }, set: calendar.useTitle))
                    Text(
                        "通常の録音でも開始時刻から予定名を補完します。開始5分前から予定の終了までが対象です。手入力したタイトルや、候補が複数ある場合は変更しません。保存済みの会議は一覧の右クリックから補完できます。"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Toggle("このMacで自動録音を有効にする", isOn: Binding(get: { calendar.automatic }, set: calendar.setAutomatic))
                    Text("下の予定で自動録音をONにすると、開始時刻に録音します。開始30秒前からお知らせし、今回はスキップできます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("ギジログを起動し、Macがスリープしていない間に動作します。初回は手動で録音し、マイクとMac音声の許可を済ませてください。予定の終了時刻だけでは録音を止めません。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("録音")
                }
                Section("これから7日間の会議") {
                    if calendar.events.isEmpty { Text("対象の会議はありません").foregroundStyle(.secondary) }
                    ForEach(calendar.events.filter { $0.end > Date() }) { event in
                        CalendarEventRow(calendar: calendar, event: event, showDate: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 760)
    }
}
struct CalendarTitleButton: View {
    @ObservedObject var calendar: CalendarIntegration
    let meeting: Meeting
    var body: some View {
        if calendar.connected && calendar.preferences.useTitle && meeting.needsCalendarTitle
            && meeting.capture != .planned
        {
            Button("録音時刻から予定名を補完") {
                Task { await calendar.completeTitle(for: meeting.id, reportResult: true) }
            }
            .disabled(calendar.completingTitles.contains(meeting.id))
        }
    }
}
final class CalendarTitleDraft: ObservableObject {
    @Published var suggestions: [CalendarEvent] = []
    @Published var loading = false
    @Published var failed = false
}
struct CalendarTitleSuggestions: View {
    @ObservedObject var calendar: CalendarIntegration
    let meeting: Meeting
    let typed: String
    let choose: (String) -> Void
    @StateObject private var draft = CalendarTitleDraft()
    private var queryID: String {
        CalendarEvent.key(
            [
                meeting.id.uuidString, String(meeting.date.timeIntervalSince1970),
                String(calendar.connected), String(calendar.preferences.useTitle), calendar.account,
            ] + calendar.preferences.selectedCalendars.sorted())
    }
    var body: some View {
        let query =
            typed == Meeting.defaultTitle(at: meeting.date)
            ? "" : typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = draft.suggestions.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        VStack(alignment: .leading, spacing: 6) {
            if calendar.connected && calendar.preferences.useTitle {
                if draft.loading {
                    Text("カレンダーの候補を取得中…").foregroundStyle(.secondary)
                } else if draft.failed {
                    Text("予定を取得できませんでした。タイトルはそのまま入力できます。").foregroundStyle(.secondary)
                } else if !matches.isEmpty {
                    Text("録音時刻の前後15分の予定").foregroundStyle(.secondary)
                    ForEach(matches.prefix(5)) { event in
                        Button {
                            choose(event.title)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar")
                                Text(event.title).lineLimit(1)
                                Text(
                                    event.start.formatted(date: .abbreviated, time: .shortened)
                                        + " – "
                                        + event.end.formatted(
                                            date: Calendar.current.isDate(event.start, inSameDayAs: event.end)
                                                ? .omitted : .abbreviated,
                                            time: .shortened)
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                        .focusable(false)
                    }
                }
            }
        }
        .font(.callout)
        .task(id: queryID) {
            draft.suggestions = []
            draft.failed = false
            draft.loading = true
            do {
                let result = try await calendar.titleSuggestions(for: meeting)
                guard !Task.isCancelled else { return }
                draft.suggestions = result
            } catch {
                guard !Task.isCancelled else { return }
                draft.failed = true
            }
            draft.loading = false
        }
    }
}
struct CalendarEventRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject var calendar: CalendarIntegration
    let event: CalendarEvent
    var showDate = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(
                        event.start.formatted(date: showDate ? .abbreviated : .omitted, time: .shortened)
                            + " – " + event.end.formatted(date: .omitted, time: .shortened)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = event.meetingURL { Link("参加", destination: url).help("会議のリンクを開く") }
                if let id = calendar.preferences.meetings[event.id], store.meetings.contains(where: { $0.id == id }) {
                    Button("議事録を開く") { store.selected = id }
                } else {
                    Button("録音") { Task { await calendar.record(event) } }
                        .disabled(store.recording || store.busy || !store.ready || !store.hasKey)
                }
            }
            HStack {
                if let series = event.seriesKey {
                    Toggle(
                        "毎回自動録音",
                        isOn: Binding(
                            get: { calendar.preferences.automaticSeries.contains(series) },
                            set: { calendar.setEvent(event, enabled: $0, series: true) })
                    ).toggleStyle(.checkbox)
                }
                Toggle(
                    "この回を自動録音",
                    isOn: Binding(
                        get: { calendar.preferences.automaticEvents.contains(event.id) },
                        set: { calendar.setEvent(event, enabled: $0) })
                ).toggleStyle(.checkbox)
                Spacer()
                if calendar.preferences.meetings[event.id] == nil {
                    if calendar.preferences.skipped[event.id] != nil {
                        Button("スキップを解除") { calendar.undoSkip(event) }
                    } else if calendar.preferences.enabled(event) {
                        Button("今回はスキップ") { calendar.skip(event) }
                    }
                }
            }
            .font(.caption)
            if !calendar.automatic && calendar.preferences.enabled(event) {
                Text("自動録音は設定で有効にすると動作します").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
struct CalendarToday: View {
    @ObservedObject var calendar: CalendarIntegration
    var body: some View {
        if calendar.connected {
            VStack(alignment: .leading, spacing: 8) {
                if let pending = calendar.pending {
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { time in
                            Text(
                                "\(max(0, Int(pending.event.start.timeIntervalSince(time.date).rounded(.up))))秒後に「\(pending.event.title)」を録音"
                            )
                            .font(.callout.weight(.semibold))
                        }
                        Spacer()
                        Button("今回はスキップ") { calendar.skip(pending.event) }
                    }
                    .foregroundStyle(Palette.yamabuki)
                }
                DisclosureGroup("今日の会議（\(calendar.today.count)件）") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(calendar.today) { event in CalendarEventRow(calendar: calendar, event: event) }
                            if calendar.today.isEmpty { Text("これからの予定はありません").foregroundStyle(.secondary) }
                        }
                    }.frame(maxHeight: 180)
                }
                if let message = calendar.message { Text(message).font(.caption).foregroundStyle(Palette.yamabuki) }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            Divider()
        }
    }
}
