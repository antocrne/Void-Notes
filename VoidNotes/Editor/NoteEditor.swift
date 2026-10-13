import SwiftUI

/// The note's text in the window. One editor per note (the caller gives it the note's `id`), so
/// each note has its own undo history; the text view owns the text while it's shown, and every
/// change goes to `onChange` to be saved.
struct NoteEditor: NSViewRepresentable {
    let note: Note
    let accent: AccentChoice
    /// Réglages: the red and blue lines.
    var checksSpelling = true
    var checksGrammar = true
    /// The search of the list: what it found shows in the note.
    var searchQuery = ""
    /// Told which text view shows the note, for the formatting panel.
    let model: NotesModel
    /// Keeps the files joined to the note.
    let store: NoteStore
    /// Changes when the text should take the keyboard.
    let focusRequest: Int
    let onChange: (NoteContent) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = NoteTextView.makeScrollable()
        // A note of the trash is read, not written.
        textView.isEditable = !note.isReadOnly && note.deleted == nil
        let id = note.id
        textView.attachmentsDirectory = store.attachmentsDirectory(of: id)
        textView.attachFile = { [store] in store.attach($0, to: id) }
        textView.attachData = { [store] in store.attach($0, named: $1, to: id) }
        textView.addPhotos = { [store] in store.addPhotos($0, to: id) }
        textView.addPhotoData = { [store] in store.addPhoto($0, named: $1, to: id) }
        textView.load(note.content)
        if note.deleted != nil { textView.dimText() }
        textView.onTyping = { [model] in if !model.writing { model.writing = true } }
        textView.searchWords = Self.words(searchQuery)
        context.coordinator.focusRequest = focusRequest
        // A note just opened takes the keyboard.
        textView.takesFocusWhenShown = true
        model.editor = textView
        let actions = NSHostingView(rootView: NoteActions(model: model, store: store))
        textView.accessory = actions
        textView.accessoryFloats = { [model, store] in actions.rootView = NoteActions(model: model, store: store, floating: $0) }
        textView.album = NSHostingView(rootView: NotePhotoAlbumSection(noteID: id, store: store))
        textView.albumHeight = note.photos.isEmpty ? 0 : NotePhotoAlbumSection.height
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        if textView.accent != accent { textView.accent = accent }
        let words = Self.words(searchQuery)
        if textView.searchWords != words { textView.searchWords = words }
        textView.setProofreading(spelling: checksSpelling, grammar: checksGrammar)
        textView.albumHeight = note.photos.isEmpty ? 0 : NotePhotoAlbumSection.height
        textView.meta = note.deleted == nil ? (note.archived ? "Archivée  ·  " : "") + NoteDate.meta(created: note.created, modified: note.modified)
            : NoteDate.trashMeta(daysLeft: store.daysLeft(note))
        textView.metaHelp = NoteDate.fullMeta(created: note.created, modified: note.modified)
        textView.onChange = { [weak textView] in
            if let textView { onChange(textView.content) }
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak textView] in textView?.focus() }
        }
    }

    static func words(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var focusRequest = 0
    }
}
