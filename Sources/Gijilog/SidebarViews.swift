import AppKit
import Combine
import SwiftUI

// MARK: - Sidebar

struct MeetingList: View {
    @EnvironmentObject var store: Store
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @StateObject private var searchAsked = Flag()  // ⌥⌘F asked for the search field since the list appeared.
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
        .onChange(of: store.focusesSearch, initial: true) {
            guard store.focusesSearch else { return }
            searchAsked.on = true
            store.focusesSearch = false
            // A window that ⌥⌘F just opened needs a moment before its search field can take focus.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                searchFocused = true
            }
        }
        // macOS hands a new window's first text field the keyboard; the search waits to be clicked or asked for with ⌥⌘F.
        .task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !searchAsked.on && store.searchText.isEmpty { searchFocused = false }
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
                // Two kinds of things sit above the meetings: ギジログAI, a page of its own like a meeting, and the
                // tools for the meetings, under their heading.
                Button {
                    store.openAsk()
                } label: {
                    Label("ギジログAI", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(QuietButtonStyle(selected: store.askOpen))
                .help("すべての会議について、AIに質問する。答えのリンクから、その会議と発言を開ける")
                Rectangle().fill(PageTab.edge).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    MeetingsHeading()
                    SidebarSearchField(text: $store.searchText, focused: $searchFocused)
                    if !store.tagFilter.isEmpty { ChosenTags() }
                }
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                // A vocabulary file that cannot be read stops the lists being saved: that stays in view until fixed.
                if let problem = store.vocabularyProblem {
                    Button {
                        store.settingsTab = "文字起こし"
                        openSettings()
                    } label: {
                        Label("用語集のファイルを読み込めません", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.yamabuki)
                    }
                    .buttonStyle(.plain).help(problem.message)
                }
                HStack {
                    SettingsLink { Label("設定", systemImage: "gearshape") }.buttonStyle(.plain).foregroundStyle(
                        .secondary)
                    Spacer()
                }
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
// The heading over the meetings, with their tools: narrowing them by tag, and preparing a new one's agenda.
struct MeetingsHeading: View {
    @EnvironmentObject var store: Store
    @StateObject private var tagsOpen = Flag()
    var body: some View {
        HStack(spacing: 12) {
            Text("会議").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.paper.opacity(0.6))
            Spacer()
            if !store.allTags.isEmpty {
                let narrowed = !store.tagFilter.isEmpty
                Button {
                    tagsOpen.on.toggle()
                } label: {
                    Image(
                        systemName: narrowed
                            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                    )
                    .foregroundStyle(narrowed ? Palette.asagi : Palette.paper.opacity(0.7))
                }
                .help("タグで絞り込む").accessibilityLabel("タグで絞り込む")
                .popover(isPresented: $tagsOpen.on, arrowEdge: .bottom) {
                    TagFilterBar().padding(14).frame(width: 300, alignment: .leading)
                        .foregroundStyle(Color.primary).environment(\.colorScheme, .dark)
                }
            }
            Button {
                store.planMeeting()
            } label: {
                Image(systemName: "plus").foregroundStyle(Palette.paper.opacity(0.7))
            }
            .disabled(!store.ready)
            .help("アジェンダを準備：録音の前に会議を作って、議題を用意しておく（⌘N）。会議が始まったら、その会議のページで録音します")
            .accessibilityLabel("アジェンダを準備")
        }
        .buttonStyle(.plain).font(.system(size: 15))
        .padding(.leading, 6)
    }
}
// The tags the list is narrowed by, under the search: each one's × stops narrowing by it.
struct ChosenTags: View {
    @EnvironmentObject var store: Store
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(store.tagFilter, id: \.self) { tag in
                Button {
                    store.toggleTagFilter(tag)
                } label: {
                    HStack(spacing: 4) {
                        Text(tag).lineLimit(1)
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(FilterChipStyle(on: true))
                .help("「\(tag)」での絞り込みをやめる")
            }
        }
    }
}
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
        .disabled(!store.owns(meeting))  // Another Mac's meeting is only read here.
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
