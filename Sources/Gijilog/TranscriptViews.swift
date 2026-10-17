import AppKit
import Combine
import SwiftUI

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
        // An answer's link or an item's evidence marks the utterance it points to, in the window it was clicked in,
        // unless the find bar is on a match. Otherwise the compact window keeps following the speech.
        let revealed = store.revealed.flatMap { $0.meetingID == meeting.id && $0.compact == !showsHeader ? $0 : nil }
        let current = find.current(in: found) ?? revealed?.segmentID
        let shownTerms = find.terms.isEmpty ? terms : find.terms
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
                .padding(.top, 10)
                .pageTabBar()
            }
            transcript(
                live: live, matches: matches, found: found, current: current, reveals: revealed?.count ?? 0,
                shownTerms: shownTerms)
        }
        .background(Palette.deepAi)
    }
    @ViewBuilder private func transcript(
        live: Bool, matches: [Segment], found: [String], current: String?, reveals: Int, shownTerms: [String]
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
                // Each time an utterance is asked for, even the same one again after scrolling away.
                .task(id: "\(current ?? "") \(reveals)") {
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
// Questions about every meeting, in words, opened from the top of the list in place of a meeting. The AI reads the
// meetings as it needs and answers here, with links to the meetings and utterances it read; a link opens the
// meeting at that utterance, and the conversation stays for the next visit until the app quits.
struct AskDesk: View {
    @EnvironmentObject var store: Store
    @ObservedObject var stream: AskStream
    @FocusState private var focused: Bool
    private static let width: CGFloat = 760
    private static let examples = ["先週決まったことは？", "終わっていないアクションは？", "最近の会議で多く話した話題は？"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label("ギジログAI", systemImage: "bubble.left.and.text.bubble.right").font(.mincho(20))
                    .foregroundStyle(Palette.paper)
                Spacer()
                if !store.asked.isEmpty {
                    Button("新しい会話") { store.clearAsked() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: Self.width).padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if store.asked.isEmpty { intro }
                        ForEach(store.asked) { AskBubble(message: $0).id($0.id) }
                        if !stream.draft.isEmpty {
                            AskBubble(message: AskMessage(role: .answer, text: stream.draft)).id("draft")
                        }
                        if let progress = stream.progress {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(progress + "…").font(.callout).foregroundStyle(Palette.paper.opacity(0.7))
                                Button("止める") { store.stopAsking() }.buttonStyle(.borderless).font(.callout)
                                Spacer(minLength: 0)
                            }
                            .id("progress")
                        }
                    }
                    .frame(maxWidth: Self.width, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                }
                // A new question or answer is shown from its start.
                .onChange(of: store.asked.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .top) }
                }
                // While the AI reads, its progress is kept in view; once it writes, the answer is read from its start.
                .onChange(of: stream.progress) { _, progress in
                    guard let progress else { return }
                    if progress == "答えを書いています" {
                        proxy.scrollTo("draft", anchor: .top)
                    } else {
                        proxy.scrollTo("progress", anchor: .bottom)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                AskScope()
                composer
            }
            .frame(maxWidth: Self.width).padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.kon)
        // A link opens its meeting here; one the AI wrote to elsewhere opens only on the web, as nothing else is cited.
        .environment(
            \.openURL,
            OpenURLAction { url in
                store.openAskLink(url) ? .handled : AskLink.opensOnTheWeb(url) ? .systemAction : .discarded
            }
        )
        .onAppear { Task { @MainActor in focused = true } }
    }
    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("すべての会議の議事録と文字起こしから、AIが探して答えます。答えのリンクを押すと、その会議と発言を開きます。")
                .font(.body).foregroundStyle(Palette.paper.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Self.examples, id: \.self) { example in
                    Button {
                        store.ask(example)
                    } label: {
                        Text(example).font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Palette.ai))
                            .overlay(Capsule().strokeBorder(PageTab.edge))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.paper)
                }
            }
        }
    }
    // The send button sits inside the field, at its right end, on the field's last line.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(store.askScope.isEmpty ? "すべての会議について質問" : "対象の会議について質問", text: $stream.question, axis: .vertical)
                .lineLimit(1...8).textFieldStyle(.plain).font(.body).foregroundStyle(Palette.paper)
                .focused($focused).onSubmit(send)
                .padding(.vertical, 5)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.plain).foregroundStyle(canSend ? Palette.asagi : Palette.paper.opacity(0.25))
            .disabled(!canSend).help("質問する（Return）").accessibilityLabel("質問する")
        }
        .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ai))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Palette.asagi.opacity(0.7) : PageTab.edge))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
    private var canSend: Bool {
        stream.progress == nil && !stream.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func send() {
        guard canSend else { return }
        store.ask(stream.question)
        stream.question = ""
    }
}
// Which meetings the AI reads, over the question field: every meeting, or those with any of the chosen tags. The
// chosen tags show as chips, each with an × to drop it.
struct AskScope: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let scope = store.askScope
        HStack(spacing: 8) {
            Menu {
                ForEach(store.allTags, id: \.name) { tag in
                    Toggle(
                        "\(tag.name)（\(tag.count)）",
                        isOn: Binding(
                            get: { MeetingTags.contains(scope, tag.name) }, set: { _ in store.toggleAskTag(tag.name) }))
                }
                if !scope.isEmpty {
                    Divider()
                    Button("すべての会議") { store.askTags = [] }
                }
            } label: {
                Label(scope.isEmpty ? "対象：すべての会議" : "対象：", systemImage: "tag")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(store.allTags.isEmpty)
            .help(store.allTags.isEmpty ? "会議にタグを付けると、タグで対象を絞れます" : "選んだタグのどれかが付いた会議だけから答える")
            ForEach(scope, id: \.self) { tag in
                Button {
                    store.toggleAskTag(tag)
                } label: {
                    HStack(spacing: 4) {
                        Text(tag).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(FilterChipStyle(on: true))
                .help("「\(tag)」を対象から外す")
            }
            if !scope.isEmpty {
                Text("の会議（\(store.askScopeCount)件）").font(.callout).foregroundStyle(Palette.paper.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(Palette.paper.opacity(0.75))
    }
}
// One turn of the conversation: a question on the right, an answer as text with links, a failure in yellow.
struct AskBubble: View {
    let message: AskMessage
    var body: some View {
        switch message.role {
        case .question:
            HStack {
                Spacer(minLength: 120)
                Text(message.text).font(.body).foregroundStyle(Palette.paper)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ai))
                    .textSelection(.enabled)
            }
        case .answer:
            Text(Self.linked(message.text)).font(.system(size: 14)).lineSpacing(4).foregroundStyle(Palette.paper)
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
