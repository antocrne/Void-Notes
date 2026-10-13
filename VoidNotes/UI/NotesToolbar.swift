import SwiftUI

/// The window's toolbar: the list on the left; a new note on the right while the list is
/// hidden (otherwise it is in the list, next to a new folder). What acts on the note being read —
/// formatting, delete — is in the note, by its title (`NoteActions`). A real window toolbar, so
/// macOS delivers its clicks and moves the window from its empty places. In the chrome's gray,
/// not the accent: the accent is for the note. While one types, it fades away.
struct NotesToolbar: ToolbarContent {
    let model: NotesModel
    let settings: AppSettings

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ChromeButton(symbol: "sidebar.left", help: "Liste des notes (⌃⌘S)") {
                withAnimation(Theme.spring) { settings.showsSidebar.toggle() }
            }
            .modifier(FadesWhileWriting(model: model))
        }
        .plainToolbarItem()
        // macOS 26+ packs items to the left unless told otherwise; earlier versions put
        // `.primaryAction` on the right by themselves.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .primaryAction) {
            ChromeButton(symbol: "square.and.pencil", help: "Nouvelle note (⌘N)") { model.newNote() }
                .opacity(settings.showsSidebar ? 0 : 1)
                .allowsHitTesting(!settings.showsSidebar)
                .modifier(FadesWhileWriting(model: model))
        }
        .plainToolbarItem()
    }
}

/// Steps aside while the note is being typed; the pointer brings it back.
struct FadesWhileWriting: ViewModifier {
    let model: NotesModel
    var dimmed: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(model.writing ? dimmed : 1)
            .allowsHitTesting(!model.writing || dimmed > 0)
            .animation(.easeInOut(duration: model.writing ? 0.6 : 0.2), value: model.writing)
    }
}

extension ToolbarContent {
    /// No Liquid Glass capsule behind the item (macOS 26+): the toolbar keeps Void's flat chrome.
    @ToolbarContentBuilder
    func plainToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
