import AppKit
import Combine
import SwiftUI

// MARK: - Fixing a word across a meeting

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
