import AppKit
import Combine
import SwiftUI

// MARK: - Minutes items: each item, editing it, and the details under it

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
                            store.moveNoteItem(editing.meetingID, part: editing.part, id: item.id, toTopic: topic.id)
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
    @EnvironmentObject var store: Store
    let item: NoteItem
    let drag: NoteItemDrag?
    @ViewBuilder func body(content: Content) -> some View {
        if let drag {
            // The drag carries the item's text, as a text field it is dropped on takes it; which item it is, the
            // store keeps for a topic it is dropped on.
            content.onDrag {
                store.draggedNoteItem = drag
                return NSItemProvider(object: item.text as NSString)
            } preview: {
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
                        ForEach(evidence) { segment in EvidenceLine(segment: segment) }
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
// One utterance an item of the minutes rests on. Its words can be clicked where the transcript is at hand, to read
// it there with what was said around it.
struct EvidenceLine: View {
    @Environment(\.searchTerms) private var terms
    @Environment(\.revealInTranscript) private var reveal
    @StateObject private var hover = Flag()
    let segment: Segment
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                PlayButton(segment: segment)
                Text("\(clock(segment.time)) \(segment.source)").foregroundStyle(.secondary)
            }
            if let reveal {
                Button {
                    reveal(segment.id)
                } label: {
                    Text(highlighted(segment.text, terms)).underline(hover.on, color: Palette.asagi)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.disabled)  // A selectable text would take the click.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { hover.on = $0 }
                .help("文字起こしでこの発言を見る")
            } else {
                Text(highlighted(segment.text, terms)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)  // Each line from the left edge.
    }
}
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
