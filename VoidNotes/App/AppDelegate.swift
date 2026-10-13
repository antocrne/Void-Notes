import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The longest the app waits, when it quits, for what is left to reach the shared folder.
    static let quitSyncLimit: Duration = .seconds(5)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One window; no "Show Tab Bar" menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { AppSettings.shared.applyAppearance() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { NoteDirectory.publish(NoteStore.shared) }
    }

    /// There is no "Save": whatever was typed is written before the app goes, and sent to the
    /// shared folder — for a few seconds at most, without blocking the app meanwhile.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            NotesModel.shared.prepareToQuit()
            guard SyncEngine.shared.hasUnsentChanges else { return .terminateNow }
            Task { @MainActor in
                await SyncEngine.shared.syncBeforeExit(within: Self.quitSyncLimit)
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { NotesModel.shared.prepareToQuit() }
        AppLanguage.relaunchIfRequested()
    }

    /// With its icon in the menu bar, the app stays there when its window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppSettings.shared.showsQuickNote }
    }
}
