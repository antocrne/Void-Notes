import Foundation
#if os(macOS)
import AppKit
#endif

/// The notes another app can add to (Void: « Envoyer vers Void Notes » → a note), left on a named
/// pasteboard as the image Void sends comes on one: the tree of the list — the spaces, their
/// folders and subfolders, the notes with their title, their folder and whether they are pinned —
/// nothing of their text. Neither a locked note, nor an archived one, nor one in the trash; a
/// folder without any of those notes, in it or under it, is left out. Written when the app goes to
/// the background, when it starts, and when a note comes in; the pasteboard keeps it once the app
/// has quit. Mac only: on iPhone, Void sends to a new note.
@MainActor
enum NoteDirectory {
    static let pasteboard = "app.void.notes.directory"
    /// Version 1 was a flat list of twelve notes.
    nonisolated static let version = 2
    /// Pinned, then the most recent: more would only weigh on the pasteboard.
    static let limit = 500

    struct SpaceEntry: Codable, Equatable {
        let id: UUID
        let name: String
        let icon: String
    }

    struct FolderEntry: Codable, Equatable {
        let id: UUID
        let name: String
        let icon: String
        let parent: UUID?
        let space: UUID?
    }

    struct Entry: Codable, Equatable {
        let id: UUID
        let title: String
        let space: UUID?
        let folder: UUID?
        let pinned: Bool
    }

    struct Payload: Codable, Equatable {
        var version = NoteDirectory.version
        /// In the order they were made, as the space bar shows them.
        var spaces: [SpaceEntry]
        /// Each one followed by its subfolders, by name — the order of the list.
        var folders: [FolderEntry]
        /// Pinned first, then the most recently changed.
        var notes: [Entry]
    }

    static func entries(of store: NoteStore) -> [Entry] {
        let candidates = store.notes.filter { !$0.locked && !$0.archived && !$0.isReadOnly && !$0.isBlank }
        // `store.notes` is the most recently changed first.
        let ordered = candidates.filter(\.pinned) + candidates.filter { !$0.pinned }
        return ordered.prefix(limit).map { note in
            Entry(id: note.id, title: String(note.title.prefix(80)), space: note.space ?? store.spaces.first?.id,
                  folder: store.folder(note.folder) == nil ? nil : note.folder, pinned: note.pinned)
        }
    }

    static func payload(of store: NoteStore) -> Payload {
        let notes = entries(of: store)
        // The folders the notes are in, and the ones above them.
        var used = Set<UUID>()
        for folder in Set(notes.compactMap(\.folder)) {
            var id: UUID? = folder
            while let current = id, used.insert(current).inserted { id = store.folder(current)?.parent }
        }
        let folders = store.folderRows.map(\.folder).filter { used.contains($0.id) }.map {
            FolderEntry(id: $0.id, name: String($0.name.prefix(80)), icon: OutlineSymbol.name($0.icon), parent: $0.parent, space: $0.space ?? store.spaces.first?.id)
        }
        let spaces = store.spaces.map { SpaceEntry(id: $0.id, name: $0.name, icon: OutlineSymbol.name($0.icon)) }
        return Payload(spaces: spaces, folders: folders, notes: notes)
    }

    #if os(macOS)
    /// What was written last: the pasteboard isn't rewritten for nothing.
    private static var published: Payload?

    static func publish(_ store: NoteStore) {
        #if DEBUG
        // The sample notes stay in their window.
        if DebugLaunch.isRequested { return }
        #endif
        let payload = payload(of: store)
        guard payload != published, let data = try? JSONEncoder().encode(payload) else { return }
        let board = NSPasteboard(name: NSPasteboard.Name(pasteboard))
        board.clearContents()
        board.setData(data, forType: NSPasteboard.PasteboardType(pasteboard))
        published = payload
    }
    #else
    static func publish(_ store: NoteStore) {}
    #endif
}
