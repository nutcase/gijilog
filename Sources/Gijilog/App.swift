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
        // The compact view floats beside the video call while the minutes are written.
        Window("ギジログ 小画面", id: "live") {
            LiveWindow().environmentObject(store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 400, height: 760)
        .windowResizability(.contentMinSize)
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
