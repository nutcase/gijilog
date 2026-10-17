import AppKit
import Combine
import SwiftUI

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
                let count = TranscriptionHints.terms(store.vocabulary).count
                HStack {
                    Text("用語集")
                    Spacer()
                    Text("\(count) / \(VocabularyFile.termLimit)語").monospacedDigit()
                        .foregroundStyle(count > VocabularyFile.termLimit ? Palette.yamabuki : .secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    let over = TranscriptionHints.terms(store.vocabulary).count - VocabularyFile.termLimit
                    if over > 0 {
                        Label(
                            "\(VocabularyFile.termLimit)語を超えています。後ろの\(over)語は保存せず、文字起こしにも使いません。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(Palette.yamabuki)
                    }
                    Text(
                        "会議によく出る人名・社名・製品名・略語を、1行に1つ（または読点で区切って）、\(VocabularyFile.termLimit)語まで入力できます。文字起こしでこの表記が使われやすくなります。会議名とアジェンダの議題、直前の発言も、文字起こしのヒントとして一緒に送ります。用語集は、覚えた聞き間違いと一緒に保存先の「vocabulary.json」に保存するので、保存先を iCloud Drive などで同期していれば、ほかの Mac とも共有されます。"
                    )
                }
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
                HStack {
                    Text("覚えた聞き間違い")
                    Spacer()
                    Text("\(LearnedWords.parse(store.learnedWords).count) / \(LearnedWords.limit)件").monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(
                    "語句を直すと「森バス、もりばす → モリバス」のように覚え、これからの会議では同じ聞き間違いを自動で直し、正しい語を文字起こしのヒントにも使います。会議の「語句をまとめて直す…」で、その会議の自動の直しだけを取り消せます。ここで行を消すと、覚えるのをやめます。覚えるのは\(LearnedWords.limit)件までで、超えると、いちばん長く直していないものから忘れます。担当者になった人の名前も、文字起こしのヒントに使います。"
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
