import SwiftUI

@main
struct VoidNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var store = NoteStore.shared
    @State private var model = NotesModel.shared
    @State private var sync = SyncEngine.shared

    init() {
        #if DEBUG
        // A debug launch always shows its window, even if the last one ended with it closed.
        if DebugLaunch.isRequested { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
        #endif
        SyncEngine.shared.onApplied = { NotesModel.shared.storeChanged() }
    }

    var body: some Scene {
        Window("Void Notes", id: "main") {
            MainWindowView()
                .environment(settings)
                .environment(store)
                .environment(model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 980, height: 680)
        .commands { NotesCommands(model: model, settings: settings, store: store) }

        // Réglages → « Icône dans la barre des menus ».
        MenuBarExtra("Void Notes", systemImage: "square.and.pencil", isInserted: $settings.showsQuickNote) {
            QuickNoteView()
                .environment(settings)
                .environment(store)
                .environment(model)
                .preferredColorScheme(settings.colorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(settings)
                .environment(store)
                .environment(sync)
        }
    }
}
