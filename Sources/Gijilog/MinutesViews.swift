import AppKit
import Combine
import SwiftUI

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
            // Selectable text is drawn by AppKit, and while the minutes keep changing (recording, processing) it
            // came out upside down in places as rows redrew; it can be selected again once they settle, when the
            // switch also draws it afresh.
            .modifier(Selectable(enabled: !store.minutesChanging(meeting)))
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
                    .help("議事録の中を検索（⌘F）")
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
            let owned = store.owns(meeting)
            ForEach(meeting.tags, id: \.self) { tag in
                TagChip(name: tag, remove: owned ? { store.removeTag(tag, from: meeting.id) } : nil)
            }
            if owned { addTag }
        }
    }
    private var addTag: some View {
        Group {
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
            if let conflict = meeting.conflict, store.owns(meeting) {
                ConflictNotice(meetingID: meeting.id, conflict: conflict)
            }
            if !store.owns(meeting) && !meeting.hasUnfinishedWork {
                // Another Mac's meeting is only read here (Store.owns), until it is taken over.
                Notice(
                    text: (meeting.workingMac == nil
                        ? "この会議は、どの Mac で録音したかの記録がない以前の形式のため、この Mac では見るだけにしています。"
                        : "この会議は\(meeting.savedOn.map { "「\($0)」" } ?? "ほかの Mac ")で録音・処理しているため、この Mac では見るだけです。")
                        + "この Mac で直すときは、引き取ってください（引き取ると、もう一方の Mac では見るだけになります）。",
                    actionTitle: "この Mac で編集する", action: { store.editHere(meeting.id) })
            }
            if !store.owns(meeting) && meeting.hasUnfinishedWork && meeting.id != store.activeID
                && !store.isProcessing(meeting.id)
            {
                // Another Mac's to finish (see Store.recover); it may never come back to it.
                Notice(
                    text: (meeting.workingMac == nil
                        ? "この会議は、どの Mac で録音・処理したかの記録がない以前の形式で、処理が途中のままです。"
                        : meeting.capture == .recording
                            ? "この会議は、ほかの Mac で録音中か、その Mac で録音が途中で止まっています。"
                            : "この会議は、ほかの Mac で処理していて、まだ途中です。その Mac でギジログを開くと続きを処理します。")
                        + "その Mac で続けないときは、この Mac で引き取れます。",
                    actionTitle: store.hasKey ? "この Mac で続ける" : nil,
                    action: { Task { await store.continueHere(meeting.id) } })
            }
            if let message = meeting.captureError { Notice(text: message) }
            if let stopped = meeting.stoppedForSilence, meeting.capture != .recording {
                Notice(
                    text: "音がしばらくなかったため、\(stopped.formatted(date: .omitted, time: .shortened)) に録音を自動で止めました。"
                        + "続きがあるときは「続けて録音」で録音できます。",
                    actionTitle: store.owns(meeting) ? "閉じる" : nil, action: { store.dismissSilenceStop(meeting.id) })
            }
            if let failure = meeting.transcriptionFailure {
                Notice(
                    text: failure, actionTitle: store.hasKey && store.owns(meeting) ? "再試行" : nil,
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
    private var canResume: Bool {
        meeting.id != store.activeID && store.hasKey && !store.isProcessing(meeting.id) && store.owns(meeting)
    }
    private func resume() { Task { await store.process() } }
}
struct TagChip: View {
    let name: String
    let remove: (() -> Void)?  // Nil on a meeting only read here.
    var body: some View {
        HStack(spacing: 5) {
            Text(name).lineLimit(1)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("このタグを外す")
                .accessibilityLabel("「\(name)」を外す")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.trailing, remove == nil ? 2 : 0)
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
                    .onTapGesture { if store.owns(meeting) { store.editingTitle = meeting.id } }
                    .help(store.owns(meeting) ? "クリックしてタイトルを変更" : "")
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
        let known = segments.byID
        let latest = notes.latestSegmentIDs ?? []
        let content = notes.content
        let revised = editable ? notes.itemsCitingRevisedLines : []
        VStack(alignment: .leading, spacing: 30) {
            if !revised.isEmpty, let meetingID {
                RevisionNotice(meetingID: meetingID, count: revised.count, updates: notes.updateTakesInCorrections)
            }
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
// Shown when the meeting was changed on two Macs at once: the version shown is kept, the other aside, and either can
// be put in place of the other until one is let go.
struct ConflictNotice: View {
    @EnvironmentObject var store: Store
    let meetingID: UUID
    let conflict: MeetingConflict
    var body: some View {
        // The version aside may be this Mac's own, when the other Mac's was kept in its place.
        let mac =
            conflict.savedOn == nil
            ? "もう一方の Mac" : conflict.savedOn == Store.computerName ? "この Mac" : "「\(conflict.savedOn ?? "")」"
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Palette.yamabuki)
                Text("この会議は、2台の Mac で同時に直されました。\(mac)で直した版を、別に残しています。")
                    .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            Text("表示している版と見比べて、残す方を選んでください。入れ替えても、もう一方の版は別に残ります。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("\(mac)の版に入れ替える") { Task { await store.swapConflict(meetingID) } }
                Button("表示している版を残す") { Task { await store.dismissConflict(meetingID) } }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.yamabuki.opacity(0.12)))
    }
}
// Shown when transcript lines the minutes cite were corrected or deleted by hand: the minutes can be written again
// from the corrected transcript, or kept as they are. Items edited by hand are kept by an update, so once only they
// are left to check, updating is not offered: it would leave them, and the notice, as they were.
struct RevisionNotice: View {
    @EnvironmentObject var store: Store
    let meetingID: UUID
    let count: Int
    let updates: Bool  // Writing the minutes again would change some of the marked items.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.yamabuki)
                Text(
                    updates
                        ? "文字起こしで直した発言をもとにした項目が\(count)件あります（「要確認」の印）。"
                        : "手で直した項目のうち\(count)件は、もとにした発言を文字起こしで直しています（「要確認」の印）。"
                )
                .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            Text(
                updates
                    ? "直した文字起こしから議事録を作り直すと反映されます。手で直した項目はそのまま残ります。"
                    : "手で直した項目は、議事録を更新しても書き換わりません。今も合っているか確かめてください。"
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if updates {
                    Button("訂正を反映して更新") { Task { await store.refineMinutes(meetingID) } }
                        .disabled(!store.hasKey)
                    Button("このままにする") { store.keepMinutesDespiteRevisions(meetingID) }
                } else {
                    Button("確認済みにする") { store.keepMinutesDespiteRevisions(meetingID) }
                }
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
    var topic: String? = nil  // The summary topic's ID, for a run under one.
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
                topic: topics[index].id)
        }
    }
}
/// The topic a dragged item is over, by its ID, outlined in its section.
@MainActor final class TopicDropHighlight: ObservableObject {
    @Published var topic: String?
}
// A topic's heading and items take a decision, open issue or action dragged from another topic of the same section,
// and move it there. Only where the minutes can be edited.
struct TopicDrop: ViewModifier {
    @EnvironmentObject var store: Store
    let editing: NoteEditing?
    let topic: String?
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
                .dropDestination(for: String.self) { texts, _ in
                    store.dropNoteItem(texts, on: topic, in: editing.meetingID, part: editing.part)
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
