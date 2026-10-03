import AppKit
import SwiftUI

@main struct MinutesApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("キロクル") {
            ContentView().environmentObject(store).frame(minWidth: 940, minHeight: 640)
                .onAppear { delegate.store = store }
        }
        Settings { SettingsView().environmentObject(store) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task {
            await store.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
struct ContentView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                Label("キロクル", systemImage: "waveform").font(.largeTitle.bold()).padding(.top, 12)
                Text("音声から、会議の記録へ。").foregroundStyle(.secondary)
                List(selection: $store.selected) {
                    ForEach(store.meetings) { meeting in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meeting.title).font(.headline)
                            Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                .foregroundStyle(.secondary)
                            Text(meeting.status).font(.caption).foregroundStyle(.teal)
                        }.padding(.vertical, 6).tag(meeting.id)
                    }
                }.listStyle(.sidebar)
                SettingsLink { Label("設定", systemImage: "gearshape") }.padding(.bottom)
            }.padding(.horizontal, 12).navigationSplitViewColumnWidth(260)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("会議を記録する").font(.title.bold())
                        Text("会議に参加しながら、録音・文字起こし・議事録を更新します。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(store.recording ? .red : .gray.opacity(0.3)).frame(width: 10, height: 10)
                }
                HStack {
                    TextField("会議のタイトル", text: $store.title).textFieldStyle(.roundedBorder).disabled(store.recording)
                    if store.recording {
                        Button("録音を停止", systemImage: "stop.fill") { Task { await store.stop() } }.tint(.red)
                    } else {
                        Button("録音を開始", systemImage: "record.circle") { Task { await store.start() } }.tint(.teal)
                    }
                }.buttonStyle(.borderedProminent).disabled(store.busy || !store.ready)
                HStack {
                    Picker("処理方式", selection: $store.processingMode) {
                        Text("Mac内のみ").tag("local")
                        Text("Mac内認識＋GPT要約").tag("hybrid")
                        Text("クラウドAI").tag("cloud")
                    }.pickerStyle(.segmented).frame(width: 460).disabled(store.busy || store.recording)
                    Spacer()
                    if store.busy { ProgressView().controlSize(.small) }
                    if store.recording { ProgressView(value: Double(min(store.level, 1))).frame(width: 100) }
                }
                Text(
                    store.cloud
                        ? "クラウド方式で録音を開始すると、録音中から音声・文字起こしをOpenAIへ送信します（API利用料が発生）。"
                        : (store.cloudSummary
                            ? "音声はMac内で文字起こし。録音中から認識済みテキストをOpenAIへ送り、議事録を更新します（API利用料が発生）。"
                            : "音声を外部に送信しません。文字起こしは端末内認識。議事録は設定に応じて発言抽出またはMac内AIです。")
                )
                .font(.caption).foregroundStyle(.secondary)
                Divider()
                if let meeting = store.meetings.first(where: { $0.id == store.selected }) {
                    HStack {
                        Text(meeting.title).font(.title2.bold())
                        Spacer()
                        Button("保存場所", systemImage: "folder") { NSWorkspace.shared.open(store.folder(meeting.id)) }
                        Button("書き出し", systemImage: "square.and.arrow.up") { store.export(meeting) }.disabled(
                            meeting.segments.isEmpty)
                        Button("未処理を再開") { Task { await store.process() } }.buttonStyle(.borderedProminent).disabled(
                            meeting.id == store.activeID || store.busy || store.isProcessing(meeting.id))
                        Menu("再処理") {
                            Button("現在の処理方式で全文を再処理") { Task { await store.process(rebuild: true) } }
                        }.disabled(meeting.id == store.activeID || store.busy || store.isProcessing(meeting.id))
                    }
                    if let message = meeting.captureError { Text(message).font(.caption).foregroundStyle(.orange) }
                    if let failed = meeting.jobs.first(where: { $0.state == .failed }) {
                        Text("\(failed.source)・\(Int(failed.offset))秒の文字起こしに失敗: \(failed.lastError ?? "未処理を再開してください")")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Picker("表示", selection: $store.tab) {
                        Text("議事録").tag("議事録")
                        Text("文字起こし").tag("文字起こし")
                    }.pickerStyle(.segmented).frame(width: 240)
                    HStack {
                        Text(
                            "未処理 \(meeting.jobs.filter { $0.state == .pending || $0.state == .running }.count)件・失敗 \(meeting.jobs.filter { $0.state == .failed }.count)件"
                        ).font(.caption).foregroundStyle(.secondary)
                        if let updated = meeting.notes?.updatedAt {
                            Text("議事録更新 \(updated.formatted(date: .omitted, time: .standard))").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if store.tab == "議事録" {
                                Text(
                                    meeting.minutes.isEmpty
                                        ? "録音中は約12秒ごとに文字起こし、30秒ごとに議事録を更新します。処理時間により遅れます。" : meeting.minutes
                                ).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            } else {
                                Text("新しい録音の時刻は両トラック共通です。クラウドではチャンクの開始位置を表示します。旧録音は各トラック内の経過秒です。").font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(Int(segment.time))秒 · \(segment.source)").font(.caption)
                                            .foregroundStyle(.teal)
                                        Text(segment.text).textSelection(.enabled)
                                    }
                                }
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }.background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ContentUnavailableView(
                        "最初の会議を録音", systemImage: "waveform", description: Text("録音データはMacに保存され、あとから再処理できます。"))
                }
                Spacer(minLength: 0)
                Text(store.status).font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.alert("確認が必要です", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("閉じる") { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Form {
            Picker("録音するマイク", selection: $store.microphone) {
                Text("デフォルトのマイク").tag("")
                ForEach(store.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }.disabled(store.recording)
            SecureField("OpenAI APIキー", text: $store.key)
            TextField("クラウド議事録モデル", text: $store.model)
            TextField("Mac内AIモデル（Ollama・任意）", text: $store.localModel)
            Text("Mac内AIは別途起動済みのOllamaとダウンロード済みモデルが必要です。空欄ならキーワードによる発言抽出を使います。接続先はこのMacのみです。").font(.caption)
                .foregroundStyle(.secondary)
            Text(
                "APIキーはmacOSのKeychainに保存します。Mac内認識＋GPT要約では文字起こしのみをOpenAIへ送信し、クラウドAI方式では音声も送信します。スピーカーの音がマイクに入ると二重録音になるため、会議ではヘッドホンを推奨します。"
            ).font(.caption).foregroundStyle(.secondary)
            Button("設定を保存") { store.saveSettings() }
        }.padding(24).frame(width: 500)
    }
}
