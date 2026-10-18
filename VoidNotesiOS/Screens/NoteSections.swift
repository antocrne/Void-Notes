import SwiftUI

/// Under the title, out of the text: the note's album of images, its recordings, then its tabs
/// once it has a transcript or a summary — each with the line that ends it (the recordings' is
/// the tabs'). Shown in the place the text view keeps for the album.
struct NoteSections: View {
    let noteID: UUID
    let store: NoteStore

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }

    /// The room the sections take in the note; 0: no images, recordings nor tabs.
    static func height(of note: Note) -> CGFloat {
        let tabs = NoteTabs.hasTabs(note)
        var parts: [CGFloat] = []
        if !note.photos.isEmpty { parts.append(NotePhotoAlbumSection.height) }
        if !note.recordings.isEmpty { parts.append(NoteRecordingsSection.height(ruled: !tabs)) }
        if tabs { parts.append(NoteTabBar.height) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * spacing
    }

    static let spacing: CGFloat = 10

    var body: some View {
        let tabs = note.map(NoteTabs.hasTabs) ?? false
        VStack(spacing: Self.spacing) {
            if note?.photos.isEmpty == false {
                NotePhotoAlbumSection(noteID: noteID, store: store)
                    .frame(height: NotePhotoAlbumSection.height)
            }
            if note?.recordings.isEmpty == false {
                NoteRecordingsSection(noteID: noteID, store: store, ruled: !tabs)
                    .frame(height: NoteRecordingsSection.height(ruled: !tabs))
            }
            if tabs {
                NoteTabBar(noteID: noteID, store: store)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
