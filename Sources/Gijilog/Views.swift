import AppKit
import SwiftUI

// 藍と紅: the minutes are a paper sheet on an indigo desk, filled in as the meeting goes.
// Red is kept for the recording lamp and record button only.
// (View state lives in observable objects: the @State macro plugin is not part of the Command Line Tools.)
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
enum Palette {
    static let kon = Color(hex: 0x1B2238)  // The desk.
    static let ai = Color(hex: 0x26304D)  // Raised controls on the desk.
    static let deepAi = Color(hex: 0x141A2C)  // Sidebar and transcript panel.
    static let paper = Color(hex: 0xF2F3EF)
    static let sumi = Color(hex: 0x23262E)
    static let rule = Color(hex: 0xCDD2DB)
    static let beni = Color(hex: 0xE0394E)  // Recording.
    static let asagi = Color(hex: 0x2BA6A6)  // Working, done, and the latest update.
    static let yamabuki = Color(hex: 0xD9A13B)  // Needs attention.
}
extension Font {
    // Minutes are a formal document, so their headings are set in Mincho.
    static func mincho(_ size: CGFloat, bold: Bool = true) -> Font {
        .custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size)
    }
}
private let longDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "y年M月d日（E）H:mm"
    return formatter
}()
private let dayTitle: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "M月d日（E）"
    return formatter
}()
func statusColor(_ status: String) -> Color {
    if status.hasPrefix("録音中") { return Palette.beni }
    if status.contains("失敗") || status.contains("確認が必要") || status.contains("APIキー") { return Palette.yamabuki }
    if status.hasPrefix("完了") || ["処理中", "更新中", "再開中", "復旧中"].contains(where: status.contains) {
        return Palette.asagi
    }
    return .secondary
}
func sourceSymbol(_ source: String) -> String {
    source == "マイク" ? "mic.fill" : source == AudioImport.source ? "waveform" : "speaker.wave.2.fill"
}
extension Store {
    var selectedMeeting: Meeting? { meetings.first { $0.id == selected } }
    var activeMeeting: Meeting? { meetings.first { $0.id == activeID } }
}

// Switching views: the compact window replaces the full window, and its button brings the full window back.
struct ViewSwitch {
    let open: OpenWindowAction
    let dismiss: DismissWindowAction
    func compact() {
        open(id: "live")
        dismiss(id: "main")
    }
    func full() {
        open(id: "main")
        dismiss(id: "live")
    }
}
struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        NavigationSplitView {
            MeetingList().navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                RecorderBar()
                Rectangle().fill(Palette.ai).frame(height: 1)
                // The transcript is a plain trailing column: SwiftUI's inspector inside this split view
                // loops on layout and crashes the window (macOS 27 SDK).
                HStack(spacing: 0) {
                    Group {
                        if let meeting = store.selectedMeeting { MinutesDesk(meeting: meeting) } else { EmptyDesk() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.showsTranscript, let meeting = store.selectedMeeting {
                        Rectangle().fill(Palette.ai).frame(width: 1)
                        TranscriptPanel(meeting: meeting).frame(width: 320)
                    }
                }
            }
            .background(Palette.kon)
            // Dropping recordings on the window makes minutes from them.
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                store.importRecordings(urls)
                return true
            } isTargeted: {
                store.dropTargeted = $0
            }
            .overlay {
                if store.dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Palette.asagi, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.kon.opacity(0.85)))
                        .overlay {
                            Label("ここにドロップして、録音ファイルから議事録を作成", systemImage: "square.and.arrow.down")
                                .font(.title3).foregroundStyle(Palette.paper)
                        }
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            .toolbar { toolbar }
        }
        .preferredColorScheme(.dark)
        .alert("確認が必要です", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("閉じる") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .confirmationDialog(
            "会議をゴミ箱に移動しますか？",
            isPresented: Binding(get: { store.deletion != nil }, set: { if !$0 { store.deletion = nil } }),
            presenting: store.deletion
        ) { meeting in
            Button("ゴミ箱に移動", role: .destructive) { Task { await store.delete(meeting.id) } }
        } message: { meeting in
            Text("「\(meeting.title)」の録音・文字起こし・議事録をゴミ箱に移動します。")
        }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let meeting = store.selectedMeeting {
                let idle = meeting.id != store.activeID && !store.busy && !store.isProcessing(meeting.id)
                Button {
                    store.export(meeting)
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                .help("議事録と文字起こしをMarkdownで書き出す")
                .disabled(meeting.segments.isEmpty && meeting.notes == nil)
                Menu {
                    Button("未処理を再開", systemImage: "arrow.clockwise") { Task { await store.process() } }
                        .disabled(!idle || !store.hasKey)
                    Button("全文を再処理", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.process(rebuild: true) }
                    }.disabled(!idle || !store.hasKey)
                    Button("Finderで表示", systemImage: "folder") {
                        NSWorkspace.shared.open(store.folder(meeting.id))
                    }
                    Divider()
                    Button("ゴミ箱に移動…", systemImage: "trash", role: .destructive) { store.deletion = meeting }
                        .disabled(!store.canDelete(meeting.id))
                } label: {
                    Label("この会議", systemImage: "ellipsis.circle")
                }
                .help("この会議の操作")
            }
            Button {
                ViewSwitch(open: openWindow, dismiss: dismissWindow).compact()
            } label: {
                Label("小画面にする", systemImage: "pip.enter")
            }
            .help("会議の横に置いておける小さな画面に切り替える")
            Button {
                store.showsTranscript.toggle()
            } label: {
                Label("文字起こし", systemImage: "sidebar.right")
            }
            .help("文字起こしの表示を切り替える")
        }
    }
}

// MARK: - Sidebar

struct MeetingList: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List(selection: $store.selected) {
            ForEach(days, id: \.0) { title, meetings in
                Section(title) {
                    ForEach(meetings) { meeting in
                        MeetingRow(meeting: meeting).tag(meeting.id)
                            .contextMenu {
                                Button("ゴミ箱に移動…", role: .destructive) { store.deletion = meeting }
                                    .disabled(!store.canDelete(meeting.id))
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.deepAi)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .semibold))
                Text("ギジログ").font(.mincho(22))
                Spacer()
            }
            .foregroundStyle(Palette.paper)
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink { Label("設定", systemImage: "gearshape") }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }
    private var days: [(String, [Meeting])] {
        let calendar = Calendar.current
        var result: [(String, [Meeting])] = []
        for meeting in store.meetings {
            let title =
                calendar.isDateInToday(meeting.date)
                ? "今日" : calendar.isDateInYesterday(meeting.date) ? "昨日" : dayTitle.string(from: meeting.date)
            if result.last?.0 == title {
                result[result.count - 1].1.append(meeting)
            } else {
                result.append((title, [meeting]))
            }
        }
        return result
    }
}
struct MeetingRow: View {
    let meeting: Meeting
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(statusColor(meeting.status)).frame(width: 6, height: 6)
                Text(meeting.date.formatted(date: .omitted, time: .shortened))
                Text(meeting.status).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recorder bar

struct RecorderBar: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Group {
            if store.recording, let meeting = store.activeMeeting { live(meeting) } else { idle }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("会議のタイトル（空欄なら日時）", text: $store.title)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ai))
                    .disabled(store.busy)
                    .onSubmit(start)
                Button {
                    store.chooseRecordingFiles()
                } label: {
                    Label("ファイルから作成", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(CapsuleButtonStyle(filled: false, tint: Palette.paper))
                .fixedSize()
                .help("録音ファイル（音声・動画）から議事録を作る。ウインドウにドロップしても作れます")
                .disabled(!store.ready || !store.hasKey)
                Button(action: start) { Label("録音を開始", systemImage: "record.circle") }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .fixedSize()
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.busy || !store.ready || !store.hasKey)
                if store.busy || store.importing { ProgressView().controlSize(.small) }
            }
            if store.hasKey {
                Text("Macの音声とマイクを録音し、OpenAIで文字起こしと議事録づくりをします。録音ファイルはドロップしても読み込めます。API利用料がかかります。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(Palette.yamabuki)
                    Text("録音するには、OpenAIのAPIキーを設定してください。")
                    SettingsLink { Text("設定を開く") }
                }
                .font(.caption)
            }
        }
    }
    // Recording switches to the compact view, which floats beside the video call.
    private func start() {
        Task {
            await store.start()
            if store.recording { ViewSwitch(open: openWindow, dismiss: dismissWindow).compact() }
        }
    }
    private func live(_ meeting: Meeting) -> some View {
        HStack(spacing: 18) {
            RecordingLamp()
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: meeting.date, by: 1)) { context in
                    Text(clock(context.date.timeIntervalSince(meeting.date)))
                        .font(.system(size: 30, weight: .light).monospacedDigit())
                }
                Text(meeting.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .fixedSize()
            Spacer(minLength: 24)
            LevelMeters(meter: store.meter)
            Button {
                Task { await store.stop() }
            } label: {
                Label("録音を停止", systemImage: "stop.fill")
            }
            .buttonStyle(CapsuleButtonStyle(filled: false))
            .fixedSize()
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.busy)
        }
    }
}
struct RecordingLamp: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let lamp = Circle().fill(Palette.beni).frame(width: 14, height: 14)
            .shadow(color: Palette.beni.opacity(0.7), radius: 6)
        Group {
            if reduceMotion {
                lamp
            } else {
                lamp.phaseAnimator([1.0, 0.3]) { view, opacity in
                    view.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
            }
        }
        .accessibilityLabel("録音中")
    }
}
struct LevelMeters: View {
    @ObservedObject var meter: LevelMeter
    var body: some View {
        HStack(spacing: 22) {
            TrackWaveform(label: "Mac音声", systemImage: "speaker.wave.2.fill", levels: meter.system, tint: Palette.paper)
            TrackWaveform(label: "マイク", systemImage: "mic.fill", levels: meter.microphone, tint: Palette.asagi)
        }
        .fixedSize()
    }
}
// The last few seconds of a track as a mirrored bar waveform; older samples fade to the left.
// Levels are drawn on a -60...0 dBFS scale, so a microphone that is not picking up a voice stays flat.
struct TrackWaveform: View {
    let label: String
    let systemImage: String
    let levels: [Float]
    let tint: Color
    var width: CGFloat = 168
    var height: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: systemImage).font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            Canvas { context, size in
                let step = size.width / CGFloat(max(levels.count, 1))
                for (i, level) in levels.enumerated() {
                    let height = max(2, CGFloat(Self.loudness(level)) * size.height)
                    let bar = CGRect(
                        x: CGFloat(i) * step + step * 0.2, y: (size.height - height) / 2, width: step * 0.6,
                        height: height)
                    let age = Double(i + 1) / Double(levels.count)
                    context.fill(
                        Path(roundedRect: bar, cornerRadius: step * 0.3), with: .color(tint.opacity(0.25 + 0.75 * age)))
                }
            }
            .frame(width: width, height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(Self.loudness(levels.last ?? 0) * 100))%")
    }
    static func loudness(_ level: Float) -> Double {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(level)) + 60) / 60))
    }
}
// Red belongs to recording; other actions use the outline style in another tint.
struct CapsuleButtonStyle: ButtonStyle {
    let filled: Bool
    var tint = Palette.beni
    func makeBody(configuration: Configuration) -> some View {
        CapsuleLabel(configuration: configuration, filled: filled, tint: tint)
    }
    private struct CapsuleLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyle.Configuration
        let filled: Bool
        let tint: Color
        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(filled ? tint : Color.clear))
                .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.8), lineWidth: 1.5))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(Capsule())
        }
    }
}

// MARK: - Minutes sheet

struct EmptyDesk: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("会議が始まったら、録音を開始してください").font(.mincho(20))
            Text("12秒ごとに文字起こしし、30秒ごとに議事録を書き足していきます。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct MinutesDesk: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                notices
                if let notes = meeting.notes {
                    MinutesSections(notes: notes, segments: meeting.segments)
                } else if !meeting.minutes.isEmpty {
                    Text(meeting.minutes).font(.system(size: 14)).lineSpacing(5).padding(.top, 24)
                } else {
                    Text(
                        meeting.transcriptionFailure != nil && meeting.segments.isEmpty
                            ? "文字起こしができていないため、議事録はまだありません。"
                            : meeting.id == store.activeID
                                ? "最初の議事録は、録音を始めて30秒ほどで届きます。"
                                : "文字起こしが済むと、ここに要約・決定事項・アクションアイテムがまとまります。"
                    )
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                }
            }
            .textSelection(.enabled)
            .foregroundStyle(Palette.sumi)
            .padding(.horizontal, 48).padding(.vertical, 40)
            .frame(maxWidth: 760, alignment: .leading)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .environment(\.colorScheme, .light)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meeting.title).font(.mincho(26))
            HStack(spacing: 10) {
                Text(longDate.string(from: meeting.date)).foregroundStyle(.secondary).fixedSize()
                Text(meeting.status)
                    .foregroundStyle(statusColor(meeting.status))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(meeting.status).opacity(0.12)))
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.callout)
            updateState.font(.caption)
            Rectangle().fill(Palette.sumi).frame(height: 1.5).padding(.top, 6)
        }
    }
    // While a meeting is live, say when the minutes last changed and whether an update is running.
    @ViewBuilder private var updateState: some View {
        if store.pipeline.isSummarizing(meeting.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("議事録を更新しています")
            }
            .foregroundStyle(Palette.asagi)
        } else if let updated = meeting.notes?.updatedAt {
            Text("\(updated.formatted(date: .omitted, time: .standard)) に更新").foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = meeting.captureError { Notice(text: message) }
            if let failure = meeting.transcriptionFailure {
                Notice(
                    text: failure, actionTitle: store.hasKey ? "再試行" : nil,
                    action: { store.retryFailedJobs(meeting.id) })
            }
            if store.pipeline.summaryFailed(meeting.id) {
                Notice(
                    text: meeting.id == store.activeID
                        ? "議事録の更新に失敗しました。録音中は間隔を空けて自動で再試行します。"
                        : "議事録の更新に失敗しました。",
                    actionTitle: canResume ? "未処理を再開" : nil, action: resume)
            }
            if let rejected = meeting.notes?.rejectedItems, rejected > 0 {
                Notice(text: "発言に根拠を確認できなかったAIの提案 \(rejected)件を載せていません。")
            }
            if meeting.notes?.extractionOnly == true {
                Notice(text: "以前のキーワード抽出で作った議事録です。「全文を再処理」でAIの議事録に作り直せます。")
            }
        }
        .padding(.top, 14)
    }
    private var canResume: Bool { meeting.id != store.activeID && store.hasKey && !store.isProcessing(meeting.id) }
    private func resume() { Task { await store.process() } }
}
struct Notice: View {
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.yamabuki)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let actionTitle { Button(actionTitle, action: action).controlSize(.small) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.yamabuki.opacity(0.12)))
    }
}
struct MinutesSections: View {
    let notes: MinutesState
    let segments: [Segment]
    var body: some View {
        let known = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let latest = notes.latestSegmentIDs ?? []
        let content = notes.content
        VStack(alignment: .leading, spacing: 30) {
            if content.summary.contains(where: { !Set($0.evidence).isDisjoint(with: latest) }) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.asagi).frame(width: 7, height: 7)
                    Text("直近の更新で加わった・変わった項目").font(.caption).foregroundStyle(.secondary)
                }
            }
            NoteSection(title: "要約", items: content.summary, known: known, latest: latest)
            NoteSection(title: "決定事項", items: content.decisions, known: known, latest: latest)
            NoteSection(title: "未決事項", items: content.unresolved, known: known, latest: latest)
            NoteSection(title: "アクションアイテム", items: content.actions, known: known, latest: latest, actions: true)
        }
        .padding(.top, 26)
    }
}
struct NoteSection: View {
    let title: String
    let items: [NoteItem]
    let known: [String: Segment]
    let latest: Set<String>
    var actions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.mincho(17))
                Text("\(items.count)").font(.callout).foregroundStyle(.secondary)
            }
            Rectangle().fill(Palette.rule).frame(height: 1).padding(.top, 8).padding(.bottom, 4)
            if items.isEmpty {
                Text("まだありません").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(items) { item in
                NoteRow(item: item, known: known, fresh: !Set(item.evidence).isDisjoint(with: latest), action: actions)
                if item.id != items.last?.id { Rectangle().fill(Palette.rule.opacity(0.5)).frame(height: 0.5) }
            }
        }
    }
}
struct NoteRow: View {
    let item: NoteItem
    let known: [String: Segment]
    let fresh: Bool
    let action: Bool
    var compact = false
    var body: some View {
        let evidence = item.evidence.compactMap { known[$0] }.sorted { $0.time < $1.time }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if action {
                Image(
                    systemName: item.state == .done
                        ? "checkmark.square.fill" : item.state == .cancelled ? "xmark.square" : "square"
                )
                .foregroundStyle(item.state == .done ? Palette.asagi : Color.secondary)
            } else {
                Circle().fill(fresh ? Palette.asagi : Palette.rule).frame(width: 6, height: 6).alignmentGuide(
                    .firstTextBaseline
                ) { $0[.bottom] + 2 }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.text).font(.system(size: compact ? 13 : 14.5)).lineSpacing(compact ? 2 : 4)
                    .strikethrough(item.state == .cancelled)
                    .foregroundStyle(item.state == .cancelled ? Color.secondary : Palette.sumi)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if action {
                        Tag(label: "担当", value: item.owner, open: item.state == .open)
                        Tag(label: "期限", value: item.due, open: item.state == .open)
                    } else if item.state != .open {
                        Text(item.state == .done ? "完了" : "撤回").foregroundStyle(Palette.asagi)
                    }
                    if let first = evidence.first {
                        Text("\(clock(first.time)) \(first.source)").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, compact ? 6 : 9).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(fresh ? Palette.asagi.opacity(0.1) : .clear))
    }
}
// An owner or deadline still missing on an open action is flagged, so the facilitator can ask for it.
struct Tag: View {
    let label: String
    let value: String?
    var open = false
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "未定").foregroundStyle(value != nil ? Palette.sumi : open ? Palette.yamabuki : Color.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.rule))
    }
}

// MARK: - Transcript panel

// Whether the transcript is scrolled to its end; following new speech pauses while the user reads back.
@MainActor final class TranscriptFollow: ObservableObject {
    @Published var atEnd = true
}
struct TranscriptPanel: View {
    @EnvironmentObject var store: Store
    @StateObject private var follow = TranscriptFollow()
    let meeting: Meeting
    var body: some View {
        let live = meeting.id == store.activeID
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("文字起こし").font(.headline)
                Spacer()
                let pending = meeting.jobs.filter { $0.state == .pending || $0.state == .running }.count
                Text(pending > 0 ? "\(meeting.segments.count)件・処理待ち \(pending)件" : "\(meeting.segments.count)件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Palette.ai).frame(height: 1)
            if meeting.segments.isEmpty {
                Text(live ? "最初の発言は12秒ほどで表示されます。" : "文字起こしはまだありません。")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(meeting.segments) { segment in TranscriptRow(segment: segment).id(segment.id) }
                        }
                        .padding(16)
                        .textSelection(.enabled)
                    }
                    // While recording, open at the latest speech and keep following it unless the user scrolled back.
                    // A finished meeting opens at its beginning.
                    .defaultScrollAnchor(live ? .bottom : .top)
                    .id(meeting.id)
                    .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                        ScrollMetrics(
                            offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                            container: geometry.containerSize.height)
                    } action: { old, new in
                        // New speech growing the content is not the user scrolling away; only their own scroll
                        // (same content size, different offset) stops following.
                        // Publish only real changes, so the modifier does not update several times per frame.
                        if new.content == old.content && new.container == old.container {
                            if follow.atEnd != new.atEnd { follow.atEnd = new.atEnd }
                        } else if new.atEnd && !follow.atEnd {
                            follow.atEnd = true
                        }
                    }
                    .onChange(of: meeting.segments.last?.id) {
                        if live && follow.atEnd { scrollToEnd(proxy) }
                    }
                    .overlay(alignment: .bottom) {
                        if live && !follow.atEnd {
                            Button {
                                scrollToEnd(proxy)
                            } label: {
                                Label("最新の発言へ", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(Palette.ai))
                                    .overlay(Capsule().strokeBorder(Palette.asagi.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .background(Palette.deepAi)
    }
    // Jumps without animation, so no in-between offset is mistaken for the user scrolling back.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = meeting.segments.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
        if !follow.atEnd { follow.atEnd = true }
    }
}
struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var container: CGFloat
    var atEnd: Bool { offset + container >= content - 60 }
}
struct TranscriptRow: View {
    let segment: Segment
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: sourceSymbol(segment.source))
                Text(clock(segment.time)).monospacedDigit()
                Text(segment.source)
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(segment.text).font(.system(size: 13.5)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings

// Drafts: nothing in the settings form takes effect until it is saved.
@MainActor final class SettingsDraft: ObservableObject {
    @Published var microphone = ""
    @Published var key = ""
    @Published var model = ""
    func load(from store: Store) {
        microphone = store.microphone
        key = store.key
        model = store.model
    }
    func differs(from store: Store) -> Bool {
        microphone != store.microphone || key != store.key || model != store.model
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var draft = SettingsDraft()
    var body: some View {
        let devices = store.devices
        let edited = draft.differs(from: store)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    SecureField("APIキー", text: $draft.key)
                    TextField("議事録のモデル", text: $draft.model)
                } header: {
                    Text("OpenAI")
                } footer: {
                    Text("文字起こしは gpt-4o-transcribe、議事録は指定したモデルで作ります。APIキーはこのMacのKeychainに保存します。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Picker("マイク", selection: $draft.microphone) {
                        Text("システムの設定に従う").tag("")
                        ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        if !draft.microphone.isEmpty && !devices.contains(where: { $0.uniqueID == draft.microphone }) {
                            Text("未接続のマイク").tag(draft.microphone)
                        }
                    }
                    .disabled(store.recording)
                } header: {
                    Text("録音")
                } footer: {
                    Text("会議の音はイヤホンで聞き、声はMac本体のマイクで録ると、二重に録音されずに済みます。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent("フォルダ") {
                        Text(displayPath(store.root))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    HStack {
                        Button("Finderで表示") { NSWorkspace.shared.open(store.root) }
                        Spacer()
                        Button("変更…") { store.chooseStorageFolder() }.disabled(store.recording || store.busy)
                    }
                } header: {
                    Text("保存先")
                } footer: {
                    Text(
                        "会議ごとにフォルダを作り、録音（録音.m4a）と議事録（議事録.md）をまとめて保存します。議事録.md はアプリが書き直すので、手を加えるときは別名で保存してください。保存先を変えると、これまでの会議も移動します。"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                if edited { Text("保存していない変更があります").font(.caption).foregroundStyle(Palette.yamabuki) }
                Spacer()
                Button("保存") {
                    if store.saveSettings(microphone: draft.microphone, key: draft.key, model: draft.model) {
                        draft.load(from: store)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!edited)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .frame(width: 540, height: 640)
        .onAppear { draft.load(from: store) }
    }
}

// MARK: - Live window

// The in-meeting view: small enough to sit beside Zoom or Teams, ordered for running the meeting
// (what is decided, what is still open, who does what), with the latest utterance at the bottom.
struct LiveWindow: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let meeting = store.recording ? store.activeMeeting : store.selectedMeeting
        VStack(spacing: 0) {
            LiveHeader(meeting: store.recording ? meeting : nil)
            if let meeting {
                LiveMinutes(meeting: meeting)
                LiveTicker(meeting: meeting, live: store.recording)
            } else {
                Text("録音を開始すると、ここに議事録が書き足されていきます。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.kon)
            }
        }
        .frame(minWidth: 340, minHeight: 460)
        .preferredColorScheme(.dark)
        .background(FloatingWindow(floating: store.pinsLiveWindow))
        .alert("確認が必要です", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("閉じる") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}
struct LiveHeader: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let meeting: Meeting?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meeting {
                HStack(spacing: 12) {
                    RecordingLamp()
                    VStack(alignment: .leading, spacing: 0) {
                        TimelineView(.periodic(from: meeting.date, by: 1)) { context in
                            Text(clock(context.date.timeIntervalSince(meeting.date)))
                                .font(.system(size: 24, weight: .light).monospacedDigit())
                        }
                        Text(meeting.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    pin
                    restore
                    Button {
                        Task { await store.stop() }
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: false))
                    .fixedSize()
                    .disabled(store.busy)
                }
                LiveMeters(meter: store.meter)
            } else {
                HStack(spacing: 8) {
                    TextField("会議のタイトル", text: $store.title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ai))
                        .onSubmit { Task { await store.start() } }
                    pin
                    restore
                    Button {
                        Task { await store.start() }
                    } label: {
                        Label("録音", systemImage: "record.circle")
                    }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .fixedSize()
                    .disabled(store.busy || !store.ready || !store.hasKey)
                }
                if !store.hasKey {
                    HStack(spacing: 6) {
                        Text("OpenAIのAPIキーを設定してください。")
                        SettingsLink { Text("設定を開く") }
                    }
                    .font(.caption).foregroundStyle(Palette.yamabuki)
                }
            }
        }
        .padding(14)
        .background(Palette.kon)
    }
    private var restore: some View {
        Button {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(Palette.paper)
        }
        .buttonStyle(.plain)
        .help("元の画面に戻す")
        .accessibilityLabel("元の画面に戻す")
    }
    private var pin: some View {
        Button {
            store.pinsLiveWindow.toggle()
        } label: {
            Image(systemName: store.pinsLiveWindow ? "pin.fill" : "pin")
                .foregroundStyle(store.pinsLiveWindow ? Palette.paper : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(store.pinsLiveWindow ? "手前への固定をやめる" : "ほかのウインドウより手前に固定する")
    }
}
struct LiveMeters: View {
    @ObservedObject var meter: LevelMeter
    var body: some View {
        HStack(spacing: 16) {
            TrackWaveform(
                label: "Mac音声", systemImage: "speaker.wave.2.fill", levels: meter.system, tint: Palette.paper,
                width: 140,
                height: 20)
            TrackWaveform(
                label: "マイク", systemImage: "mic.fill", levels: meter.microphone, tint: Palette.asagi, width: 140,
                height: 20)
        }
    }
}
struct LiveMinutes: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var body: some View {
        let notes = meeting.notes ?? MinutesState()
        let known = Dictionary(meeting.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let latest = notes.latestSegmentIDs ?? []
        let content = notes.content
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    if store.pipeline.isSummarizing(meeting.id) {
                        ProgressView().controlSize(.mini)
                        Text("議事録を更新しています").foregroundStyle(Palette.asagi)
                    } else if let updated = notes.updatedAt {
                        Circle().fill(Palette.asagi).frame(width: 6, height: 6)
                        Text("\(updated.formatted(date: .omitted, time: .standard)) の更新で加わった・変わった項目")
                            .foregroundStyle(.secondary)
                    } else if meeting.transcriptionFailure != nil && meeting.segments.isEmpty {
                        Text("文字起こしができていないため、議事録はまだありません。").foregroundStyle(Palette.yamabuki)
                    } else {
                        Text(store.recording ? "最初の議事録は、録音を始めて30秒ほどで届きます。" : "議事録はまだありません。")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                if let failure = meeting.transcriptionFailure {
                    Notice(
                        text: failure, actionTitle: store.hasKey ? "再試行" : nil,
                        action: { store.retryFailedJobs(meeting.id) })
                }
                if store.pipeline.summaryFailed(meeting.id) {
                    Notice(text: "議事録の更新に失敗しました。間隔を空けて自動で再試行します。")
                }
                LiveSection(title: "決定事項", items: content.decisions, known: known, latest: latest)
                LiveSection(title: "未決事項", items: content.unresolved, known: known, latest: latest)
                LiveSection(title: "アクションアイテム", items: content.actions, known: known, latest: latest, actions: true)
                LiveSection(title: "要約", items: content.summary, known: known, latest: latest)
            }
            .padding(16)
            .textSelection(.enabled)
        }
        .foregroundStyle(Palette.sumi)
        .background(Palette.paper)
        .environment(\.colorScheme, .light)
    }
}
struct LiveSection: View {
    let title: String
    let items: [NoteItem]
    let known: [String: Segment]
    let latest: Set<String>
    var actions = false
    var body: some View {
        let unassigned = actions ? items.filter { $0.state == .open && ($0.owner == nil || $0.due == nil) }.count : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.mincho(14))
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if unassigned > 0 {
                    Text("担当・期限が未定 \(unassigned)件").font(.caption).foregroundStyle(Palette.yamabuki)
                }
            }
            Rectangle().fill(Palette.rule).frame(height: 1).padding(.top, 4).padding(.bottom, 2)
            if items.isEmpty {
                Text("まだありません").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(items) { item in
                NoteRow(
                    item: item, known: known, fresh: !Set(item.evidence).isDisjoint(with: latest), action: actions,
                    compact: true)
            }
        }
    }
}
// The most recent utterance, so it is clear the meeting is being heard.
struct LiveTicker: View {
    let meeting: Meeting
    let live: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let last = meeting.segments.last {
                Image(systemName: sourceSymbol(last.source))
                    .font(.caption).foregroundStyle(.secondary)
                Text(clock(last.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(last.text).font(.callout).lineLimit(2)
            } else {
                Text(
                    meeting.transcriptionFailure != nil
                        ? "文字起こしに失敗しています。上の表示から再試行できます。"
                        : live ? "最初の発言は12秒ほどで表示されます。" : "文字起こしはまだありません。"
                )
                .font(.caption).foregroundStyle(meeting.transcriptionFailure != nil ? Palette.yamabuki : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Palette.deepAi)
    }
}
// Sets the hosting window's level, so the live window can stay above the video call.
struct FloatingWindow: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        DispatchQueue.main.async { view.window?.level = level }
    }
}
