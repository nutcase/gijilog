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
let longDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.dateFormat = "y年M月d日（E）H:mm"
    return formatter
}()
let dayTitle: DateFormatter = {
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
// Shows an utterance of the meeting in the transcript, for the minutes' evidence: set where the transcript is at hand.
private struct RevealInTranscriptKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}
extension EnvironmentValues {
    var searchTerms: [String] {
        get { self[SearchTermsKey.self] }
        set { self[SearchTermsKey.self] = newValue }
    }
    var playableMeeting: UUID? {
        get { self[PlayableMeetingKey.self] }
        set { self[PlayableMeetingKey.self] = newValue }
    }
    var revealInTranscript: (@MainActor (String) -> Void)? {
        get { self[RevealInTranscriptKey.self] }
        set { self[RevealInTranscriptKey.self] = newValue }
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
                        if store.askOpen {
                            AskDesk(stream: store.askStream)
                        } else if let meeting = store.selectedMeeting {
                            MinutesDesk(meeting: meeting)
                        } else {
                            EmptyDesk()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.showsTranscript, let meeting = store.selectedMeeting {
                        Rectangle().fill(Palette.ai).frame(width: 1)
                        TranscriptPanel(meeting: meeting, editable: store.canEditTranscript(meeting)).frame(width: 320)
                    }
                }
                .environment(\.searchTerms, store.searchedTerms)
                .environment(
                    \.playableMeeting, store.selectedMeeting.flatMap { store.recordingFile($0) != nil ? $0.id : nil }
                )
                .environment(\.revealInTranscript, store.selectedMeeting.map { meeting in reveal(in: meeting.id) })
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
    /// An item's evidence clicked in the minutes shows in the transcript panel beside them.
    private func reveal(in meetingID: UUID) -> @MainActor (String) -> Void {
        { [store] segmentID in store.reveal(segmentID, in: meetingID) }
    }
}
