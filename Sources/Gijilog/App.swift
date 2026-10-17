import AppKit
import SwiftUI

@main struct GijilogApp: App {
    @StateObject private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        // Single windows, so switching between the full view and the compact view always finds the same one.
        Window("ギジログ", id: "main") {
            ContentView().environmentObject(store).frame(minWidth: 1040, minHeight: 680)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("録音") { RecordingMenuItems(store: store) }
            CommandGroup(after: .textEditing) { FindMenuItem(store: store) }
        }
        // The compact view floats beside the video call while the minutes are written.
        Window("ギジログ 小画面", id: "live") {
            LiveWindow().environmentObject(store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 400, height: 760)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuBarMenu(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.menu)
        Settings { SettingsView().environmentObject(store) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: Store?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        // A quit another app asks for (one that quits apps it thinks unused, a script) would end the meeting's
        // recording: it is turned down while recording. ⌘Q, the menus, the Dock and logging out still quit.
        if let event = NSAppleEventManager.shared().currentAppleEvent, event.eventClass == kCoreEventClass,
            event.eventID == kAEQuitApplication
        {
            let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
            let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            if Store.refusesQuit(
                recording: store.recording, sender: pid.map { _ in app?.bundleIdentifier ?? "" },
                fromThisApp: pid == getpid(),
                systemReason: event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil)
            {
                store.status = "録音中のため、\(app?.localizedName ?? "ほかのアプリ")からの終了の依頼を断りました"
                return .terminateCancel
            }
        }
        Task {
            await store.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
