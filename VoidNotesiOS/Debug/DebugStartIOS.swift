#if DEBUG
import UIKit

/// Debug builds only, on iPhone: `-photos 5` opens the first note of the list with that many
/// pictures in its album; with `-blank YES`, a new empty note instead; with `-later YES`, the
/// pictures come once the note is on screen, as when they're picked in Photos; `-note Livres`
/// picks the note.
extension DebugLaunch {
    @MainActor
    static func startIOS() {
        #if BETA
        // `-listening YES`: the first note opened, listening in it — two sentences heard, words in
        // flight.
        if isDemo, UserDefaults.standard.bool(forKey: "listening") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let note = NoteStore.shared.notes.first(where: { !$0.archived }) else { return }
                NotesModel.shared.open(note.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let listener = Listener.shared
                    listener.pretend(in: note.id, words: "et pour la suite nous verrons avec l'équipe", levels: [0.2, 0.55, 0.8, 0.45, 0.65],
                                     startedAt: .now.addingTimeInterval(-134))
                    listener.pretendHeard("Le budget de l'année est validé.", from: 0, to: 2)
                    listener.pretendHeard("On se revoit mardi avec les maquettes.", from: 2.4, to: 4)
                }
            }
        }
        #endif
        let photos = UserDefaults.standard.integer(forKey: "photos")
        guard isDemo, photos > 0 else { return }
        if UserDefaults.standard.bool(forKey: "blank") { NotesModel.shared.newNote(in: nil) }
        // `-note Livres`: the note whose title starts so.
        let title = UserDefaults.standard.string(forKey: "note") ?? ""
        guard let note = NoteStore.shared.note(NotesModel.shared.selectedID)
            ?? NoteStore.shared.notes.first(where: { $0.deleted == nil && !$0.archived && $0.title.hasPrefix(title) }) else { return }
        NotesModel.shared.select(note.id)
        let later = UserDefaults.standard.bool(forKey: "later")
        DispatchQueue.main.asyncAfter(deadline: .now() + (later ? 1.5 : 0)) { addPictures(photos, to: note.id) }
    }

    @MainActor
    private static func addPictures(_ photos: Int, to id: UUID) {
        for index in 0..<photos {
            let hue = CGFloat(index) / CGFloat(photos)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
                UIColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
            if let data = image.pngData() { NoteStore.shared.addPhoto(data, named: "Photo \(index + 1).png", to: id) }
        }
    }
}
#endif
