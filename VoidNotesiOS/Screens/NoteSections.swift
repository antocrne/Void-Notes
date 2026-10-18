import SwiftUI

/// Under the title, out of the text: the note's album of images, then its tabs once it has a
/// transcript or a summary — each with the line that ends it. Shown in the place the text view
/// keeps for the album.
struct NoteSections: View {
    let noteID: UUID
    let store: NoteStore

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }

    /// The room the sections take in the note; 0: neither images nor tabs.
    static func height(of note: Note) -> CGFloat {
        var parts: [CGFloat] = []
        if !note.photos.isEmpty { parts.append(NotePhotoAlbumSection.height) }
        if NoteTabs.hasTabs(note) { parts.append(NoteTabBar.height) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * spacing
    }

    static let spacing: CGFloat = 10

    var body: some View {
        VStack(spacing: Self.spacing) {
            if note?.photos.isEmpty == false {
                NotePhotoAlbumSection(noteID: noteID, store: store)
                    .frame(height: NotePhotoAlbumSection.height)
            }
            if let note, NoteTabs.hasTabs(note) {
                NoteTabBar(noteID: noteID, store: store)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
