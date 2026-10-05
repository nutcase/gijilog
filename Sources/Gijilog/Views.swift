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
extension EnvironmentValues {
    var searchTerms: [String] {
        get { self[SearchTermsKey.self] }
        set { self[SearchTermsKey.self] = newValue }
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
// Starting a recording from anywhere (window, menu, menu bar) switches to the compact view beside the call.
@MainActor func startRecording(_ store: Store, views: ViewSwitch) {
    Task {
        await store.start()
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
                .environment(\.searchTerms, store.searchedTerms)
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
            Button {
                store.chooseRecordingFiles()
            } label: {
                Label("読み込み", systemImage: "square.and.arrow.down")
            }
            .help("録音ファイル（音声・動画）を読み込んで議事録を作る。ウインドウにドロップしても読み込めます")
            .disabled(!store.ready || !store.hasKey)
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
                    Button("議事録を仕上げる", systemImage: "text.badge.checkmark") {
                        Task { await store.refineMinutes(meeting.id) }
                    }.disabled(!idle || !store.hasKey || meeting.segments.isEmpty)
                    Button("未処理を再開", systemImage: "arrow.clockwise") { Task { await store.process() } }
                        .disabled(!idle || !store.hasKey || meeting.capture == .planned)
                    Button("全文を再処理", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await store.process(rebuild: true) }
                    }.disabled(!idle || !store.hasKey || meeting.capture == .planned)
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        Group {
            if store.recording, let meeting = store.activeMeeting { live(meeting) } else { idle }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var idle: some View {
        let planned = store.selectedMeeting.flatMap { $0.capture == .planned ? $0 : nil }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let planned {
                    HStack(spacing: 10) {
                        Text("準備中").font(.caption.weight(.semibold)).foregroundStyle(Palette.asagi)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.asagi.opacity(0.16)))
                        Text(planned.title).font(.system(size: 16)).lineLimit(1)
                        if !planned.agenda.isEmpty {
                            Text("議題 \(planned.agenda.count)件").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.asagi.opacity(0.5)))
                    Button("新しい会議にする") { store.selected = nil }
                        .buttonStyle(QuietButtonStyle())
                        .help("準備した会議ではなく、新しい会議として録音する")
                } else {
                    // For the next recording, not the meeting shown below, which is renamed by clicking its title.
                    TextField("次に録音する会議のタイトル（空欄なら日時）", text: $store.title)
                        .textFieldStyle(.plain).font(.system(size: 16))
                        .padding(.horizontal, 14).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.ai))
                        .disabled(store.busy)
                        .onSubmit(start)
                    Button {
                        store.planMeeting()
                    } label: {
                        Label("アジェンダを準備", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
                    .disabled(!store.ready)
                    .help("録音の前に議題を用意しておく。会議の時間になったら、この会議を選んで録音を開始します")
                }
                Button(action: start) { Label("録音を開始", systemImage: "record.circle") }
                    .buttonStyle(CapsuleButtonStyle(filled: true))
                    .fixedSize()
                    .disabled(store.busy || !store.ready || !store.hasKey)
                if store.busy || store.importing { ProgressView().controlSize(.small) }
            }
            if store.hasKey {
                Text(
                    planned != nil
                        ? "「録音を開始」で、準備した会議の録音を始めます。アジェンダは最初の議題から進行を記録します。"
                        : "Macの音声とマイクを録音し、OpenAIで文字起こしと議事録づくりをします。録音ファイルはドロップしても読み込めます。API利用料がかかります。"
                )
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
    private func start() { startRecording(store, views: ViewSwitch(open: openWindow, dismiss: dismissWindow)) }
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
    @Environment(\.searchTerms) private var terms
    let meeting: Meeting
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                notices
                if meeting.capture == .planned || !meeting.agenda.isEmpty {
                    AgendaSection(meeting: meeting).padding(.top, 26)
                }
                if meeting.capture == .planned {
                    Text("会議の時間になったら、この会議を選んだまま「録音を開始」を押してください。議事録はここに書き足されていきます。")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 24)
                } else if let notes = meeting.notes {
                    MinutesSections(notes: notes, segments: meeting.segments)
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
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
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
            }
            .font(.callout)
            tags
            updateState.font(.caption)
            Rectangle().fill(Palette.sumi).frame(height: 1.5).padding(.top, 6)
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
                    .onExitCommand {
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
                focused = true
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
            NoteSection(
                title: "要約", items: content.summary.filter { $0.state != .cancelled }, known: known, latest: latest)
            NoteSection(
                title: "決定事項と理由", items: content.decisions.filter { $0.state != .cancelled }, known: known,
                latest: latest)
            NoteSection(
                title: "未決事項・次の確認", items: content.unresolved.filter { $0.state == .open }, known: known, latest: latest
            )
            if !content.history.isEmpty {
                NoteSection(title: "議論の経緯", items: content.history, known: known, latest: latest)
            }
            NoteSection(
                title: "アクションアイテム", items: content.actions.filter { $0.state != .cancelled }, known: known,
                latest: latest, actions: true)
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
    @Environment(\.searchTerms) private var terms
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
                Text(highlighted(item.text, terms)).font(.system(size: compact ? 13 : 14.5)).lineSpacing(
                    compact ? 2 : 4
                )
                .strikethrough(item.state == .cancelled)
                .foregroundStyle(item.state == .cancelled ? Color.secondary : Palette.sumi)
                .fixedSize(horizontal: false, vertical: true)
                if let reason = item.reason {
                    Text(highlighted("理由：" + reason, terms)).font(.caption).foregroundStyle(.secondary)
                }
                if let next = item.nextStep {
                    Text(highlighted("次の確認：" + next, terms)).font(.caption).foregroundStyle(Palette.yamabuki)
                }
                if let change = item.changeSummary {
                    Text(highlighted("経緯：" + change, terms)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if action {
                        Tag(label: "担当", value: item.owner, open: item.state == .open)
                        Tag(label: "期限", value: item.due, open: item.state == .open)
                    } else if item.state != .open {
                        Text(item.state == .done ? "解決済み" : "撤回・統合").foregroundStyle(Palette.asagi)
                    }
                }
                .font(.caption)
                if let first = evidence.first {
                    DisclosureGroup {
                        ForEach(evidence) { segment in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(clock(segment.time)) \(segment.source)").foregroundStyle(.secondary)
                                Text(highlighted(segment.text, terms)).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 3)
                        }
                    } label: {
                        Text("根拠 \(clock(first.time))〜（\(evidence.count)件）").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
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
    @Environment(\.searchTerms) private var terms
    @StateObject private var follow = TranscriptFollow()
    let meeting: Meeting
    var showsHeader = true  // The compact window shows the count in its tab bar instead.
    var body: some View {
        let live = meeting.id == store.activeID
        let matches =
            terms.isEmpty
            ? []
            : meeting.segments.filter { segment in
                terms.contains { segment.text.range(of: $0, options: MeetingSearch.options) != nil }
            }
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                // The same tab as the compact window's, so the panel reads as the transcript's page.
                HStack(alignment: .bottom, spacing: 8) {
                    PageTab(
                        title: "文字起こし", systemImage: "text.quote", count: meeting.segments.count,
                        page: Palette.deepAi, ink: Palette.paper, outlined: true)
                    Spacer(minLength: 0)
                    let pending = meeting.jobs.filter { $0.state == .pending || $0.state == .running }.count
                    HStack(spacing: 8) {
                        if !terms.isEmpty {
                            Text("一致 \(matches.count)件").font(.caption.weight(.semibold)).foregroundStyle(
                                Palette.yamabuki)
                        }
                        if pending > 0 {
                            Label("処理待ち \(pending)件", systemImage: "hourglass").font(.caption).foregroundStyle(
                                .secondary)
                        }
                    }
                    .padding(.bottom, 9)
                }
                .padding(.top, 10)
                .pageTabBar()
            }
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
                        if live && follow.atEnd && terms.isEmpty { scrollToEnd(proxy) }
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
    @Environment(\.searchTerms) private var terms
    let segment: Segment
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: sourceSymbol(segment.source))
                Text(clock(segment.time)).monospacedDigit()
                Text(segment.source)
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(highlighted(segment.text, terms)).font(.system(size: 13.5)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
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
            Section {
                TextEditor(text: $store.vocabulary)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
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
                    "会議によく出る人名・社名・製品名・略語を、1行に1つ（または読点で区切って）入力してください。文字起こしでこの表記が使われやすくなります。会議名とアジェンダの議題、直前の発言も、文字起こしのヒントとして一緒に送ります。"
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("アジェンダ").font(.mincho(compact ? 15 : 17))
                Text("\(meeting.agenda.count)").font(.callout).foregroundStyle(.secondary)
                if planned > 0 { Text("予定 計\(planned)分").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Palette.rule).frame(height: 1).padding(.top, 8).padding(.bottom, 4)
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
                let spent = item.spent(now: context.date.timeIntervalSince(meeting.date))
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
                    if let planned = store.selectedMeeting, planned.capture == .planned {
                        HStack(spacing: 6) {
                            Text("準備中").font(.caption2.weight(.semibold)).foregroundStyle(Palette.asagi)
                            Text(planned.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.asagi.opacity(0.5)))
                    } else {
                        TextField("次に録音する会議のタイトル", text: $store.title)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ai))
                            .onSubmit { Task { await store.start() } }
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
                    Notice(
                        text: "議事録の更新に失敗しました。間隔を空けて自動で再試行します。"
                            + (store.pipeline.summaryError(meeting.id).map { "\n" + $0 } ?? ""))
                }
                LiveSection(
                    title: "要約", items: content.summary.filter { $0.state != .cancelled }, known: known, latest: latest)
                LiveSection(
                    title: "決定事項と理由", items: content.decisions.filter { $0.state != .cancelled }, known: known,
                    latest: latest)
                LiveSection(
                    title: "未決事項・次の確認", items: content.unresolved.filter { $0.state == .open }, known: known,
                    latest: latest)
                if !content.history.isEmpty {
                    LiveSection(title: "議論の経緯", items: content.history, known: known, latest: latest)
                }
                LiveSection(
                    title: "アクションアイテム", items: content.actions.filter { $0.state != .cancelled }, known: known,
                    latest: latest, actions: true)
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
            Button("録音を開始") {
                NSApp.activate()
                startRecording(store, views: views)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.busy || !store.ready || !store.hasKey)
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
            Text("録音中 \(clock(Date().timeIntervalSince(meeting.date)))：\(meeting.title)")
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
