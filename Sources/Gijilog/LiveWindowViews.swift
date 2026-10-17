import AppKit
import Combine
import SwiftUI

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
// The two tracks share the compact window's width, so they grow and shrink with it.
struct LiveMeters: View {
    let meter: LevelMeter
    var body: some View {
        HStack(spacing: 16) {
            TrackWaveform(
                label: "Mac音声", systemImage: "speaker.wave.2.fill", levels: meter.$system, tint: Palette.paper,
                width: nil, height: 20)
            TrackWaveform(
                label: "マイク", systemImage: "mic.fill", levels: meter.$microphone, tint: Palette.asagi, width: nil,
                height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct LiveMinutes: View {
    @EnvironmentObject var store: Store
    let meeting: Meeting
    var body: some View {
        let notes = meeting.notes ?? MinutesState()
        let known = meeting.segments.byID
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
            .modifier(Selectable(enabled: !store.minutesChanging(meeting)))  // As in the full window.
            // Evidence clicked here shows on the transcript's tab.
            .environment(\.revealInTranscript) { [store] id in store.reveal(id, in: meeting.id, compact: true) }
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
            store.forgetCompactReveal()  // Opened by hand, the transcript follows the speech again.
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
