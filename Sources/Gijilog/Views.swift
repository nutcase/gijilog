import AppKit
import Combine
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
    // Inks for text on the paper sheet, dark enough to read at small sizes.
    static let tokiwa = Color(hex: 0x1F7A4D)  // Decided.
    static let ruri = Color(hex: 0x1E50A2)  // Someone will do it.
    static let yamabukiInk = Color(hex: 0x93620A)  // Still open.
    static let sumire = Color(hex: 0x5A4FA0)  // What was talked about, and the points at issue.
    static let seiheki = Color(hex: 0x17707A)  // The views put forward.
}
// Each part of the minutes has its own ink and mark, so a reader finds what was decided, what is still open, and
// who does what at a glance. The text itself stays sumi; color marks only headings, bullets and labels.
enum NoteTone {
    case agenda, summary, decisions, unresolved, history, actions
    var color: Color {
        switch self {
        case .agenda: Palette.ai
        case .summary: Palette.sumire
        case .decisions: Palette.tokiwa
        case .unresolved: Palette.yamabukiInk
        case .history: Color(hex: 0x6B7280)
        case .actions: Palette.ruri
        }
    }
    var symbol: String {
        switch self {
        case .agenda: "list.number"
        case .summary: "text.alignleft"
        case .decisions: "checkmark.seal.fill"
        case .unresolved: "questionmark.circle.fill"
        case .history: "clock.arrow.circlepath"
        case .actions: "checklist"
        }
    }
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
    if status.hasPrefix("完了") || ["処理中", "更新中", "再開中", "復旧中", "準備中"].contains(where: status.contains) {
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
// The keywords being searched, for marking them in the minutes and transcript of the selected meeting.
private struct SearchTermsKey: EnvironmentKey { static let defaultValue: [String] = [] }
// The meeting whose recording can be listened back to, once it is over and 録音.m4a has been made.
private struct PlayableMeetingKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var searchTerms: [String] {
        get { self[SearchTermsKey.self] }
        set { self[SearchTermsKey.self] = newValue }
    }
    var playableMeeting: UUID? {
        get { self[PlayableMeetingKey.self] }
        set { self[PlayableMeetingKey.self] = newValue }
    }
}
/// The text with every keyword marked like a highlighter pen.
func highlighted(_ text: String, _ terms: [String]) -> AttributedString {
    var result = AttributedString(text)
    for range in MeetingSearch.ranges(of: terms, in: text) {
        if let marked = Range(range, in: result) {
            result[marked].swiftUI.backgroundColor = Palette.yamabuki.opacity(0.42)
        }
    }
    return result
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
enum RecordingStart {
    case new
    case prepared(UUID)
    case continuing(UUID)
}
// Each way of starting means one thing wherever it appears: 新規録音 always records a new meeting, and a meeting's
// own page records that meeting (prepared) or more of it (finished). Starting from anywhere (window, menu, menu bar)
// switches to the compact view beside the call.
@MainActor func startRecording(_ store: Store, views: ViewSwitch, _ how: RecordingStart = .new) {
    Task {
        switch how {
        case .new: await store.start(newMeeting: true)
        case .prepared(let id):
            store.selected = id
            await store.start()
        case .continuing(let id): await store.continueRecording(id)
        }
        if store.recording { views.compact() }
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
                // Recording is started from the toolbar or a meeting's page; the bar appears only while recording,
                // or when the API key is missing.
                if store.recording || !store.hasKey {
                    RecorderBar()
                    Rectangle().fill(Palette.ai).frame(height: 1)
                }
                // The transcript is a plain trailing column: SwiftUI's inspector inside this split view
                // loops on layout and crashes the window (macOS 27 SDK).
                HStack(spacing: 0) {
                    Group {
                        if let meeting = store.selectedMeeting { MinutesDesk(meeting: meeting) } else { EmptyDesk() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.showsTranscript, let meeting = store.selectedMeeting {
                        Rectangle().fill(Palette.ai).frame(width: 1)
                        TranscriptPanel(meeting: meeting, editable: store.canEditTranscript(meeting)).frame(width: 320)
                    }
                }
                .environment(\.searchTerms, store.searchedTerms)
                .environment(
                    \.playableMeeting, store.selectedMeeting.flatMap { store.recordingFile($0) != nil ? $0.id : nil })
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
        .alert(
            "確認が必要です",
            isPresented: Binding(
                get: { store.error != nil && !store.compactWindowOpen }, set: { if !$0 { store.error = nil } })
        ) {
            Button("閉じる") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .sheet(item: $store.correcting) { request in CorrectionSheet(request: request).environmentObject(store) }
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
            if store.busy || store.importing { ProgressView().controlSize(.small) }
            Button {
                store.chooseRecordingFiles()
            } label: {
                Label("読み込み", systemImage: "square.and.arrow.down")
            }
            .help("録音ファイル（音声・動画）を読み込んで議事録を作る。ウインドウにドロップしても読み込めます")
            .disabled(!store.ready || !store.hasKey)
            if let meeting = store.selectedMeeting {
                let idle = meeting.id != store.activeID && !store.busy && !store.isProcessing(meeting.id)
                // A click exports the minutes alone; the arrow offers them with the transcript.
                Menu {
                    Button("文字起こしも含めて書き出す…") { store.export(meeting, includesTranscript: true) }
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                } primaryAction: {
                    store.export(meeting)
                }
                .help("議事録をMarkdownで書き出す。文字起こしも含めるときは横の矢印から")
                .disabled(meeting.segments.isEmpty && meeting.notes == nil)
                Menu {
                    Button("議事録を仕上げる", systemImage: "text.badge.checkmark") {
                        Task { await store.refineMinutes(meeting.id) }
                    }.disabled(!idle || !store.hasKey || meeting.segments.isEmpty)
                    Button("未処理を再開", systemImage: "arrow.clockwise") { Task { await store.process() } }
                        .disabled(!idle || !store.hasKey || meeting.capture == .planned)
                    Button("全文を再処理", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.process(rebuild: true) }
                    }.disabled(!idle || !store.hasKey || meeting.capture == .planned)
                    if meeting.capture == .stopped || meeting.capture == .interrupted {
                        Button("この会議に続けて録音", systemImage: "record.circle") {
                            startRecording(
                                store, views: ViewSwitch(open: openWindow, dismiss: dismissWindow),
                                .continuing(meeting.id))
                        }
                        .disabled(
                            store.recording || store.busy || !store.hasKey || !store.canContinueRecording(meeting))
                    }
                    Button("語句をまとめて直す…", systemImage: "character.cursor.ibeam") {
                        store.correcting = CorrectionRequest(meetingID: meeting.id)
                    }
                    .disabled(meeting.capture == .planned || (meeting.segments.isEmpty && meeting.notes == nil))
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
        if !store.recording {
            ToolbarItemGroup(placement: .primaryAction) {
                let views = ViewSwitch(open: openWindow, dismiss: dismissWindow)
                // Always a new meeting, whatever is selected: a meeting's own page records that meeting.
                Button {
                    startRecording(store, views: views, .new)
                } label: {
                    Label("新規録音", systemImage: "record.circle").labelStyle(.titleAndIcon)
                }
                // The app's own red capsule: a system prominent button turns gray whenever the window is not
                // in front, which is most of a meeting.
                .buttonStyle(CapsuleButtonStyle(filled: true, height: 30))
                .help("新しい会議として、Macの音声とマイクの録音を始める（⌘⇧R）")
                .disabled(store.busy || !store.ready || !store.hasKey)
            }
        }
    }
}

// MARK: - Sidebar

struct MeetingList: View {
    @EnvironmentObject var store: Store
    @FocusState private var searchFocused: Bool
    var body: some View {
        List(selection: $store.selected) {
            if days.isEmpty && !store.searchedTerms.isEmpty {
                Text(
                    "「\(store.searchedTerms.joined(separator: " "))」を含む会議はありません。"
                        + (store.tagFilter.isEmpty ? "" : "タグでも絞り込んでいます。")
                )
                .font(.callout).foregroundStyle(.secondary).lineLimit(nil)  // Sidebar rows default to one line.
            } else if days.isEmpty && !store.tagFilter.isEmpty {
                Text("選んだタグがすべて付いた会議はありません。").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
            ForEach(days, id: \.0) { title, meetings in
                Section(title) {
                    ForEach(meetings) { meeting in
                        MeetingRow(meeting: meeting, hit: store.searchHits[meeting.id], terms: store.searchedTerms)
                            .tag(meeting.id)
                            .contextMenu {
                                TagMenu(meeting: meeting)
                                Divider()
                                Button("ゴミ箱に移動…", role: .destructive) { store.deletion = meeting }
                                    .disabled(!store.canDelete(meeting.id))
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "キーワードで検索")
        .searchFocused($searchFocused)
        .onChange(of: store.focusesSearch, initial: true) {
            guard store.focusesSearch else { return }
            store.focusesSearch = false
            // A window that ⌘F just opened needs a moment before its search field can take focus.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                searchFocused = true
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.deepAi)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 20, weight: .semibold))
                    Text("ギジログ").font(.mincho(22))
                    Spacer()
                }
                .foregroundStyle(Palette.paper)
                Button {
                    store.planMeeting()
                } label: {
                    Label("アジェンダを準備", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(!store.ready)
                .help("録音の前に会議を作って、議題を用意しておく（⌘N）。会議が始まったら、その会議のページで録音します")
                if !store.allTags.isEmpty { TagFilterBar() }
            }
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
        for meeting in store.visibleMeetings {
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
    var hit: SearchHit?
    var terms: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(highlighted(meeting.title, terms)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(statusColor(meeting.status)).frame(width: 6, height: 6)
                Text(meeting.date.formatted(date: .omitted, time: .shortened))
                Text(meeting.status).lineLimit(1)
            }
            .font(.caption).foregroundStyle(.secondary)
            if !meeting.tags.isEmpty {
                // Not a Label: the sidebar would tint its icon with the accent color.
                HStack(spacing: 4) {
                    Image(systemName: "tag").imageScale(.small)
                    Text(highlighted(meeting.tags.joined(separator: ", "), terms)).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("タグ: " + meeting.tags.joined(separator: ", "))
            }
            // The title and tags already show their own matches; other matches get a short excerpt.
            if let hit, hit.place == .minutes || hit.place == .transcript || hit.place == .agenda {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(
                        systemName: hit.place == .transcript
                            ? "text.quote" : hit.place == .agenda ? "list.bullet" : "doc.text"
                    )
                    .imageScale(.small)
                    Text(highlighted((hit.time.map { clock($0) + " " } ?? "") + hit.snippet, terms)).lineLimit(2)
                }
                .font(.caption).foregroundStyle(Palette.paper.opacity(0.78))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    (hit.place == .transcript ? "文字起こし: " : hit.place == .agenda ? "アジェンダ: " : "議事録: ") + hit.snippet)
            }
        }
        .padding(.vertical, 4)
    }
}
// Narrows the sidebar to meetings that have every selected tag.
struct TagFilterBar: View {
    @EnvironmentObject var store: Store
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("タグで絞り込む", systemImage: "line.3.horizontal.decrease").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !store.tagFilter.isEmpty {
                    Button("解除") { store.clearTagFilter() }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Palette.asagi)
                        .help("すべての会議を表示")
                }
                Button("管理", action: manageTags)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("タグの名前を変えたり、削除したりする")
            }
            // Many tags scroll within a few rows instead of pushing the meetings down.
            if store.allTags.count > 12 { ScrollView { chips }.frame(height: 96) } else { chips }
        }
    }
    private var chips: some View {
        FlowLayout(spacing: 6) {
            ForEach(store.allTags, id: \.name) { tag in
                let on = MeetingTags.contains(store.tagFilter, tag.name)
                Button {
                    store.toggleTagFilter(tag.name)
                } label: {
                    HStack(spacing: 5) {
                        Text(tag.name).lineLimit(1)
                        Text(shortCount(tag.count)).foregroundStyle(on ? Palette.kon.opacity(0.65) : Color.secondary)
                    }
                }
                .buttonStyle(FilterChipStyle(on: on))
                .contextMenu { Button("タグを管理…", action: manageTags) }
                .accessibilityAddTraits(on ? .isSelected : [])
                .help(on ? "「\(tag.name)」での絞り込みをやめる" : "「\(tag.name)」の付いた会議だけを表示")
            }
        }
    }
}
extension TagFilterBar {
    private func manageTags() {
        store.settingsTab = "タグ"
        openSettings()
    }
}
struct FilterChipStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Palette.kon : Palette.paper.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? Palette.asagi : Color.clear))
            .overlay(Capsule().strokeBorder(on ? Color.clear : Palette.paper.opacity(0.22), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
// Tags from a meeting's context menu: existing tags as checkmarks, or open the tag field for a new one.
struct TagMenu: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var body: some View {
        Menu("タグ") {
            ForEach(store.allTags, id: \.name) { tag in
                Toggle(
                    tag.name,
                    isOn: Binding(
                        get: { MeetingTags.contains(meeting.tags, tag.name) },
                        set: {
                            $0 ? store.addTags(tag.name, to: meeting.id) : store.removeTag(tag.name, from: meeting.id)
                        }
                    ))
            }
            if !store.allTags.isEmpty { Divider() }
            Button("新しいタグ…") {
                store.selected = meeting.id
                // Open the field once the meeting's sheet is on screen to anchor it.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    store.tagEditor = meeting.id
                }
            }
        }
    }
}
// Lays out chips left to right and wraps them onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)  // A chip wider than the row is truncated, not overflowed.
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

// MARK: - Recorder bar

struct RecorderBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Group {
            if store.recording, let meeting = store.activeMeeting { live(meeting) } else { idle }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
    // Shown only without an API key: recording starts from the toolbar or a meeting's own page.
    private var idle: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(Palette.yamabuki)
            Text("録音するには、OpenAIのAPIキーを設定してください。")
            SettingsLink { Text("設定を開く") }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
    private func live(_ meeting: Meeting) -> some View {
        VStack(spacing: 10) {
            liveControls(meeting)
            SilenceWarning()
        }
    }
    private func liveControls(_ meeting: Meeting) -> some View {
        HStack(spacing: 18) {
            RecordingLamp()
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: meeting.date, by: 1)) { context in
                    Text(clock(context.date.timeIntervalSince(meeting.recordingOrigin)))
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
            .disabled(store.busy)
        }
    }
}
// The pulse is a Core Animation layer animation, run by the window server rather than by SwiftUI redrawing the
// lamp every frame. (A SwiftUI phaseAnimator here cost about 25% CPU for the whole recording; this costs ~0%.)
struct RecordingLamp: NSViewRepresentable {
    func makeNSView(context: Context) -> PulsingLampView { PulsingLampView() }
    func updateNSView(_ view: PulsingLampView, context: Context) {
        view.pulses = !context.environment.accessibilityReduceMotion
        view.setAccessibilityLabel("録音中")
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulsingLampView, context: Context) -> CGSize? {
        CGSize(width: 14, height: 14)
    }
}
final class PulsingLampView: NSView {
    var pulses = true { didSet { updatePulse() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        let red = NSColor(Palette.beni).cgColor
        layer.backgroundColor = red
        layer.shadowColor = red
        layer.shadowOpacity = 0.7
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        layer.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        layer?.shadowPath = CGPath(ellipseIn: bounds, transform: nil)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }
    private func updatePulse() {
        guard let layer else { return }
        guard pulses, window != nil else {
            layer.removeAnimation(forKey: "pulse")
            return
        }
        guard layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }
}
// The meter is not observed by SwiftUI: each waveform subscribes to its track and moves its own layers,
// so 10 Hz levels never re-render the view tree. (A SwiftUI Canvas here cost about 17% CPU while recording.)
struct LevelMeters: View {
    let meter: LevelMeter
    var body: some View {
        HStack(spacing: 22) {
            TrackWaveform(
                label: "Mac音声", systemImage: "speaker.wave.2.fill", levels: meter.$system, tint: Palette.paper)
            TrackWaveform(label: "マイク", systemImage: "mic.fill", levels: meter.$microphone, tint: Palette.asagi)
        }
        .fixedSize()
    }
}
struct TrackWaveform: View {
    let label: String
    let systemImage: String
    let levels: Published<[Float]>.Publisher
    let tint: Color
    var width: CGFloat = 168
    var height: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: systemImage).font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                .accessibilityHidden(true)
            WaveformBars(label: label, levels: levels, tint: tint).frame(width: width, height: height)
        }
    }
}
struct WaveformBars: NSViewRepresentable {
    let label: String
    let levels: Published<[Float]>.Publisher
    let tint: Color
    func makeNSView(context: Context) -> WaveformView {
        let view = WaveformView(tint: NSColor(tint))
        view.setAccessibilityLabel(label)
        view.follow(levels)
        return view
    }
    func updateNSView(_ view: WaveformView, context: Context) {}
}
// The last few seconds of a track as a mirrored bar waveform; older samples fade to the left.
// Levels are drawn on a -60...0 dBFS scale, so a microphone that is not picking up a voice stays flat.
final class WaveformView: NSView {
    private var bars: [CALayer] = []
    private var levels = [Float](repeating: 0, count: LevelMeter.length)
    private var subscription: AnyCancellable?
    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        for i in 0..<LevelMeter.length {
            let bar = CALayer()
            let age = CGFloat(i + 1) / CGFloat(LevelMeter.length)
            bar.backgroundColor = tint.withAlphaComponent(0.25 + 0.75 * age).cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func follow(_ publisher: Published<[Float]>.Publisher) {
        subscription = publisher.receive(on: DispatchQueue.main).sink { [weak self] levels in
            guard let self else { return }
            self.levels = levels
            self.placeBars()
            self.setAccessibilityValue("\(Int(Self.loudness(levels.last ?? 0) * 100))%")
        }
    }
    override func layout() {
        super.layout()
        placeBars()
    }
    private func placeBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // Jump to each level; implicit animations would run nonstop.
        let step = bounds.width / CGFloat(bars.count)
        for (i, bar) in bars.enumerated() {
            let level = i < levels.count ? levels[i] : 0
            let height = max(2, CGFloat(Self.loudness(level)) * bounds.height)
            bar.frame = CGRect(
                x: CGFloat(i) * step + step * 0.2, y: (bounds.height - height) / 2, width: step * 0.6, height: height)
            bar.cornerRadius = step * 0.3
        }
        CATransaction.commit()
    }
    static func loudness(_ level: Float) -> Double {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(level)) + 60) / 60))
    }
}
// A secondary action beside the record button: text only, so recording stays the obvious choice.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration)
    }
    private struct QuietLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyle.Configuration
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.paper.opacity(configuration.isPressed ? 0.45 : 0.7))
                .padding(.horizontal, 6).frame(height: 40)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
    }
}
// Red belongs to recording; other actions use the outline style in another tint.
struct CapsuleButtonStyle: ButtonStyle {
    let filled: Bool
    var tint = Palette.beni
    var height: CGFloat = 40  // 30 fits a toolbar.
    func makeBody(configuration: Configuration) -> some View {
        CapsuleLabel(configuration: configuration, filled: filled, tint: tint, height: height)
    }
    private struct CapsuleLabel: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyle.Configuration
        let filled: Bool
        let tint: Color
        let height: CGFloat
        var body: some View {
            configuration.label
                .font(.system(size: height < 40 ? 13 : 14, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .padding(.horizontal, height < 40 ? 14 : 18).frame(height: height)
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
            Text("会議が始まったら、「新規録音」を押してください").font(.mincho(20))
            Text(
                "Macの音声とマイクを録音し、話の切れ目ごとに文字起こしして、30秒ごとに議事録を書き足していきます。\n録音ファイルはウインドウにドロップしても読み込めます。OpenAIのAPI利用料がかかります。"
            )
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct MinutesDesk: View {
    @EnvironmentObject var store: Store
    @Environment(\.searchTerms) private var terms
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let meeting: Meeting
    var body: some View {
        // The find bar takes over the highlighting from the meeting search while it has words.
        let find = store.minutesFind.open ? store.minutesFind : FindState()
        let found = MeetingSearch.items(meeting, terms: find.terms)
        let current = find.current(in: found)
        VStack(spacing: 0) {
            if store.minutesFind.open {
                FindBar(state: $store.minutesFind, placeholder: "議事録を検索", count: found.count, dark: true)
                    .frame(maxWidth: 520).padding(.top, 12)
            }
            ScrollViewReader { proxy in
                document(current: current)
                    .environment(\.searchTerms, find.terms.isEmpty ? terms : find.terms)
                    .task(id: current) {
                        guard let current else { return }
                        try? await Task.sleep(nanoseconds: 50_000_000)  // After the items are laid out.
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("note-" + current, anchor: .center) }
                    }
            }
        }
    }
    private func document(current: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                notices
                if meeting.capture == .planned || !meeting.agenda.isEmpty {
                    AgendaSection(meeting: meeting).padding(.top, 26)
                }
                if meeting.capture == .planned {
                    Text("会議の時間になったら、上の「この会議を録音」を押してください。議事録はここに書き足されていきます。")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                } else if let notes = meeting.notes {
                    MinutesSections(
                        notes: notes, segments: meeting.segments, meetingID: meeting.id,
                        editable: store.canEditMinutes(meeting), current: current)
                } else if !meeting.minutes.isEmpty {
                    Text(highlighted(meeting.minutes, terms)).font(.system(size: 14)).lineSpacing(5).padding(.top, 24)
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
            // The shadow is the sheet shape's alone. On the whole view it fell under every line, and flattening
            // the view into one layer to stop that drew some text upside down when part of it redrew.
            .background(
                RoundedRectangle(cornerRadius: 4).fill(Palette.paper)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            )
            .environment(\.colorScheme, .light)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if meeting.capture == .planned {
                TextField(
                    "会議のタイトル",
                    text: Binding(get: { meeting.title }, set: { store.renamePlannedMeeting(meeting.id, to: $0) })
                )
                .textFieldStyle(.plain).font(.mincho(26))
            } else {
                MeetingTitle(meeting: meeting)
            }
            HStack(spacing: 10) {
                Text(longDate.string(from: meeting.date)).foregroundStyle(.secondary).fixedSize()
                Text(meeting.status)
                    .foregroundStyle(statusColor(meeting.status))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(meeting.status).opacity(0.12)))
                    .fixedSize()
                Spacer(minLength: 0)
                if meeting.notes != nil {
                    Button {
                        store.minutesFind.open = true
                        store.minutesFind.focus += 1
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("議事録の中を検索（⌥⌘F）")
                    .accessibilityLabel("議事録の中を検索")
                }
                recordButton
            }
            .font(.callout)
            tags
            updateState.font(.caption)
            Rectangle().fill(Palette.sumi).frame(height: 1.5).padding(.top, 6)
        }
    }
    // The meeting's own recording: a prepared meeting is recorded, a finished one continued. A new meeting is
    // recorded from the toolbar.
    @ViewBuilder private var recordButton: some View {
        let views = ViewSwitch(open: openWindow, dismiss: dismissWindow)
        if meeting.capture == .planned {
            Button {
                startRecording(store, views: views, .prepared(meeting.id))
            } label: {
                Label("この会議を録音", systemImage: "record.circle")
            }
            .buttonStyle(CapsuleButtonStyle(filled: true, height: 30))
            .help("準備したこの会議の録音を始める")
            .disabled(store.recording || store.busy || !store.ready || !store.hasKey)
        } else if meeting.capture == .stopped || meeting.capture == .interrupted {
            Button {
                startRecording(store, views: views, .continuing(meeting.id))
            } label: {
                Label("続けて録音", systemImage: "record.circle")
            }
            .buttonStyle(CapsuleButtonStyle(filled: false, height: 28))
            .help(
                store.recording
                    ? "ほかの会議を録音中です"
                    : store.canContinueRecording(meeting)
                        ? "この会議の続きを録音する。時刻は前の録音の続きから数えます" : "処理が終わると続けて録音できます"
            )
            .disabled(store.recording || store.busy || !store.hasKey || !store.canContinueRecording(meeting))
        }
    }
    private var tags: some View {
        FlowLayout(spacing: 6) {
            ForEach(meeting.tags, id: \.self) { tag in
                TagChip(name: tag) { store.removeTag(tag, from: meeting.id) }
            }
            Button {
                store.tagEditor = meeting.id
            } label: {
                if meeting.tags.isEmpty {
                    Label("タグを追加", systemImage: "tag")
                } else {
                    Image(systemName: "plus").padding(.horizontal, 4).accessibilityLabel("タグを追加")
                }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .padding(.vertical, 3)
            .help("タグを付けると、一覧をタグで絞り込めます")
            .popover(
                isPresented: Binding(
                    get: { store.tagEditor == meeting.id }, set: { if !$0 { store.tagEditor = nil } }),
                arrowEdge: .bottom
            ) {
                // The popover is app chrome, not part of the light paper sheet it is anchored to.
                TagEditor(meetingID: meeting.id).environmentObject(store).environment(\.colorScheme, .dark)
            }
        }
    }
    // While a meeting is live, say when the minutes last changed and whether an update is running.
    @ViewBuilder private var updateState: some View {
        if store.pipeline.isSummarizing(meeting.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(
                    meeting.finalReviewPending == true && meeting.capture != .recording
                        ? "議事録全体を確認して仕上げています" : "議事録を更新しています")
            }
            .foregroundStyle(Palette.asagi)
        } else if let finalized = meeting.notes?.finalizedAt {
            Text("\(finalized.formatted(date: .omitted, time: .standard)) に全体の確認完了").foregroundStyle(.secondary)
        } else if let updated = meeting.notes?.updatedAt {
            Text("\(updated.formatted(date: .omitted, time: .standard)) に更新").foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = meeting.captureError { Notice(text: message) }
            if let stopped = meeting.stoppedForSilence, meeting.capture != .recording {
                Notice(
                    text: "音がしばらくなかったため、\(stopped.formatted(date: .omitted, time: .shortened)) に録音を自動で止めました。"
                        + "続きがあるときは「続けて録音」で録音できます。",
                    actionTitle: "閉じる", action: { store.dismissSilenceStop(meeting.id) })
            }
            if let failure = meeting.transcriptionFailure {
                Notice(
                    text: failure, actionTitle: store.hasKey ? "再試行" : nil,
                    action: { store.retryFailedJobs(meeting.id) })
            }
            if store.pipeline.summaryFailed(meeting.id) {
                Notice(
                    text: (meeting.id == store.activeID
                        ? "議事録の更新に失敗しました。録音中は間隔を空けて自動で再試行します。"
                        : "議事録の更新に失敗しました。") + (store.pipeline.summaryError(meeting.id).map { "\n" + $0 } ?? ""),
                    actionTitle: canResume ? "未処理を再開" : nil, action: resume)
            }
            if meeting.notes?.extractionOnly == true {
                Notice(text: "以前のキーワード抽出で作った議事録です。「全文を再処理」でAIの議事録に作り直せます。")
            }
            if let offer = store.correctionOffer, offer.meetingID == meeting.id, !offer.inTranscript {
                CorrectionOfferView(offer: offer)
            }
        }
        .padding(.top, 14)
    }
    private var canResume: Bool { meeting.id != store.activeID && store.hasKey && !store.isProcessing(meeting.id) }
    private func resume() { Task { await store.process() } }
}
struct TagChip: View {
    let name: String
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            Text(name).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("このタグを外す")
            .accessibilityLabel("「\(name)」を外す")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.sumi)
        .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 3)
        .background(Capsule().fill(Palette.asagi.opacity(0.14)))
    }
}
final class TextDraft: ObservableObject {
    @Published var text = ""
}
final class TitleDraft: ObservableObject {
    @Published var text = ""
    var original = ""
}
// A recorded meeting's title: click to rename it. The title is saved as it is typed (a blank one is skipped), so
// it holds however editing ends; Enter or clicking another field closes the field, and Esc restores the old title.
struct MeetingTitle: View {
    @EnvironmentObject var store: Store
    @Environment(\.searchTerms) private var terms
    @StateObject private var draft = TitleDraft()
    @FocusState private var focused: Bool
    let meeting: Meeting
    var body: some View {
        let editing = store.editingTitle == meeting.id
        Group {
            if editing {
                TextField("会議のタイトル", text: $draft.text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onChange(of: draft.text) { store.renameMeeting(meeting.id, to: draft.text) }
                    .onSubmit { store.editingTitle = nil }
                    .onEscape {
                        store.renameMeeting(meeting.id, to: draft.original)
                        store.editingTitle = nil
                    }
            } else {
                Text(highlighted(meeting.title, terms))
                    .textSelection(.disabled)
                    .contentShape(Rectangle())
                    .onTapGesture { store.editingTitle = meeting.id }
                    .help("クリックしてタイトルを変更")
            }
        }
        .font(.mincho(26))
        .onChange(of: editing, initial: true) {
            if editing {
                draft.original = meeting.title
                draft.text = meeting.title
                Task { @MainActor in focused = true }  // Once the field is on screen.
            }
        }
        .onChange(of: focused) { if !focused && store.editingTitle == meeting.id { store.editingTitle = nil } }
    }
}
// Type a tag and press Enter, or pick one used before. Enter on an empty field closes it.
struct TagEditor: View {
    @EnvironmentObject var store: Store
    let meetingID: UUID
    @StateObject private var draft = TextDraft()
    @FocusState private var focused: Bool
    var body: some View {
        let current = store.meetings.first { $0.id == meetingID }?.tags ?? []
        let typed = draft.text.trimmingCharacters(in: .whitespaces)
        let suggestions = store.allTags.map(\.name).filter { name in
            !MeetingTags.contains(current, name) && (typed.isEmpty || name.localizedStandardContains(typed))
        }
        VStack(alignment: .leading, spacing: 10) {
            TextField("タグを入力して Enter", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if typed.isEmpty {
                        store.tagEditor = nil
                    } else {
                        store.addTags(draft.text, to: meetingID)
                        draft.text = ""
                    }
                }
            if !suggestions.isEmpty {
                Text(typed.isEmpty ? "これまでに使ったタグ" : "一致するタグ").font(.caption)
                    .foregroundStyle(Palette.paper.opacity(0.6))
                FlowLayout(spacing: 6) {
                    ForEach(suggestions.prefix(20), id: \.self) { name in
                        Button(name) {
                            store.addTags(name, to: meetingID)
                            draft.text = ""
                        }
                        .buttonStyle(SuggestionChipStyle())
                    }
                }
            }
            Text("カンマ（、）で区切ると、まとめて追加できます。").font(.caption)
                .foregroundStyle(Palette.paper.opacity(0.6))
        }
        .foregroundStyle(Palette.paper)  // Not the sheet's ink: the popover is dark app chrome.
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .onAppear { focused = true }
    }
}
struct SuggestionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium)).lineLimit(1)
            .foregroundStyle(Palette.paper)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Palette.paper.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}
// Shown in the last minute before recording stops for a long silence, counting down, with a button to keep
// recording. Nothing shows the rest of the time.
struct SilenceWarning: View {
    @EnvironmentObject var store: Store
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let left = store.secondsUntilSilenceStop(now: context.date) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "speaker.slash.fill").foregroundStyle(Palette.yamabuki)
                    Text("音が\(store.autoStopMinutes)分近くありません。あと\(left)秒で録音を止めます。")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("録音を続ける") { store.heardSound() }.controlSize(.small)
                }
                .font(compact ? .caption : .callout)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.yamabuki.opacity(0.18)))
            }
        }
    }
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
    var meetingID: UUID?
    var editable = false
    var current: String?  // The find bar's current match.
    var body: some View {
        let known = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let latest = notes.latestSegmentIDs ?? []
        let content = notes.content
        let revised = editable ? notes.itemsCitingRevisedLines : []
        VStack(alignment: .leading, spacing: 30) {
            if !revised.isEmpty, let meetingID { RevisionNotice(meetingID: meetingID, count: revised.count) }
            if content.summary.contains(where: { !Set($0.evidence).isDisjoint(with: latest) }) {
                HStack(spacing: 6) {
                    FreshSwatch()
                    Text("直近の更新で加わった・変わった項目").font(.caption).foregroundStyle(.secondary)
                }
            }
            NoteSection(
                title: "要約", tone: .summary, items: content.summary.filter { $0.state != .cancelled }, known: known,
                latest: latest, editing: edit(.summary), current: current, revised: revised)
            NoteSection(
                title: "決定事項と理由", tone: .decisions, items: content.decisions.filter { $0.state != .cancelled },
                known: known, latest: latest, editing: edit(.decisions), current: current, revised: revised,
                topics: content.summary.filter { $0.state != .cancelled })
            NoteSection(
                title: "未決事項・次の確認", tone: .unresolved, items: content.unresolved.filter { $0.state == .open },
                known: known, latest: latest, editing: edit(.unresolved), current: current, revised: revised,
                topics: content.summary.filter { $0.state != .cancelled })
            if !content.history.isEmpty {
                NoteSection(
                    title: "議論の経緯", tone: .history, items: content.history, known: known, latest: latest,
                    current: current, revised: revised)
            }
            NoteSection(
                title: "アクションアイテム", tone: .actions, items: content.actions.filter { $0.state != .cancelled },
                known: known, latest: latest, editing: edit(.actions), current: current, revised: revised,
                topics: content.summary.filter { $0.state != .cancelled })
        }
        .padding(.top, 26)
    }
    private func edit(_ part: NotePart) -> NoteEditing? {
        guard editable, let meetingID else { return nil }
        return NoteEditing(meetingID: meetingID, part: part)
    }
}
// Shown when transcript lines the minutes cite were corrected or deleted by hand: the minutes can be written again
// from the corrected transcript (hand-edited items stay), or kept as they are.
struct RevisionNotice: View {
    @EnvironmentObject var store: Store
    let meetingID: UUID
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.yamabuki)
                Text("文字起こしで直した発言をもとにした項目が\(count)件あります（「要確認」の印）。")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            Text("直した文字起こしから議事録を作り直すと反映されます。手で直した項目はそのまま残ります。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("訂正を反映して更新") { Task { await store.refineMinutes(meetingID) } }
                    .disabled(!store.hasKey)
                Button("このままにする") { store.keepMinutesDespiteRevisions(meetingID) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.yamabuki.opacity(0.12)))
    }
}
/// Where an editable section's items live.
struct NoteEditing {
    let meetingID: UUID
    let part: NotePart
}
struct NoteSection: View {
    @EnvironmentObject var store: Store
    let title: String
    let tone: NoteTone
    let items: [NoteItem]
    let known: [String: Segment]
    let latest: Set<String>
    var editing: NoteEditing?
    var current: String?
    var revised: Set<String> = []  // Items citing transcript lines corrected since the minutes were written.
    var topics: [NoteItem] = []  // The summary's topics, for decisions, open issues or actions listed by topic.
    @StateObject private var dropTarget = TopicDropHighlight()
    var body: some View {
        // A folded section opens while the find bar's current match is in it.
        let folded = store.foldedSections.contains(title) && !items.contains { $0.id == current }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: title, tone: tone, count: items.count)
            SectionRule(tone: tone).padding(.top, 8).padding(.bottom, folded ? 0 : 4)
            if !folded { rows }
        }
    }
    @ViewBuilder private var rows: some View {
        if items.isEmpty {
            Text("まだありません").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        }
        ForEach(TopicGroup.of(items, topics: topics, known: known)) { group in
            VStack(alignment: .leading, spacing: 0) {
                if let heading = group.heading { TopicGroupHeading(heading: heading) }
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    row(item, number: index + 1)
                    if item.id != group.items.last?.id {
                        Rectangle().fill(Palette.rule.opacity(0.5)).frame(height: 0.5)
                    }
                }
            }
            .modifier(TopicDrop(editing: editing, topic: group.topic, highlight: dropTarget))
        }
        if let editing { AddNoteItem(editing: editing) }
    }
    @ViewBuilder private func row(_ item: NoteItem, number: Int) -> some View {
        let fresh = !Set(item.evidence).isDisjoint(with: latest)
        Group {
            if let editing {
                EditableNoteRow(
                    editing: editing, item: item, known: known, fresh: fresh, tone: tone, number: number,
                    current: item.id == current, revised: revised.contains(item.id), topics: topics)
            } else {
                NoteRow(
                    item: item, known: known, fresh: fresh, tone: tone, number: number,
                    current: item.id == current, revised: revised.contains(item.id))
            }
        }
        .id("note-" + item.id)
    }
}
/// A run of items under one summary topic, or all of them when they are not grouped.
struct TopicGroup: Identifiable {
    let id: String
    let heading: (number: Int?, name: String)?  // None when the items are not grouped by topic.
    let items: [NoteItem]
    var topic: Int? = nil  // The summary topic's place, for a run under one.
    /// The items under the summary topic each came from, in the summary's order, those of no topic under その他
    /// last; all together when there are no topics to group by or none of the items belongs to one.
    static func of(_ items: [NoteItem], topics: [NoteItem], known: [String: Segment]) -> [TopicGroup] {
        guard !topics.isEmpty else { return [TopicGroup(id: "all", heading: nil, items: items)] }
        let groups = MinutesEngine.groupedByTopic(items, summary: topics, known: known)
        guard groups.contains(where: { $0.topic != nil }) else {
            return [TopicGroup(id: "all", heading: nil, items: items)]
        }
        return groups.map { group in
            guard let index = group.topic else {
                return TopicGroup(id: "rest", heading: (nil, "その他"), items: group.items)
            }
            let parts = MinutesEngine.summaryParts(topics[index].text)
            return TopicGroup(
                id: topics[index].id, heading: (index + 1, parts.topic ?? parts.overview), items: group.items,
                topic: index)
        }
    }
}
/// The topic a dragged item is over, outlined in its section.
@MainActor final class TopicDropHighlight: ObservableObject {
    @Published var topic: Int?
}
// A topic's heading and items take a decision, open issue or action dragged from another topic of the same section,
// and move it there. Only where the minutes can be edited.
struct TopicDrop: ViewModifier {
    @EnvironmentObject var store: Store
    let editing: NoteEditing?
    let topic: Int?
    @ObservedObject var highlight: TopicDropHighlight
    @ViewBuilder func body(content: Content) -> some View {
        if let editing, let topic, editing.part != .summary {
            let over = highlight.topic == topic
            content
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Palette.sumire.opacity(over ? 0.07 : 0)).padding(-4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                        Palette.sumire.opacity(over ? 0.5 : 0), lineWidth: 1.5
                    )
                    .padding(-4)
                )
                .dropDestination(for: String.self) { payloads, _ in
                    guard let drag = payloads.lazy.compactMap(NoteItemDrag.init(payload:)).first,
                        drag.meetingID == editing.meetingID, drag.part == editing.part
                    else { return false }
                    store.moveNoteItem(editing.meetingID, part: drag.part, id: drag.id, toTopic: topic)
                    return true
                } isTargeted: { inside in
                    if inside {
                        highlight.topic = topic
                    } else if highlight.topic == topic {
                        highlight.topic = nil
                    }
                }
        } else {
            content
        }
    }
}
// The heading of a run of decisions, open issues or actions: the summary topic's number and name, drawn as the
// summary draws them.
struct TopicGroupHeading: View {
    let heading: (number: Int?, name: String)
    var compact = false
    var body: some View {
        TopicTitle(number: heading.number, name: heading.name, compact: compact)
            .padding(.top, compact ? 8 : 14).padding(.bottom, compact ? 2 : 4).padding(.horizontal, 8)
    }
}
// A summary topic's number and name, the same wherever the topic is named: in the summary, and over the decisions,
// open issues and actions that came from it. Without a number (その他) the name is quieter.
struct TopicTitle: View {
    @Environment(\.searchTerms) private var terms
    let number: Int?
    let name: String
    var compact = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 7 : 9) {
            if let number {
                Text("\(number)").font(.system(size: compact ? 10 : 11, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: compact ? 17 : 19, height: compact ? 17 : 19)
                    .background(Circle().fill(Palette.sumire))
            }
            Text(highlighted(name, terms)).font(.system(size: compact ? 13.5 : 15, weight: .bold))
                .foregroundStyle(number == nil ? Color.secondary : Palette.sumi)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
// A section heading: its mark and count in the section's ink, the title in Mincho. Clicking it folds the section
// away or opens it again, with the chevron at its end showing which.
struct SectionHeading<Trailing: View>: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let tone: NoteTone
    let count: Int
    var compact = false
    var folds = true
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        let folded = store.foldedSections.contains(title)
        if folds {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { store.toggleFolded(title) }
            } label: {
                heading(folded: folded).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? "クリックで開く" : "クリックで畳む")
            .accessibilityValue(folded ? "畳んでいます" : "開いています")
        } else {
            heading(folded: false)
        }
    }
    private func heading(folded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 8) {
            Image(systemName: tone.symbol).font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(tone.color)
            Text(title).font(.mincho(compact ? 14 : 17)).foregroundStyle(Palette.sumi)
            Text("\(count)").font(.system(size: compact ? 10.5 : 11.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(tone.color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(tone.color.opacity(0.1)))
            Spacer(minLength: 8)
            trailing()
            if folds {
                Image(systemName: "chevron.down").font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(folded ? -90 : 0))
            }
        }
    }
}
extension SectionHeading where Trailing == EmptyView {
    init(title: String, tone: NoteTone, count: Int, compact: Bool = false, folds: Bool = true) {
        self.init(title: title, tone: tone, count: count, compact: compact, folds: folds) { EmptyView() }
    }
}
// The rule under a heading begins in the section's ink.
struct SectionRule: View {
    let tone: NoteTone
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Palette.rule).frame(height: 1)
            Rectangle().fill(tone.color).frame(width: 40, height: 2)
        }
        .frame(height: 2)
    }
}
// The tint of items the latest update added or changed.
struct FreshSwatch: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Palette.asagi.opacity(0.22)).frame(width: 14, height: 9)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.asagi.opacity(0.6), lineWidth: 0.5))
    }
}
@MainActor final class NoteDraft: ObservableObject {
    @Published var text = ""
    @Published var owner = ""
    @Published var due = ""
    @Published var reason = ""
    @Published var nextStep = ""
    @Published var points = ""  // One per line.
    @Published var opinions = ""
    @Published var done = false
    var cancelled = false
    var opening: NoteField?  // The field to type in when the item opens, when not its text.
    private var original: NoteItem?  // The item as last loaded; only fields changed from it are saved.
    func load(_ item: NoteItem) {
        text = item.text
        owner = item.owner ?? ""
        due = item.due ?? ""
        reason = item.reason ?? ""
        nextStep = item.nextStep ?? ""
        points = item[.points] ?? ""
        opinions = item[.opinions] ?? ""
        done = item.state == .done
        original = item
        cancelled = false
    }
    /// The item changed while open (a word fixed across the meeting): fields not typed in follow it.
    func follow(_ item: NoteItem) {
        guard let original else { return load(item) }
        if text == original.text { text = item.text }
        if owner == original.owner ?? "" { owner = item.owner ?? "" }
        if due == original.due ?? "" { due = item.due ?? "" }
        if reason == original.reason ?? "" { reason = item.reason ?? "" }
        if nextStep == original.nextStep ?? "" { nextStep = item.nextStep ?? "" }
        if points == original[.points] ?? "" { points = item[.points] ?? "" }
        if opinions == original[.opinions] ?? "" { opinions = item[.opinions] ?? "" }
        if done == (original.state == .done) { done = item.state == .done }
        self.original = item
    }
    /// Applies the fields changed in the editor, leaving the rest of the item as it is now.
    func apply(to item: inout NoteItem, action: Bool) {
        func optional(_ value: String) -> String? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let original else { return }
        if text != original.text, let text = optional(text) { item.text = text }
        if reason != original.reason ?? "" { item.reason = optional(reason) }
        if nextStep != original.nextStep ?? "" { item.nextStep = optional(nextStep) }
        if points != original[.points] ?? "" { item[.points] = points }
        if opinions != original[.opinions] ?? "" { item[.opinions] = opinions }
        guard action else { return }
        if owner != original.owner ?? "" { item.owner = optional(owner) }
        if due != original.due ?? "" { item.due = optional(due) }
        if done != (original.state == .done) && item.state != .cancelled { item.state = done ? .done : .open }
    }
}
// Click an item to edit it in place. Leaving it (完了, Return, or opening another item) saves; Esc cancels. An item
// edited by hand is kept as it is by later AI updates.
struct EditableNoteRow: View {
    @EnvironmentObject var store: Store
    @StateObject private var draft = NoteDraft()
    @FocusState private var focused: NoteField?
    let editing: NoteEditing
    let item: NoteItem
    let known: [String: Segment]
    let fresh: Bool
    let tone: NoteTone
    var number: Int?
    var current = false
    var revised = false
    var topics: [NoteItem] = []  // The summary's topics, which a decision, open issue or action can be moved under.
    private var action: Bool { tone == .actions }
    private var key: String { editing.part.rawValue + "/" + item.id }
    // Decisions, open issues and actions can go under another summary topic: from the menu, or dragged there.
    private var movable: Bool { editing.part != .summary && !topics.isEmpty }
    private var drag: NoteItemDrag { NoteItemDrag(meetingID: editing.meetingID, part: editing.part, id: item.id) }
    var body: some View {
        let open = store.editingNoteItem == key
        Group {
            if open {
                editor
            } else {
                NoteRow(
                    item: item, known: known, fresh: fresh, tone: tone, number: number, current: current,
                    revised: revised,
                    edit: { field in
                        draft.opening = field
                        store.editingNoteItem = key
                    },
                    toggle: item.state == .cancelled ? nil : { toggleDone() },
                    due: DuePicking(meetingDate: meetingDate) { date in setDue(date) },
                    setOwner: { name in setOwner(name) }
                )
                .contextMenu {
                    Button("編集", systemImage: "pencil") { store.editingNoteItem = key }
                    if movable { topicMenu }
                    Button("削除", systemImage: "trash", role: .destructive) { remove() }
                }
                .modifier(DraggableNoteItem(item: item, drag: movable ? drag : nil))
            }
        }
        .onChange(of: open, initial: true) { wasOpen, isOpen in
            if isOpen {
                draft.load(item)
                let field = draft.opening ?? .text
                draft.opening = nil
                // The editor's fields appear with this change; focus can move into one only once they are there.
                Task { @MainActor in focused = field }
            } else if wasOpen && !draft.cancelled {
                save()
            }
        }
        .onChange(of: item) { if open { draft.follow(item) } }
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(editing.part == .summary ? "話題：概要" : "内容", text: $draft.text, axis: .vertical)
                .font(.system(size: 14.5)).focused($focused, equals: .text).onSubmit(finish)
            if editing.part == .summary {
                ListField(title: "主な論点", ink: Palette.sumire, text: $draft.points)
                    .focused($focused, equals: .points)
                ListField(title: "主な意見", ink: Palette.seiheki, text: $draft.opinions)
                    .focused($focused, equals: .opinions)
            }
            if action {
                HStack(spacing: 10) {
                    // The list of people sits before the field, so it reads as the owner's, not the deadline's.
                    HStack(spacing: 4) {
                        let people = store.knownOwners
                        if !people.isEmpty {
                            Menu {
                                // Each name is ticked on or off, so an action can have several owners.
                                ForEach(people.prefix(30), id: \.self) { name in
                                    Toggle(
                                        name,
                                        isOn: Binding(
                                            get: { NoteItem.names(draft.owner).contains(name) },
                                            set: { _ in draft.owner = NoteItem.toggling(name, in: draft.owner) ?? ""
                                            }))
                                }
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("これまでの担当者から選ぶ")
                        }
                        TextField("担当", text: $draft.owner).focused($focused, equals: .owner).onSubmit(finish)
                    }
                    DueField(text: $draft.due, meetingDate: meetingDate)
                    Toggle("完了", isOn: $draft.done).toggleStyle(.checkbox)
                }
                .font(.callout)
            }
            if editing.part != .summary || !draft.reason.isEmpty {
                TextField("理由（任意）", text: $draft.reason, axis: .vertical)
                    .font(.caption).focused($focused, equals: .reason).onSubmit(finish)
            }
            if editing.part == .unresolved || !draft.nextStep.isEmpty {
                TextField("次の確認（任意）", text: $draft.nextStep, axis: .vertical)
                    .font(.caption).focused($focused, equals: .nextStep).onSubmit(finish)
            }
            HStack(spacing: 10) {
                Button("削除", role: .destructive, action: remove).buttonStyle(.borderless)
                Spacer()
                Text(editing.part == .summary ? "論点と意見は1行に1つ・Esc で取り消し" : "Return で確定・Esc で取り消し")
                    .font(.caption).foregroundStyle(.secondary)
                Button("完了", action: finish)
            }
            .controlSize(.small)
        }
        .textFieldStyle(.plain)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.asagi.opacity(0.1)))
        .onEscape {
            draft.cancelled = true
            store.editingNoteItem = nil
        }
    }
    private func finish() { store.editingNoteItem = nil }
    // The summary topics, the one the item is under ticked: choosing another moves it there.
    private var topicMenu: some View {
        let under = MinutesEngine.topicIndex(of: item, in: topics, known: known)
        return Menu("話題を移す", systemImage: "arrow.turn.down.right") {
            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                let parts = MinutesEngine.summaryParts(topic.text)
                let name = parts.topic ?? String(parts.overview.prefix(30))
                Toggle(
                    "\(index + 1). \(name)",
                    isOn: Binding(
                        get: { under == index },
                        set: { _ in
                            store.moveNoteItem(editing.meetingID, part: editing.part, id: item.id, toTopic: index)
                        }
                    ))
            }
        }
    }
    private var meetingDate: Date { store.meetings.first { $0.id == editing.meetingID }?.date ?? Date() }
    private func setDue(_ date: Date?) {
        let meetingDate = meetingDate
        store.updateNoteItem(editing.meetingID, part: editing.part, id: item.id) {
            $0.due = date.map { DueDate.text($0, from: meetingDate) }
        }
    }
    private func setOwner(_ name: String?) {
        store.updateNoteItem(editing.meetingID, part: editing.part, id: item.id, offersCorrection: false) {
            $0.owner = name
        }
    }
    private func toggleDone() {
        store.updateNoteItem(editing.meetingID, part: editing.part, id: item.id) {
            $0.state = $0.state == .done ? .open : .done
        }
    }
    private func save() {
        let draft = draft
        let action = action
        store.updateNoteItem(editing.meetingID, part: editing.part, id: item.id) {
            draft.apply(to: &$0, action: action)
        }
    }
    private func remove() {
        draft.cancelled = true
        store.removeNoteItem(editing.meetingID, part: editing.part, id: item.id)
    }
}
// An item picked up to drag to another topic shows its text, short, as it moves.
struct DraggableNoteItem: ViewModifier {
    let item: NoteItem
    let drag: NoteItemDrag?
    @ViewBuilder func body(content: Content) -> some View {
        if let drag {
            content.draggable(drag.payload) {
                Text(item.text).font(.callout).lineLimit(2).frame(maxWidth: 360, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.paper))
                    .foregroundStyle(Palette.sumi)
            }
        } else {
            content
        }
    }
}
// A summary topic's points or opinions, one per line: Return starts the next one.
struct ListField: View {
    let title: String
    let ink: Color
    @Binding var text: String
    var body: some View {
        // A text editor has no baseline to share, so the label lines up with its first line by hand.
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(ink)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.1)))
                .padding(.top, 1)
            TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden)
                .frame(minHeight: 22, maxHeight: 90).fixedSize(horizontal: false, vertical: true)
        }
    }
}
// "＋ 追加" at the end of an editable section opens a field; Return adds the item, an empty Return closes it.
struct AddNoteItem: View {
    @EnvironmentObject var store: Store
    @StateObject private var draft = TextDraft()
    @FocusState private var focused: Bool
    let editing: NoteEditing
    private var key: String { editing.meetingID.uuidString + "/" + editing.part.rawValue }
    var body: some View {
        Group {
            if store.addingNoteItem == key {
                HStack(spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                    TextField(placeholder, text: $draft.text, axis: .vertical)
                        .textFieldStyle(.plain).focused($focused)
                        .onSubmit(add)
                        .onEscape { close() }
                }
                .font(.system(size: 14.5))
                .padding(.vertical, 9).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.asagi.opacity(0.1)))
                .onAppear { focused = true }
            } else {
                Button {
                    store.addingNoteItem = key
                } label: {
                    Label("追加", systemImage: "plus").font(.callout)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .padding(.top, 6).padding(.horizontal, 8)
            }
        }
    }
    private var placeholder: String {
        switch editing.part {
        case .summary: "要約を追加（話題：結論や現状）"
        case .decisions: "決定事項を追加"
        case .unresolved: "未決事項を追加"
        case .actions: "アクションを追加"
        }
    }
    private func add() {
        if store.addNoteItem(editing.meetingID, part: editing.part, text: draft.text) != nil {
            draft.text = ""
        } else {
            close()
        }
    }
    private func close() {
        draft.text = ""
        store.addingNoteItem = nil
    }
}
@MainActor final class CorrectionDraft: ObservableObject {
    @Published var from = ""
    @Published var to = ""
    @Published var excluded: Set<String> = []  // Occurrences the user unchecked.
    @Published var addsToVocabulary = true
}
// Fix a misheard word across the meeting: every occurrence, and other spellings that read the same, each with its
// context and a checkbox. Corrections made earlier can be undone here.
struct CorrectionSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = CorrectionDraft()
    let request: CorrectionRequest
    var body: some View {
        let meeting = store.meetings.first { $0.id == request.meetingID }
        let found = meeting?.occurrences(of: draft.from, correctedTo: draft.to) ?? []
        let chosen = found.filter { !draft.excluded.contains($0.id) }
        let to = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 14) {
            Text("語句をまとめて直す").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                TextField("誤った語（例：森バス）", text: $draft.from)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("正しい語（例：モリバス）", text: $draft.to)
            }
            .textFieldStyle(.roundedBorder)
            if let meeting, !draft.from.trimmingCharacters(in: .whitespaces).isEmpty {
                if found.isEmpty {
                    Text("この会議に「\(draft.from)」は見つかりません。").font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            group("同じ表記", found.filter(\.exact), in: meeting)
                            group("読みが同じ別の表記", found.filter { !$0.exact }, in: meeting)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                }
            }
            Toggle(isOn: $draft.addsToVocabulary) {
                Text(to.isEmpty ? "正しい語を用語集にも追加" : "「\(to)」を用語集にも追加（ほかの会議の文字起こしでも使います）")
            }
            .toggleStyle(.checkbox)
            if let corrections = meeting?.corrections, !corrections.isEmpty {
                Divider()
                Text("この会議で直した語句").font(.callout.weight(.semibold))
                ForEach(corrections) { correction in
                    HStack {
                        Text(correction.variants.joined(separator: "・") + " → " + correction.to)
                        if correction.learned == true {
                            Text("自動").font(.caption.weight(.semibold)).foregroundStyle(Palette.asagi)
                                .help("これまでに直した語句から、自動で直しました")
                        }
                        Text("\(correction.changes.count)か所").foregroundStyle(.secondary)
                        Spacer()
                        Button("取り消す") { store.undoCorrection(request.meetingID, correction.id) }
                            .controlSize(.small)
                    }
                    .font(.callout)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "直す" : "\(chosen.count)か所を直す") {
                    store.applyCorrection(
                        request.meetingID, occurrences: chosen, to: to, addToVocabulary: draft.addsToVocabulary)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || to.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            draft.from = request.from
            draft.to = request.to
        }
        .onChange(of: draft.from) { draft.excluded = [] }
    }
    @ViewBuilder private func group(_ title: String, _ occurrences: [TermOccurrence], in meeting: Meeting) -> some View
    {
        if !occurrences.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title)（\(occurrences.count)か所）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(occurrences) { occurrence in
                    Toggle(isOn: chosen(occurrence)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(occurrence.place, in: meeting)).font(.caption).foregroundStyle(.secondary)
                            Text(snippet(occurrence, in: meeting)).font(.callout).lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
    private func chosen(_ occurrence: TermOccurrence) -> Binding<Bool> {
        Binding(
            get: { !draft.excluded.contains(occurrence.id) },
            set: { checked in
                if checked { draft.excluded.remove(occurrence.id) } else { draft.excluded.insert(occurrence.id) }
            })
    }
    private func label(_ place: TextPlace, in meeting: Meeting) -> String {
        switch place {
        case .title: return "タイトル"
        case .agendaTitle, .agendaGoal: return "アジェンダ"
        case .item(let part, _, let field):
            let sections: [NotePart: String] = [
                .summary: "要約", .decisions: "決定事項", .unresolved: "未決事項", .actions: "アクション",
            ]
            let fields: [NoteField: String] = [
                .owner: "の担当", .due: "の期限", .reason: "の理由", .nextStep: "の次の確認", .points: "の論点",
                .opinions: "の意見",
            ]
            return (sections[part] ?? "") + (fields[field] ?? "")
        case .segment(let id):
            let segment = meeting.segments.first { $0.id == id }
            return "文字起こし " + (segment.map { clock($0.time) + " " + $0.source } ?? "")
        }
    }
    /// The occurrence with some text around it, the occurrence marked.
    private func snippet(_ occurrence: TermOccurrence, in meeting: Meeting) -> AttributedString {
        let text = (meeting.text(at: occurrence.place) ?? "") as NSString
        let range = occurrence.range
        guard NSMaxRange(range) <= text.length else { return AttributedString(occurrence.found) }
        let start = max(0, range.location - 24)
        let end = min(text.length, NSMaxRange(range) + 24)
        var result = AttributedString(
            (start > 0 ? "…" : "") + text.substring(with: NSRange(location: start, length: range.location - start)))
        var found = AttributedString(occurrence.found)
        found.backgroundColor = Palette.yamabuki.opacity(0.35)
        result.append(found)
        result.append(
            AttributedString(
                text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
                    + (end < text.length ? "…" : "")))
        return result
    }
}
// After an edit that fixed a word, offers to fix the same word, or another spelling that reads the same, elsewhere.
struct CorrectionOfferView: View {
    @EnvironmentObject var store: Store
    let offer: CorrectionOffer
    var stacked = false  // Buttons under the message, for the narrow transcript column.
    var body: some View {
        let message = Text("「\(offer.from)」を「\(offer.to)」に直しました。ほかの\(offer.count)か所も直しますか？")
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    message
                    HStack(spacing: 6) { buttons }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "character.cursor.ibeam").foregroundStyle(Palette.asagi)
                    message
                    Spacer(minLength: 8)
                    buttons
                }
            }
        }
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.asagi.opacity(stacked ? 0.2 : 0.12)))
    }
    @ViewBuilder private var buttons: some View {
        Button("すべて直す") { store.applyOfferedCorrection() }
        Button("確認して直す") {
            store.correcting = CorrectionRequest(meetingID: offer.meetingID, from: offer.from, to: offer.to)
            store.correctionOffer = nil
        }
        Button("直さない") { store.correctionOffer = nil }
    }
}
struct NoteRow: View {
    @Environment(\.searchTerms) private var terms
    let item: NoteItem
    let known: [String: Segment]
    let fresh: Bool
    let tone: NoteTone
    var number: Int?  // A summary topic's place in the meeting.
    var compact = false
    var current = false  // The find bar's current match.
    var revised = false  // It cites a transcript line corrected or deleted since it was written.
    // Set where the minutes can be edited: clicking the text, the pencil, or an owner or deadline opens the item at
    // that field, and an action's box ticks it done.
    var edit: ((NoteField) -> Void)?
    var toggle: (() -> Void)?
    @StateObject private var hover = Flag()
    @StateObject private var calendar = Flag()
    var due: DuePicking?  // Set where an action's deadline can be picked from a calendar.
    var setOwner: ((String?) -> Void)?  // Set where an action's owner can be picked from everyone named before.
    @StateObject private var people = Flag()
    private var action: Bool { tone == .actions }
    private var closed: Bool { item.state != .open }
    // A summary topic is marked by its number instead of a bullet.
    private var topic: Bool { tone == .summary && SummaryTopic.applies(to: item) }
    var body: some View {
        let evidence = item.evidence.compactMap { known[$0] }.sorted { $0.time < $1.time }
        let indent: CGFloat = topic && number != nil ? SummaryTopic.indent(compact) : 0  // Past a topic's number.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !topic { bullet }
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                Group {
                    if topic {
                        SummaryTopic(item: item, number: number, compact: compact)
                    } else {
                        // Decisions carry the weight a reader scans for.
                        Text(highlighted(item.text, terms))
                            .font(
                                .system(
                                    size: compact ? 13 : 14.5,
                                    weight: tone == .decisions && !closed ? .semibold : .regular)
                            )
                            .lineSpacing(compact ? 2 : 4)
                            .strikethrough(item.state == .cancelled)
                            .foregroundStyle(closed ? Color.secondary : Palette.sumi)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .modifier(Selectable(enabled: edit == nil))  // A selectable text would take the click.
                .contentShape(Rectangle())
                .onTapGesture { edit?(.text) }
                .help(edit == nil ? "" : "クリックして編集")
                if let reason = item.reason {
                    NoteDetail(label: "理由", text: reason, color: tone.color, compact: compact).padding(.leading, indent)
                }
                if let next = item.nextStep {
                    NoteDetail(label: "次の確認", text: next, color: Palette.yamabukiInk, compact: compact)
                        .padding(.leading, indent)
                }
                if let change = item.changeSummary {
                    NoteDetail(label: "経緯", text: change, color: NoteTone.history.color, compact: compact)
                        .padding(.leading, indent)
                }
                if action || closed || item.edited == true || revised {
                    HStack(spacing: 6) {
                        if revised {
                            Label("要確認", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon).fontWeight(.semibold).foregroundStyle(Palette.yamabukiInk)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.yamabuki.opacity(0.18)))
                                .help("根拠の発言を文字起こしで直したか削除しました。今も合っているか確かめてください")
                        }
                        if action {
                            Tag(
                                label: "担当", symbol: "person.fill",
                                value: item.owners.isEmpty ? nil : item.owners.joined(separator: "・"), open: !closed
                            )
                            .editing(setOwner.map { _ in { people.on = true } }, help: "クリックして担当者を選ぶ")
                            .popover(isPresented: $people.on, arrowEdge: .bottom) {
                                if let setOwner {
                                    OwnerPicker(current: item.owner, set: setOwner, close: { people.on = false })
                                }
                            }
                            Tag(label: "期限", symbol: "calendar", value: item.due, open: !closed)
                                .editing(due.map { _ in { calendar.on = true } }, help: "クリックして期限の日付を選ぶ")
                                .popover(isPresented: $calendar.on, arrowEdge: .bottom) {
                                    if let due {
                                        DueCalendar(current: item.due, picking: due, close: { calendar.on = false })
                                    }
                                }
                        } else if closed {
                            Text(item.state == .done ? "解決済み" : "撤回・統合").foregroundStyle(Palette.asagi)
                        }
                        if item.edited == true {
                            Label("手直し", systemImage: "pencil").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                                .help("手で直した項目です。AI の更新では書き換わりません")
                        }
                    }
                    .font(.system(size: compact ? 11 : 11.5))
                    .padding(.leading, indent)
                }
                if let first = evidence.first {
                    DisclosureGroup {
                        ForEach(evidence) { segment in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    PlayButton(segment: segment)
                                    Text("\(clock(segment.time)) \(segment.source)").foregroundStyle(.secondary)
                                }
                                Text(highlighted(segment.text, terms)).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)  // Each line from the left edge.
                        }
                    } label: {
                        Text("根拠 \(clock(first.time))〜（\(evidence.count)件）").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.leading, indent)
                }
            }
        }
        .padding(.vertical, compact ? 6 : 10).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4).fill(
                fresh ? Palette.asagi.opacity(0.1) : hover.on ? Palette.sumi.opacity(0.035) : .clear)
        )
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(current ? Palette.yamabuki : .clear, lineWidth: 1.5))
        // An editable item shows a pencil while the pointer is over it.
        .overlay(alignment: .topTrailing) {
            if let edit, hover.on {
                Button {
                    edit(.text)
                } label: {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .padding(6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("編集").padding(.top, 4).padding(.trailing, 2)
            }
        }
        .onHover { inside in if edit != nil { hover.on = inside } }
    }
    // The bullet says what kind of item it is: a check for a decision, an open ring for an open question, a box to
    // tick for a task.
    @ViewBuilder private var bullet: some View {
        let size: CGFloat = compact ? 12 : 13
        switch tone {
        case .actions:
            let box = Image(
                systemName: item.state == .done
                    ? "checkmark.square.fill" : item.state == .cancelled ? "xmark.square" : "square"
            )
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(closed ? Color.secondary : tone.color)
            if let toggle {
                Button(action: toggle) { box }.buttonStyle(.plain)
                    .help(item.state == .done ? "未完了に戻す" : "完了にする")
            } else {
                box
            }
        case .decisions:
            Image(systemName: "checkmark").font(.system(size: size - 2, weight: .heavy))
                .foregroundStyle(closed ? Color.secondary : tone.color)
        case .unresolved:
            Circle().strokeBorder(Palette.yamabuki, lineWidth: 1.8).frame(width: 9, height: 9)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
        case .agenda, .summary, .history:
            Circle().fill(tone.color.opacity(tone == .summary ? 0.55 : 0.35)).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
        }
    }
}
// A summary topic: its number and name, then what it came to, the points at issue and the views put forward. Each
// part has its own ink (sumi for the overview, sumire for the points, seiheki for the views), and the text after the
// labels lines up.
struct SummaryTopic: View {
    @Environment(\.searchTerms) private var terms
    let item: NoteItem
    var number: Int?
    var compact = false
    static func applies(to item: NoteItem) -> Bool {
        MinutesEngine.summaryTopic(item.text) != nil || item.points != nil || item.opinions != nil
    }
    /// How far the topic's parts sit in from its number: the number's width and the space after it.
    static func indent(_ compact: Bool) -> CGFloat { compact ? 17 + 7 : 19 + 9 }
    private struct Part {
        let label: String
        let ink: Color
        let lines: [String]
    }
    var body: some View {
        // Without a topic before "：", the whole text is the title.
        let parts = MinutesEngine.summaryParts(item.text)
        let rows = [
            Part(label: "概要", ink: Palette.sumi.opacity(0.7), lines: parts.topic == nil ? [] : [parts.overview]),
            Part(label: "主な論点", ink: Palette.sumire, lines: item.points ?? []),
            Part(label: "主な意見", ink: Palette.seiheki, lines: item.opinions ?? []),
        ].filter { !$0.lines.isEmpty }
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            TopicTitle(number: number, name: parts.topic ?? parts.overview, compact: compact)
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                ForEach(rows, id: \.label) { part in
                    HStack(alignment: .firstTextBaseline, spacing: compact ? 8 : 12) {
                        // Labeled like a decision's 理由 or an open issue's 次の確認.
                        Text(part.label).font(.system(size: compact ? 10 : 10.5, weight: .bold))
                            .foregroundStyle(part.ink)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 3).fill(part.ink.opacity(0.1)))
                            .frame(width: compact ? 54 : 60, alignment: .leading)
                        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                            ForEach(Array(part.lines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    if part.label != "概要" {
                                        Circle().fill(part.ink.opacity(0.7)).frame(width: 5, height: 5)
                                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                                    }
                                    Text(highlighted(line, terms)).lineSpacing(compact ? 1.5 : 3.5)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .font(.system(size: part.label == "概要" ? (compact ? 12.5 : 14) : (compact ? 12 : 13.5)))
                        .foregroundStyle(Palette.sumi.opacity(part.label == "概要" ? 1 : 0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, number == nil ? 0 : Self.indent(compact))
        }
    }
}
// A reason or next step under an item: a small label in the section's ink, then the text a little smaller than the
// item, still dark enough to read.
struct NoteDetail: View {
    @Environment(\.searchTerms) private var terms
    let label: String
    let text: String
    let color: Color
    var compact = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: compact ? 10 : 10.5, weight: .bold)).foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.1)))
            Text(highlighted(text, terms)).font(.system(size: compact ? 11.5 : 12.5)).lineSpacing(2)
                .foregroundStyle(Palette.sumi.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
@MainActor final class Flag: ObservableObject {
    @Published var on = false
}
// An action's owner: everyone named as an owner before, to pick with one click, or a new name typed in.
// An action's owners: everyone named as an owner before, each ticked on or off with one click, or a new name typed
// in. An action can have several owners.
struct OwnerPicker: View {
    @EnvironmentObject var store: Store
    @StateObject private var draft = TextDraft()
    @FocusState private var focused: Bool
    let current: String?
    let set: (String?) -> Void
    let close: () -> Void
    var body: some View {
        let typed = draft.text.trimmingCharacters(in: .whitespaces)
        let chosen = Set(NoteItem.names(current).map(Store.personKey))
        let people = store.knownOwners.filter { typed.isEmpty || $0.localizedStandardContains(typed) }
        VStack(alignment: .leading, spacing: 10) {
            TextField("名前を入力して Enter", text: $draft.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    guard !typed.isEmpty else { return close() }
                    if !chosen.contains(Store.personKey(typed)) { set(NoteItem.toggling(typed, in: current)) }
                    draft.text = ""
                }
            if !people.isEmpty {
                Text(typed.isEmpty ? "これまでの担当者（押すと加わり、もう一度押すと外れます）" : "一致する担当者")
                    .font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(people.prefix(24), id: \.self) { name in
                        Button {
                            set(NoteItem.toggling(name, in: current))
                        } label: {
                            Label(name, systemImage: "checkmark").labelStyle(
                                ChosenLabelStyle(chosen: chosen.contains(Store.personKey(name))))
                        }
                        .buttonStyle(PersonChipStyle(chosen: chosen.contains(Store.personKey(name))))
                    }
                }
            }
            HStack {
                if current != nil {
                    Button("未定にする") {
                        set(nil)
                        close()
                    }
                }
                Spacer()
                Button("閉じる", action: close)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .onAppear { Task { @MainActor in focused = true } }
        // A popover is dark app chrome even when opened from the paper sheet, whose dark ink would not read on it:
        // both the color scheme and the ink passed down from the sheet are set back.
        .foregroundStyle(Color.primary)
        .environment(\.colorScheme, .dark)
    }
}
// A chip's name, with a check in front once the person is chosen.
struct ChosenLabelStyle: LabelStyle {
    let chosen: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if chosen { configuration.icon.font(.system(size: 10, weight: .bold)) }
            configuration.title
        }
    }
}
struct PersonChipStyle: ButtonStyle {
    var chosen = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: chosen ? .bold : .medium)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(chosen ? Color.accentColor.opacity(0.18) : .clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(chosen ? 0.5 : 0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}
/// Where an action's deadline can be picked: the meeting's day, from which said days are counted, and what to do
/// with the picked day (nil for none).
struct DuePicking {
    let meetingDate: Date
    let set: (Date?) -> Void
}
// A calendar for an action's deadline. Picking a day saves it and closes; 未定にする clears it. A deadline said in
// words that names no day ("11月") is shown above, so it is not lost by surprise.
struct DueCalendar: View {
    @StateObject private var selection = DateSelection()
    let current: String?
    let picking: DuePicking
    let close: () -> Void
    var body: some View {
        let day = DueDate.parse(current, from: picking.meetingDate)
        VStack(alignment: .leading, spacing: 10) {
            if let current, day == nil {
                Text("今の期限：\(current)").font(.caption).foregroundStyle(.secondary)
            }
            DatePicker(
                "期限",
                selection: Binding(
                    get: { selection.date },
                    set: { date in
                        selection.date = date
                        picking.set(date)
                        close()
                    }), displayedComponents: .date
            )
            .datePickerStyle(.graphical).labelsHidden()
            HStack {
                if current != nil {
                    Button("未定にする") {
                        picking.set(nil)
                        close()
                    }
                }
                Spacer()
                Button("閉じる", action: close).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .onAppear { selection.date = day ?? DueDate.calendar.startOfDay(for: picking.meetingDate) }
        .foregroundStyle(Color.primary)
        .environment(\.colorScheme, .dark)  // Dark app chrome, like the owner list.
    }
}
@MainActor final class DateSelection: ObservableObject {
    @Published var date = Date()
}
// The deadline in the item editor: the day it names, as a button that opens the calendar, and a button to clear it.
struct DueField: View {
    @StateObject private var calendar = Flag()
    @Binding var text: String
    let meetingDate: Date
    var body: some View {
        let day = DueDate.parse(text, from: meetingDate)
        HStack(spacing: 4) {
            Button {
                calendar.on = true
            } label: {
                Label(
                    day.map { DueDate.text($0, from: meetingDate) } ?? (text.isEmpty ? "期限を選ぶ" : text + "（日付を選ぶ）"),
                    systemImage: "calendar")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(text.isEmpty ? Color.secondary : Palette.sumi)
            .popover(isPresented: $calendar.on, arrowEdge: .bottom) {
                DueCalendar(
                    current: text.isEmpty ? nil : text,
                    picking: DuePicking(meetingDate: meetingDate) { date in
                        text = date.map { DueDate.text($0, from: meetingDate) } ?? ""
                    },
                    close: { calendar.on = false })
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("期限を未定にする")
            }
        }
    }
}
extension View {
    /// Esc runs the action. A focused text field takes Esc for word completion before .onExitCommand sees it, so
    /// the key is also caught on its way in.
    func onEscape(_ action: @escaping () -> Void) -> some View {
        onExitCommand(perform: action).onKeyPress(.escape) {
            action()
            return .handled
        }
    }
    /// Makes the view a button that opens the item for editing, where it can be edited.
    @ViewBuilder func editing(_ action: (() -> Void)?, help: String) -> some View {
        if let action {
            Button(action: action) { self }.buttonStyle(.plain).help(help)
        } else {
            self
        }
    }
}
// Plays an utterance from the meeting's recording, to check a name, a figure or how a decision was put; shown once
// the recording is over. While it plays, it stops it. `shown` hides it until the pointer is over the line, keeping
// its space so nothing moves.
struct PlayButton: View {
    @EnvironmentObject var store: Store
    @Environment(\.playableMeeting) private var meetingID
    let segment: Segment
    var shown = true
    var body: some View {
        if let meetingID {
            PlayButtonLabel(player: store.player, segment: segment, shown: shown) { store.play(segment, in: meetingID) }
        }
    }
}
private struct PlayButtonLabel: View {
    @ObservedObject var player: ClipPlayer
    let segment: Segment
    let shown: Bool
    let action: () -> Void
    var body: some View {
        let playing = player.playing == segment.id
        Button(action: action) {
            Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                .foregroundStyle(playing ? Palette.asagi : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(playing ? "再生を止める" : "この発言を録音で聞く")
        .opacity(shown || playing ? 1 : 0)
        .accessibilityLabel(playing ? "再生を止める" : "この発言を再生")
    }
}
struct Selectable: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}
// An action's owner or deadline. One still missing on an open action is flagged in yamabuki, so the facilitator can
// ask for it.
struct Tag: View {
    let label: String
    let symbol: String
    let value: String?
    var open = false
    var body: some View {
        let missing = value == nil && open
        let ink = missing ? Palette.yamabukiInk : Palette.ruri
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.opacity(0.8))
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "未定").fontWeight(value != nil ? .semibold : .medium)
                .foregroundStyle(value != nil ? Palette.sumi : missing ? Palette.yamabukiInk : Color.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(open ? ink.opacity(0.08) : Palette.rule.opacity(0.3)))
    }
}

// MARK: - Transcript panel

// Whether the transcript is scrolled to its end; following new speech pauses while the user reads back.
@MainActor final class TranscriptFollow: ObservableObject {
    @Published var atEnd = true
}
// A find bar for one meeting's transcript or minutes: Return or ↓ goes to the next match, ↑ to the previous one,
// Esc closes it.
struct FindBar: View {
    @Binding var state: FindState
    let placeholder: String
    let count: Int
    var dark = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $state.query)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit { state.step(1, count: count) }
                .onEscape { state = FindState() }
            if !state.terms.isEmpty {
                Text(count == 0 ? "なし" : "\(min(state.index, count - 1) + 1)/\(count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            Button {
                state.step(-1, count: count)
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("前の一致").disabled(count == 0)
            Button {
                state.step(1, count: count)
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("次の一致（Return）").disabled(count == 0)
            Button {
                state = FindState()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .help("閉じる（Esc）")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(dark ? Palette.ai : Color.white.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.asagi.opacity(0.5)))
        .onAppear { focused = true }
        .onChange(of: state.focus) { focused = true }
        .onChange(of: state.query) { state.index = 0 }
    }
}
struct TranscriptPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.searchTerms) private var terms
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabs
    @StateObject private var follow = TranscriptFollow()
    let meeting: Meeting
    var showsHeader = true  // The compact window shows the count in its tab bar instead.
    var editable = false  // Lines can be corrected in the full window.
    var body: some View {
        let live = meeting.id == store.activeID
        let matches =
            terms.isEmpty
            ? []
            : meeting.segments.filter { segment in
                terms.contains { segment.text.range(of: $0, options: MeetingSearch.options) != nil }
            }
        // The find bar (full window only) takes over the highlighting from the meeting search while it has words.
        let find = showsHeader && store.transcriptFind.open ? store.transcriptFind : FindState()
        let found = MeetingSearch.lines(meeting, terms: find.terms)
        // An answer's link marks the utterance it points to, unless the find bar is on a match.
        let current =
            find.current(in: found) ?? store.revealed.flatMap { $0.meetingID == meeting.id ? $0.segmentID : nil }
        let shownTerms = find.terms.isEmpty ? terms : find.terms
        let asking = showsHeader && store.sideTab == "質問"
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                // The same tabs as the compact window's, so the panel reads as the page of the one chosen.
                HStack(alignment: .bottom, spacing: 2) {
                    sideTab("文字起こし", systemImage: "text.quote", count: meeting.segments.count)
                    sideTab("質問", systemImage: "bubble.left.and.text.bubble.right")
                    Spacer(minLength: 0)
                    let pending = meeting.jobs.filter { $0.state == .pending || $0.state == .running }.count
                    if !asking {
                        HStack(spacing: 8) {
                            if !terms.isEmpty {
                                Text("一致 \(matches.count)件").font(.caption.weight(.semibold)).foregroundStyle(
                                    Palette.yamabuki)
                            }
                            if pending > 0 {
                                Label("処理待ち \(pending)件", systemImage: "hourglass").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Button {
                                store.transcriptFind.open = true
                                store.transcriptFind.focus += 1
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("文字起こしの中を検索（⇧⌘F）")
                            .accessibilityLabel("文字起こしの中を検索")
                        }
                        .padding(.bottom, 9)
                    }
                }
                .padding(.top, 10)
                .pageTabBar()
            }
            if asking {
                AskPanel()
            } else {
                transcript(live: live, matches: matches, found: found, current: current, shownTerms: shownTerms)
            }
        }
        .background(Palette.deepAi)
    }
    private func sideTab(_ title: String, systemImage: String, count: Int? = nil) -> some View {
        let selected = store.sideTab == title
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { store.sideTab = title }
        } label: {
            PageTab(
                title: title, systemImage: systemImage, count: count, selected: selected, page: Palette.deepAi,
                ink: Palette.paper, outlined: true, namespace: tabs
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title == "質問" ? "すべての会議について、AIに質問する" : "この会議の文字起こし")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    @ViewBuilder private func transcript(
        live: Bool, matches: [Segment], found: [String], current: String?, shownTerms: [String]
    ) -> some View {
        if showsHeader && store.transcriptFind.open {
            FindBar(state: $store.transcriptFind, placeholder: "文字起こしを検索", count: found.count, dark: true)
                .padding(.horizontal, 12).padding(.top, 10)
        }
        if let offer = store.correctionOffer, offer.meetingID == meeting.id, offer.inTranscript, editable {
            CorrectionOfferView(offer: offer, stacked: true).padding(.horizontal, 12).padding(.top, 10)
        }
        if meeting.segments.isEmpty {
            Text(live ? "最初の発言は10秒ほどで表示されます。" : "文字起こしはまだありません。")
                .font(.callout).foregroundStyle(.secondary).padding(16)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(meeting.segments) { segment in
                            TranscriptRow(
                                segment: segment, meetingID: meeting.id, editable: editable,
                                current: segment.id == current
                            ).id(segment.id)
                        }
                    }
                    .padding(16)
                    .textSelection(.enabled)
                    .environment(\.searchTerms, shownTerms)
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
                    // Not while a line is being corrected or found: following would scroll it away.
                    if live && follow.atEnd && shownTerms.isEmpty && store.editingSegment == nil {
                        scrollToEnd(proxy)
                    }
                }
                .task(id: current) {
                    guard let current else { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)  // After the rows are laid out.
                    proxy.scrollTo(current, anchor: .center)
                }
                // A new search, or another meeting while searching, opens at the first matching utterance.
                .task(id: "\(meeting.id) \(terms.joined(separator: " "))") {
                    guard let first = matches.first?.id else { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)  // After the rows are laid out.
                    proxy.scrollTo(first, anchor: .center)
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
    // Jumps without animation, so no in-between offset is mistaken for the user scrolling back.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = meeting.segments.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
        if !follow.atEnd { follow.atEnd = true }
    }
}
// The 質問 tab: ask anything about the meetings, in words. The AI reads every meeting as it needs and answers here,
// with links to the meetings and utterances it read; a link opens the meeting at that utterance.
struct AskPanel: View {
    @EnvironmentObject var store: Store
    @StateObject private var draft = TextDraft()
    @FocusState private var focused: Bool
    private static let examples = ["先週決まったことは？", "終わっていないアクションは？", "この会議の要点は？"]
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.asked.isEmpty { intro }
                        ForEach(store.asked) { AskBubble(message: $0).id($0.id) }
                        if let progress = store.askProgress {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(progress + "…").font(.callout).foregroundStyle(Palette.paper.opacity(0.7))
                                Spacer(minLength: 0)
                                Button("止める") { store.stopAsking() }.buttonStyle(.borderless).font(.caption)
                            }
                            .id("progress")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A new question or answer is shown from its start.
                .onChange(of: store.asked.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .top) }
                }
                .onChange(of: store.askProgress) { _, progress in
                    if progress != nil { proxy.scrollTo("progress", anchor: .bottom) }
                }
            }
            composer
        }
        .environment(\.openURL, OpenURLAction { url in store.openAskLink(url) ? .handled : .systemAction })
        .onAppear { Task { @MainActor in focused = true } }
    }
    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会議について質問").font(.headline).foregroundStyle(Palette.paper)
            Text("すべての会議の議事録と文字起こしから、AIが探して答えます。答えのリンクから、その会議と発言を開けます。")
                .font(.callout).foregroundStyle(Palette.paper.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Self.examples, id: \.self) { example in
                Button {
                    store.ask(example)
                } label: {
                    Text(example).font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Palette.ai))
                        .overlay(Capsule().strokeBorder(PageTab.edge))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.paper)
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("会議について質問", text: $draft.text, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.plain).font(.callout).foregroundStyle(Palette.paper)
                    .focused($focused).onSubmit(send)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ai))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(
                            focused ? Palette.asagi.opacity(0.7) : PageTab.edge))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain).foregroundStyle(canSend ? Palette.asagi : Palette.paper.opacity(0.25))
                .disabled(!canSend).help("質問する（Return）").accessibilityLabel("質問する")
            }
            if !store.asked.isEmpty {
                Button("新しい会話") { store.clearAsked() }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(alignment: .top) { Rectangle().fill(PageTab.edge).frame(height: 1) }
    }
    private var canSend: Bool {
        store.askProgress == nil && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func send() {
        guard canSend else { return }
        store.ask(draft.text)
        draft.text = ""
    }
}
// One turn of the 質問 tab: a question on the right, an answer as text with links, a failure in yellow.
struct AskBubble: View {
    let message: AskMessage
    var body: some View {
        switch message.role {
        case .question:
            HStack {
                Spacer(minLength: 32)
                Text(message.text).font(.callout).foregroundStyle(Palette.paper)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ai))
                    .textSelection(.enabled)
            }
        case .answer:
            Text(Self.linked(message.text)).font(.system(size: 13)).lineSpacing(3).foregroundStyle(Palette.paper)
                .tint(Palette.asagi).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .failure:
            Label(message.text, systemImage: "exclamationmark.triangle.fill").font(.callout)
                .foregroundStyle(Palette.yamabuki).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// The answer with its Markdown links and bold, keeping its line breaks.
    static func linked(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var content: CGFloat
    var container: CGFloat
    var atEnd: Bool { offset + container >= content - 60 }
}
@MainActor final class LineDraft: ObservableObject {
    @Published var text = ""
    var original = ""
    var cancelled = false
}
// One utterance. Where the transcript is editable, clicking the text opens it: Return saves, Esc cancels, and a
// right-click deletes the line.
struct TranscriptRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.searchTerms) private var terms
    @StateObject private var draft = LineDraft()
    @StateObject private var hover = Flag()
    @FocusState private var focused: Bool
    let segment: Segment
    var meetingID: UUID?
    var editable = false
    var current = false  // The find bar's current match.
    var body: some View {
        let open = editable && store.editingSegment == segment.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: sourceSymbol(segment.source))
                Text(clock(segment.time)).monospacedDigit()
                Text(segment.source)
                if segment.edited == true {
                    Image(systemName: "pencil").help("手で直した発言です")
                }
                PlayButton(segment: segment, shown: hover.on)
            }
            .font(.caption).foregroundStyle(.secondary)
            if open {
                TextField("発言", text: $draft.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5))
                    .focused($focused)
                    .onSubmit { store.editingSegment = nil }
                    .onEscape {
                        draft.cancelled = true
                        store.editingSegment = nil
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.asagi.opacity(0.2)))
                Text("Return で確定・Esc で取り消し").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(highlighted(segment.text, terms)).font(.system(size: 13.5)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(Selectable(enabled: !editable))  // A selectable text would take the click.
                    .contentShape(Rectangle())
                    .onTapGesture { if editable { store.editingSegment = segment.id } }
                    .help(editable ? "クリックして編集" : "")
            }
        }
        .padding(current ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(current ? Palette.yamabuki : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .contextMenu {
            if editable, let meetingID {
                Button("編集", systemImage: "pencil") { store.editingSegment = segment.id }
                Button("この発言を削除", systemImage: "trash", role: .destructive) {
                    store.removeSegment(meetingID, id: segment.id)
                }
            }
        }
        .onChange(of: open, initial: true) { wasOpen, isOpen in
            if isOpen {
                draft.text = segment.text
                draft.original = segment.text
                draft.cancelled = false
                Task { @MainActor in focused = true }  // Once the field is on screen.
            } else if wasOpen && !draft.cancelled && draft.text != draft.original, let meetingID {
                store.updateSegment(meetingID, id: segment.id, text: draft.text)
            }
        }
        // A word fixed across the meeting while this line is open: follow it unless the line was typed in.
        .onChange(of: segment.text) {
            if open && draft.text == draft.original { draft.text = segment.text }
            draft.original = segment.text
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
    var body: some View {
        TabView(selection: $store.settingsTab) {
            GeneralSettings().tabItem { Label("一般", systemImage: "gearshape") }.tag("一般")
            TranscriptionSettings().tabItem { Label("文字起こし", systemImage: "text.quote") }.tag("文字起こし")
            TagSettings().tabItem { Label("タグ", systemImage: "tag") }.tag("タグ")
            MCPSettings().tabItem { Label("AI 連携", systemImage: "sparkles") }.tag("AI 連携")
        }
    }
}
struct GeneralSettings: View {
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
                    Text("文字起こしは gpt-transcribe、議事録は指定したモデルで作ります。APIキーはこのMacのKeychainに保存します。")
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
                    Picker("音がないときの自動停止", selection: $store.autoStopMinutes) {
                        Text("しない").tag(0)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0)分で止める").tag($0) }
                    }
                } header: {
                    Text("録音")
                } footer: {
                    Text(
                        "会議の音はイヤホンで聞き、声はMac本体のマイクで録ると、二重に録音されずに済みます。マイクにもMac音声にも人の声や物音がない状態が続くと、録音を自動で止めます（止める1分前に知らせます）。空調などの一定の音は無音として扱います。"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    LabeledContent("フォルダ") {
                        Text(displayPath(store.root)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    LabeledContent("使用量") {
                        if let usage = store.storageUsage {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("\(bytes(usage.total))（会議 \(usage.meetings)件）")
                                Group {
                                    Text("聞き返し用の録音 \(bytes(usage.recordings))")
                                    Text("作業用の音声 \(bytes(usage.working))")
                                    Text("議事録とデータ \(bytes(usage.other))")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Toggle("完了した会議の作業用の音声を自動で削除", isOn: $store.removesWorkingAudio)
                    HStack {
                        Button("Finderで表示") { NSWorkspace.shared.open(store.root) }
                        Button("作業用の音声を整理…") { store.confirmWorkingAudioCleanup() }
                            .disabled(store.reclaimableBytes == 0)
                            .help(
                                store.reclaimableBytes == 0
                                    ? "削除できる作業用の音声はありません"
                                    : "完了した会議の作業用の音声 \(bytes(store.reclaimableBytes)) を削除する")
                        Spacer()
                        Button("変更…") { store.chooseStorageFolder() }.disabled(store.recording || store.busy)
                    }
                } header: {
                    Text("保存先")
                } footer: {
                    Text(
                        "会議ごとにフォルダを作り、録音（録音.m4a）と議事録（議事録.md）をまとめて保存します。議事録.md はアプリが書き直すので、手を加えるときは別名で保存してください。作業用の音声は文字起こしのために区切った音声で、削除すると全文の再処理は録音.m4a から行います（Mac音声とマイクは区別されません）。保存先を変えると、これまでの会議も移動します。"
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
        .frame(width: 560, height: 760)
        .onAppear {
            draft.load(from: store)
            store.refreshStorageUsage()
        }
    }
}

// The vocabulary the transcription should follow. Saved as it is typed, like the other tabs' settings.
struct TranscriptionSettings: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            if let problem = store.vocabularyProblem {
                Section {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                TextEditor(text: $store.vocabulary)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200)
                    .overlay(alignment: .topLeading) {
                        if store.vocabulary.isEmpty {
                            Text("例：\nギジログ\n山田 花子\nOKR")
                                .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("用語集")
            } footer: {
                Text(
                    "会議によく出る人名・社名・製品名・略語を、1行に1つ（または読点で区切って）入力してください。文字起こしでこの表記が使われやすくなります。会議名とアジェンダの議題、直前の発言も、文字起こしのヒントとして一緒に送ります。用語集は、覚えた聞き間違いと一緒に保存先の「vocabulary.json」に保存するので、保存先を iCloud Drive などで同期していれば、ほかの Mac とも共有されます。"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                TextEditor(text: $store.learnedWords)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .overlay(alignment: .topLeading) {
                        if store.learnedWords.isEmpty {
                            Text("まだありません。文字起こしや議事録で語句を直すと、ここに覚えていきます。")
                                .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("覚えた聞き間違い")
            } footer: {
                Text(
                    "語句を直すと「森バス、もりばす → モリバス」のように覚え、これからの会議では同じ聞き間違いを自動で直し、正しい語を文字起こしのヒントにも使います。会議の「語句をまとめて直す…」で、その会議の自動の直しだけを取り消せます。ここで行を消すと、覚えるのをやめます。担当者になった人の名前も、文字起こしのヒントに使います。"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
    }
}

@MainActor final class TagManagement: ObservableObject {
    @Published var renaming: String?
    @Published var newName = ""
    @Published var deleting: (name: String, count: Int)?
}
// Every tag with its meetings: rename (or merge into another tag) and delete, applied to all meetings at once.
struct TagSettings: View {
    @EnvironmentObject var store: Store
    @StateObject private var manage = TagManagement()
    var body: some View {
        let tags = store.allTags
        Form {
            Section {
                if tags.isEmpty {
                    Text("タグはまだありません。議事録のタイトルの下にある「タグを追加」から付けられます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(tags, id: \.name) { tag in
                    HStack(spacing: 12) {
                        Label(tag.name, systemImage: "tag").lineLimit(1)
                        Spacer()
                        Text("\(tag.count)件").monospacedDigit().foregroundStyle(.secondary)
                        Button("名前を変更…") {
                            manage.newName = tag.name
                            manage.renaming = tag.name
                        }
                        Button(role: .destructive) {
                            manage.deleting = tag
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("このタグを削除")
                        .accessibilityLabel("「\(tag.name)」を削除")
                    }
                }
            } header: {
                Text("タグ")
            } footer: {
                Text("名前を変えると、そのタグが付いたすべての会議で変わります。ほかのタグと同じ名前にすると、ひとつにまとまります。タグを削除しても会議は消えません。")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .alert(
            "タグの名前を変更",
            isPresented: Binding(get: { manage.renaming != nil }, set: { if !$0 { manage.renaming = nil } }),
            presenting: manage.renaming
        ) { tag in
            TextField("新しい名前", text: $manage.newName)
            Button("変更") { store.renameTag(tag, to: manage.newName) }
                .disabled(MeetingTags.parse(manage.newName).count != 1)
            Button("キャンセル", role: .cancel) {}
        } message: { tag in
            Text("「\(tag)」が付いたすべての会議で名前が変わります。カンマ（、）は使えません。")
        }
        .confirmationDialog(
            "タグを削除しますか？",
            isPresented: Binding(get: { manage.deleting != nil }, set: { if !$0 { manage.deleting = nil } }),
            presenting: manage.deleting
        ) { tag in
            Button("「\(tag.name)」を削除", role: .destructive) { store.deleteTag(tag.name) }
            Button("キャンセル", role: .cancel) {}
        } message: { tag in
            Text("\(tag.count)件の会議から「\(tag.name)」を外します。会議は削除されません。")
        }
    }
}

// MARK: - Agenda

// The agenda on the minutes sheet: editable while the meeting is prepared or being recorded, a record of how
// long each topic took afterwards. A meeting without an agenda shows none of this.
struct AgendaSection: View {
    @EnvironmentObject var store: Store
    @StateObject private var draft = TextDraft()
    @FocusState private var adding: Bool
    let meeting: Meeting
    var compact = false
    var body: some View {
        let live = meeting.id == store.activeID
        let editable = meeting.capture == .planned || live
        let planned = meeting.agenda.compactMap(\.minutes).reduce(0, +)
        let folded = !compact && store.foldedSections.contains("アジェンダ")
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(
                title: "アジェンダ", tone: .agenda, count: meeting.agenda.count, compact: compact, folds: !compact
            ) {
                if planned > 0 { Text("予定 計\(planned)分").font(.caption).foregroundStyle(.secondary) }
            }
            SectionRule(tone: .agenda).padding(.top, 8).padding(.bottom, folded ? 0 : 4)
            if !folded { rows(live: live, editable: editable) }
        }
    }
    @ViewBuilder private func rows(live: Bool, editable: Bool) -> some View {
        if live && !meeting.agenda.isEmpty {
            Label("話している議題は、文字起こしから AI が判断します（約30秒ごと）", systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6).padding(.horizontal, 8)
        }
        ForEach(Array(meeting.agenda.enumerated()), id: \.element.id) { index, item in
            AgendaRow(
                meeting: meeting, item: item, number: index + 1, editable: editable, live: live,
                last: index == meeting.agenda.count - 1, compact: compact)
            Rectangle().fill(Palette.rule.opacity(0.5)).frame(height: 0.5)
        }
        if editable && store.addingAgenda == meeting.id {
            // Return adds the topic; pasting several lines (an invite, a chat message) adds one per line.
            TextField("議題を入力して Enter（複数行の貼り付けもできます）", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: compact ? 13 : 14))
                .lineLimit(1...4)
                .focused($adding)
                .padding(.vertical, compact ? 8 : 10).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.asagi.opacity(0.1)))
                .padding(.top, 4)
                .onSubmit(add)
                .onChange(of: draft.text) { if draft.text.contains(where: \.isNewline) { add() } }
                .onAppear { adding = true }
                .onChange(of: adding) {
                    if !adding && draft.text.isEmpty && store.addingAgenda == meeting.id {
                        store.addingAgenda = nil
                    }
                }
        } else if editable {
            // Not a field until asked for, so typing during the meeting cannot land here by accident.
            Button {
                store.addingAgenda = meeting.id
            } label: {
                Label("議題を追加", systemImage: "plus").font(.system(size: compact ? 12.5 : 13, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Palette.asagi)
            .padding(.vertical, compact ? 8 : 10).padding(.horizontal, 8)
        } else if meeting.agenda.isEmpty {
            Text("まだありません").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
        }
    }
    private func add() {
        store.addAgenda(draft.text, to: meeting.id)
        draft.text = ""
    }
}
// A topic shows as text; clicking it (while the agenda can still change) opens it for editing, so a keystroke
// during the meeting never lands in a topic by accident.
struct AgendaRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.searchTerms) private var terms
    @FocusState private var field: Field?
    enum Field { case title, goal, minutes }
    let meeting: Meeting
    let item: AgendaItem
    let number: Int
    let editable: Bool
    let live: Bool
    let last: Bool
    var compact = false
    var body: some View {
        let editing = editable && store.editingAgendaItem == item.id
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField("議題", text: title)
                        .textFieldStyle(.plain).font(.system(size: compact ? 13 : 14.5, weight: .semibold))
                        .focused($field, equals: .title)
                        .onSubmit { field = .goal }
                    TextField("決めたいこと（任意）", text: goal)
                        .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .focused($field, equals: .goal)
                        .onSubmit { store.editingAgendaItem = nil }
                } else {
                    Text(highlighted(item.title.isEmpty ? "（無題）" : item.title, terms))
                        .font(.system(size: compact ? 13 : 14.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let goal = item.goal {
                        Text(highlighted("決めたいこと：" + goal, terms)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                AgendaTiming(meeting: meeting, item: item, live: live)
            }
            Spacer(minLength: 4)
            if editing {
                HStack(spacing: 2) {
                    TextField("–", text: minutes).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .frame(width: 26)
                        .focused($field, equals: .minutes)
                        .onSubmit { store.editingAgendaItem = nil }
                    Text("分").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .help("予定時間（分）")
            } else if let minutes = item.minutes {
                Text("予定\(minutes)分").font(.caption).foregroundStyle(.secondary)
            }
            if editable {
                Menu {
                    Button("編集", systemImage: "pencil") { store.editingAgendaItem = item.id }
                    Button("上へ", systemImage: "arrow.up") { store.moveAgendaItem(item.id, in: meeting.id, by: -1) }
                        .disabled(number == 1)
                    Button("下へ", systemImage: "arrow.down") { store.moveAgendaItem(item.id, in: meeting.id, by: 1) }
                        .disabled(last)
                    Divider()
                    Button("削除", systemImage: "trash", role: .destructive) {
                        store.removeAgendaItem(item.id, from: meeting.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("編集・並べ替え・削除")
                .accessibilityLabel("議題の操作")
            }
        }
        .padding(.vertical, compact ? 6 : 9).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(background(editing: editing)))
        .contentShape(Rectangle())
        .textSelection(.disabled)
        .onTapGesture { if editable && !editing { store.editingAgendaItem = item.id } }
        .onChange(of: editing, initial: true) { if editing { field = .title } }
        .onChange(of: field) {
            // Clicking away ends editing; moving between this topic's fields does not.
            if field == nil && store.editingAgendaItem == item.id { store.editingAgendaItem = nil }
        }
        .help(editable && !editing ? "クリックして編集" : "")
    }
    private func background(editing: Bool) -> Color {
        if editing { return Palette.asagi.opacity(0.1) }
        return item.progress == .current && live ? Palette.beni.opacity(0.07) : .clear
    }
    @ViewBuilder private var marker: some View {
        switch item.progress {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.asagi)
        case .current where live: Image(systemName: "play.circle.fill").foregroundStyle(Palette.beni)
        case .current: Image(systemName: "circle.lefthalf.filled").foregroundStyle(Palette.yamabuki)
        case .pending: Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private var title: Binding<String> {
        Binding(
            get: { item.title },
            set: { value in store.updateAgendaItem(item.id, in: meeting.id) { $0.title = value } })
    }
    private var goal: Binding<String> {
        Binding(
            get: { item.goal ?? "" },
            set: { value in store.updateAgendaItem(item.id, in: meeting.id) { $0.goal = value.isEmpty ? nil : value } })
    }
    private var minutes: Binding<String> {
        Binding(
            get: { item.minutes.map(String.init) ?? "" },
            set: { value in
                let digits = (value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value).filter(
                    \.isNumber)
                store.updateAgendaItem(item.id, in: meeting.id) { $0.minutes = Int(digits.prefix(3)) }
            })
    }
}
// How long a topic took, or has taken so far: past its planned time it turns to the attention color.
struct AgendaTiming: View {
    let meeting: Meeting
    let item: AgendaItem
    let live: Bool
    var body: some View {
        if item.progress == .done {
            let spent = item.spent(now: 0)
            label("実際 " + MeetingAgenda.duration(spent), over: over(spent))
        } else if item.progress == .current, live {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let spent = item.spent(now: context.date.timeIntervalSince(meeting.recordingOrigin))
                label("進行中 " + clock(spent) + (item.minutes.map { " / \($0)分" } ?? ""), over: over(spent))
            }
        } else if item.progress == .current {
            label("途中で録音が止まりました", over: false)
        }
    }
    private func over(_ spent: Double) -> Bool { item.minutes.map { spent > Double($0) * 60 } ?? false }
    private func label(_ text: String, over: Bool) -> some View {
        Text(text).font(.caption.monospacedDigit()).foregroundStyle(over ? Palette.yamabuki : Color.secondary)
    }
}
// The compact window's line for the topic under way: number, title, and time so far against plan. The minutes
// model follows the discussion, so nobody has to switch topics during the meeting.
struct AgendaBanner: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var body: some View {
        let agenda = meeting.agenda
        let live = meeting.id == store.activeID
        let current = MeetingAgenda.currentIndex(agenda)
        HStack(spacing: 10) {
            if live, let current {
                let item = agenda[current]
                Text("\(current + 1)/\(agenda.count)")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.kon)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Palette.asagi))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    AgendaTiming(meeting: meeting, item: item, live: true)
                }
            } else {
                Image(systemName: "list.bullet").foregroundStyle(Palette.asagi)
                let planned = agenda.compactMap(\.minutes).reduce(0, +)
                Text(
                    live
                        ? "議題の話が始まると、ここに表示します"
                        : "アジェンダ \(agenda.count)件" + (planned > 0 ? "・予定 計\(planned)分" : "")
                )
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.paper)
        .padding(.horizontal, 14).padding(.bottom, 10)
        .background(Palette.kon)
        .help("話している議題は、文字起こしから AI が判断します（約30秒ごと）")
    }
}

@MainActor final class MCPSetupResult: ObservableObject {
    @Published var shown: (title: String, message: String)?
    @Published var adding = false
}
// AI apps on this Mac read meetings through MCP: what they may see, how to register them, and what they read.
struct MCPSettings: View {
    @EnvironmentObject var store: Store
    @StateObject private var result = MCPSetupResult()
    var body: some View {
        Form {
            Section {
                Toggle("AI アプリから会議を読めるようにする", isOn: $store.mcpEnabled)
                LabeledContent("状態") {
                    Text(status).foregroundStyle(store.mcpProblem == nil ? Color.secondary : Palette.yamabuki)
                }
            } header: {
                Text("MCP サーバー")
            } footer: {
                Text(
                    "この Mac の AI アプリ（Claude Code、Claude Desktop など）が、MCP でギジログの会議を読み取れます。通信はこの Mac の中だけで、ほかのコンピュータからは接続できません。AI アプリに渡した内容は、そのアプリの提供元に送られます。"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("文字起こしも渡す", isOn: $store.mcpIncludesTranscript)
                ForEach(store.allTags, id: \.name) { tag in
                    Toggle(
                        "「\(tag.name)」の会議を渡さない",
                        isOn: Binding(
                            get: { MeetingTags.contains(store.mcpHiddenTags, tag.name) },
                            set: { _ in store.toggleMCPHiddenTag(tag.name) }))
                }
            } header: {
                Text("渡す内容")
            } footer: {
                Text("文字起こしをオフにすると、議事録とアジェンダだけを渡します。チェックしたタグが付いた会議は、AI アプリからは見えません。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    Button("Claude Code に追加") {
                        result.adding = true
                        Task {
                            result.shown = await MCPSetup.addToClaudeCode()
                            result.adding = false
                        }
                    }
                    .disabled(result.adding)
                    Button("Claude Desktop に追加") { result.shown = MCPSetup.addToClaudeDesktop() }
                    if result.adding { ProgressView().controlSize(.small) }
                }
                LabeledContent("コマンド") {
                    HStack(spacing: 6) {
                        Text(MCPSetup.bridgePath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("コピー") { MCPSetup.copy(MCPSetup.bridgePath) }
                    }
                }
                Button("ほかの AI アプリ用の設定（JSON）をコピー") { MCPSetup.copy(MCPSetup.desktopConfig) }
            } header: {
                Text("AI アプリに登録")
            } footer: {
                Text(
                    "登録は最初の一度だけです。あとは AI アプリが必要なときにギジログにつなぎ、ギジログが起動していなければ起動します。ギジログのアプリを別の場所に移したら、Claude Code では登録し直してください。"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                if store.mcpAccesses.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(store.mcpAccesses.prefix(20)) { access in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(access.tool).font(.callout.monospaced())
                            Spacer()
                            Text(access.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary)
                        }
                        Text(access.client + (access.detail.isEmpty ? "" : "　" + access.detail))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } header: {
                Text("最近のアクセス（このアプリを開いている間）")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .alert(
            result.shown?.title ?? "",
            isPresented: Binding(get: { result.shown != nil }, set: { if !$0 { result.shown = nil } })
        ) {
            Button("OK") { result.shown = nil }
        } message: {
            Text(result.shown?.message ?? "")
        }
    }
    private var status: String {
        if !store.mcpEnabled { return "オフ" }
        if let problem = store.mcpProblem { return problem }
        return store.mcpConnections > 0 ? "接続中（AI アプリ \(store.mcpConnections)件）" : "待ち受け中"
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
                if !meeting.agenda.isEmpty && (meeting.id == store.activeID || meeting.capture == .planned) {
                    AgendaBanner(meeting: meeting)
                }
                LiveTabBar(meeting: meeting)
                if store.liveTab == "アジェンダ" && !meeting.agenda.isEmpty {
                    ScrollView { AgendaSection(meeting: meeting, compact: true).padding(14) }
                        .foregroundStyle(Palette.sumi)
                        .background(Palette.paper)
                        .environment(\.colorScheme, .light)
                } else if store.liveTab == "文字起こし" {
                    // The full transcript, following the newest speech like the full window's panel.
                    TranscriptPanel(meeting: meeting, showsHeader: false)
                } else {
                    LiveMinutes(meeting: meeting)
                    LiveTicker(meeting: meeting, live: store.recording)
                }
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
        .onAppear { store.compactWindowOpen = true }
        .onDisappear { store.compactWindowOpen = false }
        // Only one window shows an alert, so an error does not pull both windows forward.
        .alert(
            "確認が必要です",
            isPresented: Binding(
                get: { store.error != nil && store.compactWindowOpen }, set: { if !$0 { store.error = nil } })
        ) {
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
                            Text(clock(context.date.timeIntervalSince(meeting.recordingOrigin)))
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
                SilenceWarning(compact: true)
            } else {
                HStack(spacing: 8) {
                    if let planned = store.selectedMeeting, planned.capture == .planned {
                        HStack(spacing: 6) {
                            Text("準備中").font(.caption2.weight(.semibold)).foregroundStyle(Palette.asagi)
                            Text(planned.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.asagi.opacity(0.5)))
                    } else {
                        Spacer(minLength: 0)
                    }
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
    let meter: LevelMeter
    var body: some View {
        HStack(spacing: 16) {
            TrackWaveform(
                label: "Mac音声", systemImage: "speaker.wave.2.fill", levels: meter.$system, tint: Palette.paper,
                width: 140, height: 20)
            TrackWaveform(
                label: "マイク", systemImage: "mic.fill", levels: meter.$microphone, tint: Palette.asagi, width: 140,
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
                        Text(
                            meeting.finalReviewPending == true && meeting.capture != .recording
                                ? "議事録全体を確認して仕上げています" : "議事録を更新しています"
                        ).foregroundStyle(Palette.asagi)
                    } else if let finalized = notes.finalizedAt {
                        Text("\(finalized.formatted(date: .omitted, time: .standard)) に全体の確認完了").foregroundStyle(
                            .secondary)
                    } else if let updated = notes.updatedAt {
                        FreshSwatch()
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
                    Notice(
                        text: "議事録の更新に失敗しました。間隔を空けて自動で再試行します。"
                            + (store.pipeline.summaryError(meeting.id).map { "\n" + $0 } ?? ""))
                }
                LiveSection(
                    title: "要約", tone: .summary, items: content.summary.filter { $0.state != .cancelled }, known: known,
                    latest: latest)
                LiveSection(
                    title: "決定事項と理由", tone: .decisions, items: content.decisions.filter { $0.state != .cancelled },
                    known: known, latest: latest, topics: content.summary.filter { $0.state != .cancelled })
                LiveSection(
                    title: "未決事項・次の確認", tone: .unresolved, items: content.unresolved.filter { $0.state == .open },
                    known: known, latest: latest, topics: content.summary.filter { $0.state != .cancelled })
                if !content.history.isEmpty {
                    LiveSection(title: "議論の経緯", tone: .history, items: content.history, known: known, latest: latest)
                }
                LiveSection(
                    title: "アクションアイテム", tone: .actions, items: content.actions.filter { $0.state != .cancelled },
                    known: known, latest: latest, topics: content.summary.filter { $0.state != .cancelled })
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
    @EnvironmentObject var store: Store
    let title: String
    let tone: NoteTone
    let items: [NoteItem]
    let known: [String: Segment]
    let latest: Set<String>
    var topics: [NoteItem] = []  // The summary's topics, for decisions, open issues or actions listed by topic.
    var body: some View {
        let unassigned =
            tone == .actions ? items.filter { $0.state == .open && ($0.owner == nil || $0.due == nil) }.count : 0
        let folded = store.foldedSections.contains(title)
        VStack(alignment: .leading, spacing: 2) {
            SectionHeading(title: title, tone: tone, count: items.count, compact: true) {
                if unassigned > 0 {
                    Text("担当・期限が未定 \(unassigned)件").font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.yamabukiInk)
                }
            }
            SectionRule(tone: tone).padding(.top, 5).padding(.bottom, 2)
            if !folded { rows }
        }
    }
    @ViewBuilder private var rows: some View {
        if items.isEmpty {
            Text("まだありません").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        }
        ForEach(TopicGroup.of(items, topics: topics, known: known)) { group in
            if let heading = group.heading { TopicGroupHeading(heading: heading, compact: true) }
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                NoteRow(
                    item: item, known: known, fresh: !Set(item.evidence).isDisjoint(with: latest), tone: tone,
                    number: index + 1, compact: true)
            }
        }
    }
}
// The most recent utterance, so it is clear the meeting is being heard.
// Switches the compact window between the minutes and the whole transcript. The chosen tab takes the color of
// the page below it (paper for the minutes, ink for the transcript), so it reads as that page's tab.
struct LiveTabBar: View {
    @EnvironmentObject var store: Store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabs
    let meeting: Meeting
    var body: some View {
        let pending = meeting.jobs.filter { $0.state == .pending || $0.state == .running }.count
        HStack(alignment: .bottom, spacing: 2) {
            tab("議事録", systemImage: "doc.text", key: "1", page: Palette.paper, ink: Palette.sumi)
            tab(
                "文字起こし", systemImage: "text.quote", key: "2", count: meeting.segments.count, page: Palette.deepAi,
                ink: Palette.paper, outlined: true)
            if !meeting.agenda.isEmpty {
                tab("アジェンダ", systemImage: "list.bullet", key: "3", page: Palette.paper, ink: Palette.sumi)
            }
            Spacer(minLength: 8)
            if pending > 0 {
                Label("処理待ち \(pending)件", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 9)
            }
        }
        .pageTabBar()
    }
    private func tab(
        _ title: String, systemImage: String, key: KeyEquivalent, count: Int? = nil, page: Color, ink: Color,
        outlined: Bool = false
    ) -> some View {
        let selected = store.liveTab == title
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { store.liveTab = title }
        } label: {
            PageTab(
                title: title, systemImage: systemImage, count: count, selected: selected, page: page, ink: ink,
                outlined: outlined, namespace: tabs
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .help(title + "を表示（⌘" + String(key.character) + "）")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
// A tab that opens into the page below it: when chosen it takes the page's color (paper for the minutes, ink
// for the transcript) and joins it. The dark page is close to the bar's color, so its tab can be outlined.
struct PageTab: View {
    static let edge = Palette.paper.opacity(0.18)
    let title: String
    let systemImage: String
    var count: Int?
    var selected = true
    let page: Color
    let ink: Color
    var outlined = false
    var namespace: Namespace.ID?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).imageScale(.small)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let count {
                Text(shortCount(count))
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? ink.opacity(0.14) : Palette.ai))
            }
        }
        .foregroundStyle(selected ? ink : Palette.paper.opacity(0.55))
        .padding(.horizontal, 14).frame(height: 34)
        .background(alignment: .bottom) {
            if selected {
                let shape = UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9)
                    .fill(page)
                    .overlay { if outlined { TabOutline(radius: 9).stroke(Self.edge, lineWidth: 1) } }
                if let namespace { shape.matchedGeometryEffect(id: "tab", in: namespace) } else { shape }
            }
        }
    }
}
extension View {
    /// The bar tabs stand on: a line along its bottom that a chosen tab covers, so its page opens below.
    func pageTabBar() -> some View {
        padding(.horizontal, 10)
            .background(alignment: .bottom) { Rectangle().fill(PageTab.edge).frame(height: 1) }
            .background(Palette.kon)
    }
}
// A tab's top and sides, open at the bottom where it joins its page.
struct TabOutline: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY + 0.5))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY),
            radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius),
            radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + 0.5))
        return path
    }
}
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

// MARK: - Menu bar

// Start and stop from the menu bar and the app's 録音 menu, even with every window closed.
// Edit > 検索 (⌘F): search lives in the full window's sidebar, so the compact view switches back to it.
struct FindMenuItem: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Button("検索") {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
            store.focusesSearch = true
        }
        .keyboardShortcut("f")
        Button("議事録の中を検索") {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
            store.minutesFind.open = true
            store.minutesFind.focus += 1
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled(store.selectedMeeting?.notes == nil)
        Button("文字起こしの中を検索") {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
            store.showsTranscript = true
            store.transcriptFind.open = true
            store.transcriptFind.focus += 1
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(store.selectedMeeting?.segments.isEmpty != false)
    }
}
struct RecordingMenuItems: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        let views = ViewSwitch(open: openWindow, dismiss: dismissWindow)
        if store.recording {
            Button("録音を停止") { Task { await store.stop() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.busy)
        } else {
            Button("新規録音") {
                NSApp.activate()
                startRecording(store, views: views, .new)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.busy || !store.ready || !store.hasKey)
            if let meeting = store.selectedMeeting, meeting.capture == .planned {
                Button("「\(meeting.title)」を録音") {
                    NSApp.activate()
                    startRecording(store, views: views, .prepared(meeting.id))
                }
                .disabled(store.busy || !store.ready || !store.hasKey)
            }
            if let meeting = store.selectedMeeting, meeting.capture == .stopped || meeting.capture == .interrupted {
                Button("「\(meeting.title)」に続けて録音") {
                    NSApp.activate()
                    startRecording(store, views: views, .continuing(meeting.id))
                }
                .disabled(store.busy || !store.hasKey || !store.canContinueRecording(meeting))
            }
        }
        Button("録音ファイルを読み込む…") {
            NSApp.activate()
            store.chooseRecordingFiles()
        }
        .keyboardShortcut("o")
        .disabled(!store.ready || !store.hasKey)
        Button("アジェンダを準備") {
            NSApp.activate()
            views.full()
            store.planMeeting()
        }
        .keyboardShortcut("n")
        .disabled(!store.ready)
        Divider()
        Button("小画面を表示") {
            NSApp.activate()
            views.compact()
        }
        Button("大きい画面を表示") {
            NSApp.activate()
            views.full()
        }
    }
}
struct MenuBarMenu: View {
    @ObservedObject var store: Store
    var body: some View {
        if store.recording, let meeting = store.activeMeeting {
            Text("録音中 \(clock(Date().timeIntervalSince(meeting.recordingOrigin)))：\(meeting.title)")
        } else if !store.hasKey {
            Text("録音するには、設定で OpenAI の API キーを保存してください")
        }
        RecordingMenuItems(store: store)
        Divider()
        SettingsLink { Text("設定…") }
        Button("ギジログを終了") { NSApp.terminate(nil) }
    }
}
// The menu bar shows a waveform, or the recording mark while recording. (A ticking clock in the menu bar label
// makes SwiftUI's status item re-layout in an endless loop at launch, so the elapsed time lives in the menu.)
struct MenuBarLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        Image(systemName: store.recording ? "record.circle.fill" : "waveform")
            .accessibilityLabel(store.recording ? "ギジログ 録音中" : "ギジログ")
    }
}
