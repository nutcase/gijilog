import AppKit
import Combine
import SwiftUI

// MARK: - Menu bar

// Start and stop from the menu bar and the app's 録音 menu, even with every window closed.
// Edit menu: ⌘F finds in what is open, the meeting's minutes, as in Notes or Mail; ⌥⌘F searches every meeting from
// the sidebar. Both live in the full window, so the compact view switches back to it.
struct FindMenuItem: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        // With no minutes open (ギジログAI, a meeting still being prepared), ⌘F searches the meetings instead.
        let inMinutes = !store.askOpen && store.selectedMeeting?.notes != nil
        Button(inMinutes ? "議事録の中を検索" : "会議を検索") {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
            if inMinutes {
                store.minutesFind.open = true
                store.minutesFind.focus += 1
            } else {
                store.focusesSearch = true
            }
        }
        .keyboardShortcut("f")
        Button("会議を検索") {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
            store.focusesSearch = true
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        Button("文字起こしの中を検索") {
            ViewSwitch(open: openWindow, dismiss: dismissWindow).full()
            store.showsTranscript = true
            store.transcriptFind.open = true
            store.transcriptFind.focus += 1
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(store.selectedMeeting?.segments.isEmpty != false)
    }
}
struct RecordingMenuItems: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    var body: some View {
        let views = ViewSwitch(open: openWindow, dismiss: dismissWindow)
        if store.recording {
            Button("録音を停止") { Task { await store.stop() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.busy)
        } else {
            Button("新規録音") {
                NSApp.activate()
                startRecording(store, views: views, .new)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(store.busy || !store.ready || !store.hasKey)
            if let meeting = store.selectedMeeting, meeting.capture == .planned {
                Button("「\(meeting.title)」を録音") {
                    NSApp.activate()
                    startRecording(store, views: views, .prepared(meeting.id))
                }
                .disabled(store.busy || !store.ready || !store.hasKey)
            }
            if let meeting = store.selectedMeeting, meeting.capture == .stopped || meeting.capture == .interrupted {
                Button("「\(meeting.title)」に続けて録音") {
                    NSApp.activate()
                    startRecording(store, views: views, .continuing(meeting.id))
                }
                .disabled(store.busy || !store.hasKey || !store.canContinueRecording(meeting))
            }
        }
        Button("録音ファイルを読み込む…") {
            NSApp.activate()
            store.chooseRecordingFiles()
        }
        .keyboardShortcut("o")
        .disabled(!store.ready || !store.hasKey)
        Button("アジェンダを準備") {
            NSApp.activate()
            views.full()
            store.planMeeting()
        }
        .keyboardShortcut("n")
        .disabled(!store.ready)
        Divider()
        Button("小画面を表示") {
            NSApp.activate()
            views.compact()
        }
        Button("大きい画面を表示") {
            NSApp.activate()
            views.full()
        }
    }
}
struct MenuBarMenu: View {
    @ObservedObject var store: Store
    var body: some View {
        if store.recording, let meeting = store.activeMeeting {
            Text("録音中 \(clock(Date().timeIntervalSince(meeting.recordingOrigin)))：\(meeting.title)")
        } else if !store.hasKey {
            Text("録音するには、設定で OpenAI の API キーを保存してください")
        }
        RecordingMenuItems(store: store)
        Divider()
        SettingsLink { Text("設定…") }
        Button("ギジログを終了") { NSApp.terminate(nil) }
    }
}
// The menu bar shows a waveform, or the recording mark while recording. (A ticking clock in the menu bar label
// makes SwiftUI's status item re-layout in an endless loop at launch, so the elapsed time lives in the menu.)
struct MenuBarLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        Image(systemName: store.recording ? "record.circle.fill" : "waveform")
            .accessibilityLabel(store.recording ? "ギジログ 録音中" : "ギジログ")
    }
}
