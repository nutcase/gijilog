import AppKit
import Combine
import SwiftUI

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
