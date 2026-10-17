import SwiftUI

@main
struct VoidNotesiOSApp: App {
    @State private var settings = AppSettings.shared
    @State private var store = NoteStore.shared
    @State private var model = NotesModel.shared
    @State private var sync = SyncEngine.shared
    @Environment(\.scenePhase) private var scenePhase
    /// The app isn't in front (app switcher, Control Center) while a locked note is open: it is
    /// covered, so that neither the switcher nor its snapshot shows it.
    @State private var covered = false

    init() {
        SyncEngine.shared.onApplied = { NotesModel.shared.storeChanged() }
        #if DEBUG
        DebugLaunch.startIOS()
        #endif
        #if BETA
        // A listening cut short last time (the app killed): its sound goes to its note.
        Task { @MainActor in await Listener.shared.recoverInterrupted() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NotesScreen()
                .environment(settings)
                .environment(store)
                .environment(model)
                .environment(sync)
                .tint(Theme.accent)
                .preferredColorScheme(settings.colorScheme)
                // voidnotes://new?… : a new note, shown.
                .onOpenURL { url in _ = model.importNote(from: url) }
                .overlay {
                    if covered {
                        Theme.surface.ignoresSafeArea().overlay { VoidLogo(size: 44).opacity(0.9) }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // There is no "Save": whatever was typed is written before the app leaves the screen.
                    if phase != .active { store.flush() }
                    // Out of the front, an unlocked note is covered at once (Face ID's own
                    // dialog leaves nothing unlocked: it isn't covered); in the background,
                    // locked notes are hidden again.
                    if phase != .active, !model.unlocked.isEmpty { covered = true }
                    if phase == .active { covered = false }
                    if phase == .background { model.relock() }
                }
        }
    }
}
