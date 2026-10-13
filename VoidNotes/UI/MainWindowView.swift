import SwiftUI

/// Root of the window: the list of notes on the chrome, the note being written on a rounded
/// surface — Void's layout, with the note where Void shows the page. The chrome itself, tinted or
/// not, is drawn behind the whole window, toolbar included (`WindowBackdrop`, `WindowChrome`).
struct MainWindowView: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(\.openSettings) private var openSettings

    static let autosaveName = "VoidNotesMainWindow"

    var body: some View {
        HStack(spacing: 0) {
            if settings.showsSidebar {
                NoteListView()
                    .padding(.bottom, 8)
                    // While one types, the list recedes; the pointer brings it back.
                    .modifier(FadesWhileWriting(model: model, dimmed: 0.35))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NoteSurface(drawsFrame: false))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                .padding(.leading, settings.showsSidebar ? 0 : 8)
                .padding([.trailing, .bottom], 8)
        }
        .frame(minWidth: 640, minHeight: 420)
        // The window's frame below the toolbar; the toolbar's is drawn by the title bar (`WindowBackdrop`).
        .background { if WindowBackdrop.metrics.split { WindowChrome(edge: .bottom) } }
        .toolbar { NotesToolbar(model: model, settings: settings) }
        .modifier(ChromeToolbarBackground())
        .tint(Theme.accent)
        .background(WindowAccessor(configure: configure))
        // The pointer moves, a click, a scroll: what faded while typing comes back.
        .background(PointerWatcher { if model.writing { model.writing = false } })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.writing = false }
        .onAppear {
            #if DEBUG
            DebugLaunch.start { openSettings() }
            #endif
        }
        // voidnotes://new?… (Void, « Envoyer vers Void Notes ») : a new note, shown;
        // voidnotes://append?note=…: added to that note.
        .onOpenURL { url in withAnimation(Theme.quick) { _ = model.importNote(from: url) } }
        // Another app comes to the front: what was typed is on disk before anything else happens,
        // and Void knows the notes it can add to.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.flush()
            NoteDirectory.publish(store)
        }
        // The screen sleeps, is locked, or goes to another user: locked notes are hidden again.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in model.relock() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in model.relock() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))) { _ in model.relock() }
        .confirmationDialog("Supprimer « \(model.pendingDeletion?.title ?? "") » ?",
                            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } })) {
            Button("Supprimer définitivement", role: .destructive) {
                if let note = model.pendingDeletion { withAnimation(Theme.quick) { model.delete(note) } }
            }
            Button("Annuler", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text("La note et ses pièces jointes sont supprimées définitivement de ce Mac.")
        }
        .confirmationDialog("Vider la corbeille de « \(model.currentSpace.name) » ?",
                            isPresented: Binding(get: { model.confirmingEmptyTrash }, set: { model.confirmingEmptyTrash = $0 })) {
            Button("Vider la corbeille", role: .destructive) { withAnimation(Theme.quick) { model.emptyTrash() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(model.trashedNotes.count == 1 ? "La note qui s'y trouve est supprimée définitivement de ce Mac."
                 : "Les \(model.trashedNotes.count) notes qui s'y trouvent sont supprimées définitivement de ce Mac.")
        }
        .confirmationDialog("Supprimer le dossier « \(model.pendingFolderDeletion?.name ?? "") » ?",
                            isPresented: Binding(get: { model.pendingFolderDeletion != nil }, set: { if !$0 { model.pendingFolderDeletion = nil } })) {
            Button("Supprimer le dossier", role: .destructive) {
                if let folder = model.pendingFolderDeletion { withAnimation(Theme.quick) { model.delete(folder) } }
            }
            Button("Annuler", role: .cancel) { model.pendingFolderDeletion = nil }
        } message: {
            Text("Ses sous-dossiers sont supprimés avec lui. Aucune note n'est supprimée : les siennes reviennent dans le dossier au-dessus.")
        }
        .confirmationDialog("Supprimer les \(model.selectionCount) éléments sélectionnés ?",
                            isPresented: Binding(get: { model.confirmingSelectionDeletion }, set: { model.confirmingSelectionDeletion = $0 })) {
            Button("Supprimer", role: .destructive) { withAnimation(Theme.quick) { model.deleteSelection() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les notes sélectionnées vont à la corbeille. Les dossiers sont supprimés avec leurs sous-dossiers ; les notes qui y restent reviennent dans le dossier au-dessus.")
        }
        .alert("Opération impossible", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }


    @ViewBuilder private var content: some View {
        if let note = model.selected, model.isConcealed(note) {
            LockedNote(note: note)
        } else if let note = model.selected {
            NoteEditor(note: note, accent: settings.accent, checksSpelling: settings.checksSpelling, checksGrammar: settings.checksGrammar,
                       searchQuery: model.query, model: model, store: store, focusRequest: model.editorFocusRequest) { content in
                store.update(note.id, content: content)
            }
            // A new editor for each note: its own text, its own undo history — and for a note
            // that leaves the trash, which can be written again, or that another device changed;
            // and when the frame goes from neutral to tinted or back (its grey changes).
            .id("\(note.id)\(note.deleted == nil)\(store.revisions[note.id] ?? 0)\(settings.chromeTint == .none)")
        } else {
            EmptyState()
        }
    }

    private func configure(_ window: NSWindow) {
        window.toolbar?.showsBaselineSeparator = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The content starts below the toolbar: the toolbar's empty places belong to macOS, which
        // moves the window from there (and zooms it on double-click).
        window.styleMask.remove(.fullSizeContentView)
        window.isMovable = true
        window.tabbingMode = .disallowed
        // The pointer's moves end the fading of the chrome while typing (`PointerWatcher`).
        window.acceptsMouseMovedEvents = true
        WindowBackdrop.install(in: window)
        window.setFrameAutosaveName(Self.autosaveName)
    }
}

/// No note to show: the mark, and the one thing to do.
private struct EmptyState: View {
    @Environment(NotesModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            VoidLogo(size: 44).opacity(0.9)
            Text("Aucune note ouverte")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Button("Nouvelle note  ⌘N") { model.newNote() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accentFill))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A locked note, before Touch ID: nothing of it but that it is locked, and the way in.
private struct LockedNote: View {
    let note: Note
    @Environment(NotesModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text("Note verrouillée")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Button("Déverrouiller  ⇧⌘L") { model.unlock(note.id) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accentFill))
                .help("Avec \(NoteLock.method)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The toolbar shows the window's chrome color rather than a material.
private struct ChromeToolbarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}
