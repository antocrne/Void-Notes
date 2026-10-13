#if DEBUG
import Foundation

/// Debug builds only. Launch arguments that never touch the real notes or preferences:
/// `-demo YES` shows sample notes kept in memory, `-selfTest YES` runs the checks and quits,
/// `-snapshot name` writes a picture of the window and quits (the last two on the Mac only).
/// `-theme` and `-accent` choose the look.
enum DebugLaunch {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var isSelfTest: Bool { UserDefaults.standard.bool(forKey: "selfTest") }
    static var snapshotName: String? { UserDefaults.standard.string(forKey: "snapshot") }
    static var isRequested: Bool { isDemo || isSelfTest || snapshotName != nil }
    /// `-pinned YES`: "Liste de courses" is pinned at the top of the list.
    static var pinsDemoNote: Bool { UserDefaults.standard.bool(forKey: "pinned") }

    // MARK: Sample notes

    /// "Personnel", where the sample folders are, and a second space with one note.
    static let demoSpaces: [Space] = isSelfTest ? [] : [Space(), Space(name: "Studio", icon: "paintpalette")]

    static let demoFolders: [Folder] = isSelfTest ? [] : [
        Folder(name: "Voyages", icon: "airplane"),
        Folder(name: "Travail", icon: "briefcase"),
        Folder(name: "Maison", icon: "house"),
    ].flatMap { folder in
        folder.name == "Voyages" ? [folder, Folder(name: "Portugal", icon: "map", parent: folder.id)]
            : folder.name == "Travail" ? [folder, Folder(name: "Void Notes", icon: "sparkles", parent: folder.id)] : [folder]
    }

    static var demoNotes: [Note] {
        guard !isSelfTest else { return [] }
        let now = Date.now
        // In order: Lisbonne, Idées, Réunion, Courses, Livres (the last one in no folder).
        let filed = ["Portugal", "Void Notes", "Travail", "Maison"].map { name in demoFolders.first { $0.name == name }?.id }
        var studio = note(minutesAgo: 60 * 5, now: now, [
            (.title, "Pistes pour l'affiche"),
            (nil, "Un seul aplat, une seule graisse. Essayer le format carré."),
        ])
        studio.space = demoSpaces.last?.id
        var deleted = note(minutesAgo: 60 * 24 * 9, now: now, [(.title, "Brouillon de discours"), (nil, "À reprendre, ou pas.")])
        deleted.deleted = now.addingTimeInterval(-86400 * 4)
        var archived = note(minutesAgo: 60 * 24 * 70, now: now, [(.title, "Déménagement 2025"), (nil, "☑ Cartons"), (nil, "☑ État des lieux")])
        archived.archived = true
        return zip(unfiledDemoNotes(now: now), filed + [nil]).map { note, folder in
            var note = note
            note.folder = folder
            note.pinned = pinsDemoNote && note.title == "Liste de courses"
            return note
        } + [studio, deleted, archived]
    }

    private static func unfiledDemoNotes(now: Date) -> [Note] {
        return [
            note(minutesAgo: 2, now: now, [
                (.title, "Carnet de voyage — Lisbonne"),
                (nil, "Trois jours en octobre, sans programme serré. L'idée : marcher, **manger**, et garder les après-midi pour *ne rien faire*."),
                (.heading, "À ne pas manquer"),
                (nil, "• Le miradouro da Senhora do Monte au lever du jour"),
                (nil, "• La LX Factory, pour la librairie"),
                (nil, "• Un pastel de nata **encore tiède**, ==pas ailleurs qu'à Belém=="),
                (.heading, "Avant de partir"),
                (nil, "1. Réserver le train pour Sintra"),
                (nil, "2. Vérifier la carte d'identité"),
                (nil, "3. Prévenir Camille pour le chat"),
                (.divider, "---"),
                (.quote, "« Le voyage est une espèce de porte par où l'on sort de la réalité. »"),
                (nil, "À relire dans l'avion."),
            ]),
            note(minutesAgo: 95, now: now, [
                (.title, "Idées pour Void Notes"),
                (nil, "Rester simple. Une liste, un texte, rien d'autre à l'écran."),
                (nil, "• Mise en forme pendant la frappe"),
                (nil, "• Recherche immédiate"),
            ]),
            note(minutesAgo: 60 * 26, now: now, [
                (.title, "Réunion du lundi"),
                (nil, "Points à aborder : calendrier de la 0.2, retours des premiers essais, *priorités* du mois."),
            ]),
            note(minutesAgo: 60 * 24 * 6, now: now, [
                (.title, "Liste de courses"),
                (nil, "☑ Café"), (nil, "☑ Citrons"), (nil, "☐ Pain au levain"), (nil, "☐ Tomates, basilic"),
            ]),
            note(minutesAgo: 60 * 24 * 40, now: now, [
                (.title, "Livres à lire"),
                (nil, "Pessoa, *Le Livre de l'intranquillité*. Calvino, *Les Villes invisibles*."),
            ]),
        ]
    }

    /// A note from lines written with **, * and == around bold, italic and highlighted passages.
    private static func note(minutesAgo: Double, now: Date, _ lines: [(NoteBlock?, String)]) -> Note {
        var text = "", runs: [StyleRun] = []
        for (index, (block, line)) in lines.enumerated() {
            let start = text.utf16.count
            var bold = false, italic = false, highlight = false
            var rest = Substring(line)
            while !rest.isEmpty {
                if rest.hasPrefix("**") { bold.toggle(); rest = rest.dropFirst(2); continue }
                if rest.hasPrefix("*") { italic.toggle(); rest = rest.dropFirst(); continue }
                if rest.hasPrefix("==") { highlight.toggle(); rest = rest.dropFirst(2); continue }
                let piece = rest.prefix { $0 != "*" && $0 != "=" }
                rest = rest.dropFirst(piece.count)
                if bold || italic || highlight || block != nil {
                    runs.append(StyleRun(start: text.utf16.count, length: piece.utf16.count, block: block, bold: bold ? true : nil, italic: italic ? true : nil,
                                         highlight: highlight ? true : nil))
                }
                text += piece
            }
            if index < lines.count - 1 {
                if block != nil { runs.append(StyleRun(start: text.utf16.count, length: 1, block: block)) }
                text += "\n"
            }
            _ = start
        }
        let date = now.addingTimeInterval(-minutesAgo * 60)
        return Note(created: date.addingTimeInterval(-86400 * 3), modified: date, content: NoteContent(text: text, runs: runs))
    }
}
#endif
