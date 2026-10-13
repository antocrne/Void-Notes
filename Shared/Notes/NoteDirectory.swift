import Foundation
#if os(macOS)
import AppKit
#endif

/// The notes another app can add to (Void: « Envoyer vers Void Notes » → a note), left on a named
/// pasteboard as the image Void sends comes on one: the pinned notes, then the most recently
/// changed, with their title and the name of their space — nothing of their text. Neither a
/// locked note, nor an archived one, nor one in the trash. Written when the app goes to the
/// background, when it starts, and when a note comes in; the pasteboard keeps it once the app
/// has quit. Mac only: on iPhone, Void sends to a new note.
@MainActor
enum NoteDirectory {
    static let pasteboard = "app.void.notes.directory"
    /// More would make too long a menu.
    static let limit = 12

    struct Entry: Codable, Equatable {
        let id: UUID
        let title: String
        let space: String
    }

    struct Payload: Codable, Equatable {
        var version = 1
        var notes: [Entry]
    }

    static func entries(of store: NoteStore) -> [Entry] {
        let candidates = store.notes.filter { !$0.locked && !$0.archived && !$0.isReadOnly && !$0.isBlank }
        // `store.notes` is the most recently changed first.
        let ordered = candidates.filter(\.pinned) + candidates.filter { !$0.pinned }
        return ordered.prefix(limit).map { note in
            Entry(id: note.id, title: String(note.title.prefix(80)), space: store.space(note.space)?.name ?? "")
        }
    }

    #if os(macOS)
    /// What was written last: the pasteboard isn't rewritten for nothing.
    private static var published: Payload?

    static func publish(_ store: NoteStore) {
        #if DEBUG
        // The sample notes stay in their window.
        if DebugLaunch.isRequested { return }
        #endif
        let payload = Payload(notes: entries(of: store))
        guard payload != published, let data = try? JSONEncoder().encode(payload) else { return }
        let board = NSPasteboard(name: NSPasteboard.Name(pasteboard))
        board.clearContents()
        board.setData(data, forType: NSPasteboard.PasteboardType("app.void.notes.directory"))
        published = payload
    }
    #else
    static func publish(_ store: NoteStore) {}
    #endif
}
