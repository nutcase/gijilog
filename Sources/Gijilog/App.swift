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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tahoe wraps legacy ICNS artwork in another tile. Draw the bundled artwork directly in the
        // running app's Dock tile; keep the bundle icon for Finder and earlier macOS versions.
        guard #available(macOS 26, *),
            let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let image = NSImage(contentsOf: url)
        else { return }
        let tile = NSApplication.shared.dockTile
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.autoresizingMask = [.width, .height]
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task {
            await store.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
