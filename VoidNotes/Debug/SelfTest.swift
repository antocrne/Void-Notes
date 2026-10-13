#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `-selfTest YES` checks the storage, the saved format and the formatting
/// as you type (by typing in a real text view), prints one line per check and quits with the
/// number of failures. The checks read the French interface: launch with `-AppleLanguages '(fr)'`
/// to keep it whatever the system's language.
@MainActor
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  (\(detail()))")")
        if !ok { failures += 1 }
    }

    static func run() async {
        await storage()
        folders()
        spaces()
        selection()
        trash()
        archive()
        pin()
        lock()
        imports()
        attachments()
        await sync()
        format()
        typing()
        writingTools()
        markdown()
        await checklistSort()
        links()
        proofreading()
        await window()
        await tint()
        print(failures == 0 ? "Auto-test : tout passe." : "Auto-test : \(failures) échec(s).")
        exit(Int32(failures))
    }

    // MARK: Storage

    private static func storage() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let files = { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") } }

        let store = NoteStore(directory: directory)
        check("Stockage : dossier vide, aucune note", store.notes.isEmpty)
        let first = store.create()
        store.flush()
        check("Stockage : une note vide n'est pas écrite", files().isEmpty)

        let content = NoteContent(text: "Été à Lisbonne\nUn café serré", runs: [StyleRun(start: 0, length: 15, block: .title), StyleRun(start: 18, length: 4, bold: true)])
        store.update(first.id, content: content)
        check("Stockage : titre et aperçu", store.notes[0].title == "Été à Lisbonne" && store.notes[0].preview == "Un café serré")
        store.flush()
        check("Stockage : un fichier par note", files() == ["\(first.id.uuidString).json"])

        // Dates are kept to the millisecond: the changes below are not simultaneous.
        await sleep(0.01)
        let second = store.create()
        store.update(second.id, content: NoteContent(text: "Courses\n• Pain"))
        check("Stockage : la dernière modifiée en premier", store.notes.map(\.id) == [second.id, first.id])
        await sleep(0.01)
        store.update(first.id, content: NoteContent(text: content.text + " !", runs: content.runs))
        check("Stockage : modifier une note la remonte", store.notes.map(\.id) == [first.id, second.id])
        let modified = store.notes[0].modified
        store.update(first.id, content: store.notes[0].content)
        check("Stockage : sans changement, la date ne bouge pas", store.notes[0].modified == modified)
        store.flush()

        let reloaded = NoteStore(directory: directory)
        check("Stockage : relecture identique", reloaded.notes.map(\.content) == store.notes.map(\.content) && reloaded.notes.map(\.id) == store.notes.map(\.id),
              "\(reloaded.notes.map(\.content.text))")
        check("Stockage : dates relues", abs(reloaded.notes[0].modified.timeIntervalSince(modified)) < 1)

        check("Recherche : casse et accents ignorés", reloaded.notes.filter { $0.matches(["ete", "CAFE"]) }.map(\.id) == [first.id])
        check("Recherche : dans le contenu", reloaded.notes.filter { $0.matches(["pain"]) }.map(\.id) == [second.id])
        check("Recherche : tous les mots requis", reloaded.notes.filter { $0.matches(["pain", "lisbonne"]) }.isEmpty)

        let model = NotesModel(store: reloaded, settings: nil)
        check("Modèle : la plus récente est ouverte", model.selectedID == first.id)
        model.query = "courses"
        check("Modèle : la recherche filtre la liste", model.visibleNotes.map(\.id) == [second.id])
        model.query = ""
        model.newNote()
        let blank = model.selectedID
        check("Modèle : nouvelle note en tête", reloaded.notes.first?.id == blank && reloaded.notes.count == 3)
        model.select(second.id)
        check("Modèle : une note laissée vide disparaît", reloaded.notes.count == 2)
        model.delete(reloaded.note(second.id)!)
        check("Modèle : supprimer ouvre la note voisine", model.selectedID == first.id && reloaded.notes.count == 1)
        reloaded.delete(second.id)
        check("Stockage : le fichier d'une note supprimée définitivement est retiré", files() == ["\(first.id.uuidString).json"])

        // A note written by the first version of the format, and one from a version to come.
        let old = UUID(), later = UUID()
        for (id, version) in [(old, 1), (later, NoteStore.formatVersion + 1)] {
            let json = """
            {"created":"2026-10-01T12:05:12.345Z","id":"\(id.uuidString)","modified":"2026-10-01T12:05:12.345Z",
             "runs":[{"bold":true,"length":2,"start":0}],"text":"v\(version)","version":\(version)}
            """
            try? Data(json.utf8).write(to: directory.appendingPathComponent("\(id.uuidString).json"))
        }
        let versions = NoteStore(directory: directory)
        check("Stockage : une note au format 1 se lit et se modifie", versions.note(old)?.content.runs == [StyleRun(start: 0, length: 2, bold: true)] && versions.note(old)?.isReadOnly == false)
        check("Stockage : une note d'un format ultérieur est en lecture seule", versions.note(later)?.isReadOnly == true)
        // Put in the trash, it can't be marked as trashed: it stays, and isn't deleted for good.
        let laterModel = NotesModel(store: versions, settings: nil)
        laterModel.open(later)
        laterModel.delete(versions.note(later)!)
        check("Stockage : une note d'un format ultérieur n'est jamais supprimée par la corbeille", versions.note(later) != nil && laterModel.selectedID == later
              && FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(later.uuidString).json").path) && versions.errorMessage != nil, "\(versions.errorMessage ?? "")")
        for id in [old, later] { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).json")) }

        try? Data("pas du json".utf8).write(to: directory.appendingPathComponent("abîmé.json"))
        let afterDamage = NoteStore(directory: directory)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("illisibles").path)) ?? []
        check("Stockage : fichier illisible mis de côté", afterDamage.unreadable == 1 && afterDamage.notes.count == 1 && aside.count == 1)
    }

    // MARK: Folders

    private static func folders() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = NoteStore(directory: directory)
        let travel = store.createFolder(named: "Voyages")
        let work = store.createFolder(named: "Travail")
        let portugal = store.createFolder(named: "Portugal", in: travel.id)
        store.setIcon("airplane", for: travel.id)
        store.renameFolder(work.id, to: "  Bureau ")
        store.renameFolder(portugal.id, to: "   ")
        check("Dossiers : par nom, les sous-dossiers sous leur dossier", store.folderRows.map(\.folder.name) == ["Bureau", "Voyages", "Portugal"]
              && store.folderRows.map(\.depth) == [0, 0, 1], "\(store.folderRows.map(\.folder.name))")

        let model = NotesModel(store: store, settings: nil)
        func shown() -> [String] {
            model.rows.map {
                switch $0 {
                case .allNotes: "*"
                case .folder(let folder, let depth): String(repeating: ">", count: depth) + folder.name + "/"
                case .note(let note, let depth, let inAll): (inAll ? "*" : String(repeating: ">", count: depth)) + note.title
                case .trash, .archive: "*"
                case .trashed: "*"
                }
            }.filter { $0 != "*" }
        }
        check("Dossiers : repliés au départ, seuls ceux du haut se voient", shown() == ["Bureau/", "Voyages/"] && model.rows.first?.id == "all", "\(shown())")
        model.newNote(in: portugal.id)
        let lisbon = model.selectedID!
        store.update(lisbon, content: NoteContent(text: "Lisbonne"))
        check("Dossiers : une note créée dans un dossier le déplie jusqu'à elle", store.note(lisbon)?.folder == portugal.id
              && shown() == ["Bureau/", "Voyages/", ">Portugal/", ">>Lisbonne"], "\(shown())")
        model.newNote()
        let porto = model.selectedID!
        store.update(porto, content: NoteContent(text: "Porto"))
        check("Dossiers : une nouvelle note va dans le dossier de la note ouverte", store.note(porto)?.folder == portugal.id)
        model.newNote(in: nil)
        let loose = model.selectedID!
        store.update(loose, content: NoteContent(text: "Sans dossier"))
        let modified = store.note(loose)!.modified
        check("Dossiers : les notes sans dossier après les dossiers, les plus récentes d'abord", shown() == ["Bureau/", "Voyages/", ">Portugal/", ">>Porto", ">>Lisbonne", "Sans dossier"], "\(shown())")
        model.toggle(travel.id)
        check("Dossiers : replier un dossier cache ses sous-dossiers et leurs notes", shown() == ["Bureau/", "Voyages/", "Sans dossier"] && model.visibleNotes.map(\.id) == [loose], "\(shown())")
        model.query = "lisbonne"
        check("Dossiers : la recherche porte sur tous les dossiers, même repliés", model.visibleNotes.map(\.id) == [lisbon])
        model.open(lisbon)
        model.query = ""
        check("Dossiers : ouvrir un résultat déplie son dossier", model.selectedID == lisbon && shown().contains(">>Lisbonne"), "\(shown())")
        model.step(1)
        model.step(1)
        model.step(-1)
        model.step(1)
        check("Dossiers : ⌥⌘↑ / ⌥⌘↓ suivent l'ordre de la liste", model.selectedID == loose)
        model.toggleAllNotes()
        check("Toutes les notes : dépliée, toutes les notes de l'espace, les plus récentes d'abord, avant les dossiers",
              shown().prefix(5) == ["*Sans dossier", "*Porto", "*Lisbonne", "Bureau/", "Voyages/"] && Set(model.rows.map(\.id)).count == model.rows.count, "\(shown())")
        check("Toutes les notes : chaque note une seule fois au clavier", model.visibleNotes.map(\.id) == [loose, porto, lisbon])
        model.toggleAllNotes()
        model.beginDrag(loose)
        check("Dossiers : déposer une note sur un dossier l'y range, le déplie, sans changer sa date", model.drop(on: work.id) && store.note(loose)?.folder == work.id
              && store.note(loose)?.modified == modified && shown().prefix(2) == ["Bureau/", ">Sans dossier"] && !model.drop(on: nil), "\(shown())")
        model.beginDrag(porto)
        model.drop(on: nil)
        check("Dossiers : déposer une note hors des dossiers l'en sort", store.note(porto)?.folder == nil && shown().last == "Porto", "\(shown())")
        model.beginDrag(folder: portugal.id)
        check("Dossiers : déposer un dossier sur un autre en fait un sous-dossier, avec ses notes", model.drop(on: work.id)
              && store.folder(portugal.id)?.parent == work.id && store.note(lisbon)?.folder == portugal.id
              && store.folderRows.map(\.folder.name) == ["Bureau", "Portugal", "Voyages"] && store.folderRows.map(\.depth) == [0, 1, 0], "\(store.folderRows.map(\.folder.name))")
        model.beginDrag(folder: work.id)
        check("Dossiers : un dossier ne va ni dans lui-même ni dans un de ses sous-dossiers", !model.drop(on: portugal.id) && !model.drop(on: work.id)
              && store.folder(work.id)?.parent == nil && model.destinations(for: store.folder(work.id)!).map(\.folder.name) == ["Voyages"])
        model.beginDrag(folder: portugal.id)
        model.drop(on: nil)
        check("Dossiers : déposer un dossier sous la liste le remet au premier niveau", store.folder(portugal.id)?.parent == nil
              && store.folderRows.map(\.depth) == [0, 0, 0])
        model.moveFolder(portugal.id, to: travel.id)
        check("Dossiers : « Déplacer vers » range un dossier dans un autre", store.folder(portugal.id)?.parent == travel.id)
        store.flush()

        let reloaded = NoteStore(directory: directory)
        check("Dossiers : relus avec leur icône, leur parent et leurs notes", reloaded.folders == store.folders && reloaded.folder(travel.id)?.icon == "airplane"
              && reloaded.note(lisbon)?.folder == portugal.id && reloaded.note(loose)?.folder == work.id, "\(reloaded.folders)")

        model.delete(store.folder(travel.id)!)
        check("Dossiers : supprimer un dossier retire ses sous-dossiers, pas ses notes", store.folders.map(\.name) == ["Bureau"]
              && store.note(lisbon) != nil && store.note(lisbon)?.folder == nil && shown() == ["Bureau/", ">Sans dossier", "Porto", "Lisbonne"], "\(shown())")
        store.flush()
        let folderFile = directory.deletingLastPathComponent().appendingPathComponent("folders.json")
        try? Data("{".utf8).write(to: folderFile)
        let damaged = NoteStore(directory: directory)
        check("Dossiers : fichier des dossiers illisible mis de côté, les notes restent", damaged.folders.isEmpty && damaged.unreadable == 1 && damaged.notes.count == 3
              && !FileManager.default.fileExists(atPath: folderFile.path))
    }

    // MARK: Spaces

    private static func spaces() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        // A note and a folder from before the spaces.
        let old = UUID(), oldFolder = UUID()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(#"{"created":"2026-10-01T10:00:00.000Z","folder":"\#(oldFolder.uuidString)","id":"\#(old.uuidString)","modified":"2026-10-01T10:00:00.000Z","runs":[],"text":"Ancienne","version":3}"#.utf8)
            .write(to: directory.appendingPathComponent("\(old.uuidString).json"))
        try? Data(#"{"folders":[{"icon":"folder","id":"\#(oldFolder.uuidString)","name":"Archives"}],"version":1}"#.utf8)
            .write(to: directory.deletingLastPathComponent().appendingPathComponent("folders.json"))

        let store = NoteStore(directory: directory)
        let personal = store.spaces[0]
        check("Espaces : un espace « Personnel » par défaut", store.spaces.count == 1 && personal.name == "Personnel")
        check("Espaces : les notes et dossiers d'avant les espaces y sont", store.note(old)?.space == personal.id && store.folder(oldFolder)?.space == personal.id
              && store.note(old)?.isReadOnly == false)

        let model = NotesModel(store: store, settings: nil)
        func shown() -> [String] {
            model.rows.compactMap {
                switch $0 {
                case .allNotes, .archive, .trash, .trashed: nil
                case .folder(let folder, let depth): String(repeating: ">", count: depth) + folder.name + "/"
                case .note(let note, let depth, _): String(repeating: ">", count: depth) + note.title
                }
            }
        }
        check("Espaces : la liste montre l'espace courant", model.currentSpaceID == personal.id && shown() == ["Archives/", ">Ancienne"], "\(shown())")
        model.newSpace(named: "  Travail ", icon: "briefcase")
        let work = model.currentSpaceID
        check("Espaces : un nouvel espace est affiché, vide", store.spaces.map(\.name) == ["Personnel", "Travail"] && work != personal.id && model.rows.isEmpty && model.selectedID == nil)
        model.newNote()
        let report = model.selectedID!
        store.update(report, content: NoteContent(text: "Rapport"))
        model.newFolder()
        let clients = model.renamingFolderID!
        store.renameFolder(clients, to: "Clients")
        check("Espaces : notes et dossiers créés dans l'espace courant", store.note(report)?.space == work && store.folder(clients)?.space == work
              && shown() == ["Clients/", "Rapport"], "\(shown())")
        model.query = "ancienne"
        check("Espaces : la recherche reste dans l'espace", model.visibleNotes.isEmpty)
        model.switchSpace(to: personal.id)
        check("Espaces : changer d'espace montre ses notes et rouvre la sienne", model.query.isEmpty && model.selectedID == old && shown() == ["Archives/", ">Ancienne"], "\(shown())")
        model.switchSpace(to: work)
        check("Espaces : revenir à un espace rouvre la note qu'il montrait", model.selectedID == report)
        model.move(report, to: clients)
        model.move(store.folder(clients)!, toSpace: personal.id)
        check("Espaces : déplacer un dossier emmène ses notes", store.folder(clients)?.space == personal.id && store.note(report)?.space == personal.id
              && model.rows.isEmpty && model.selectedID == nil)
        model.switchSpace(to: personal.id)
        model.move(old, toSpace: work)
        check("Espaces : déplacer une note la sort de son dossier", store.note(old)?.space == work && store.note(old)?.folder == nil && model.selectedID != old)
        store.flush()

        let reloaded = NoteStore(directory: directory)
        check("Espaces : relus avec leur nom, leur icône et leur contenu", reloaded.spaces == store.spaces && reloaded.spaces.last?.icon == "briefcase"
              && reloaded.note(old)?.space == work && reloaded.note(report)?.space == personal.id && reloaded.folders == store.folders, "\(reloaded.spaces)")

        model.delete(store.space(work)!)
        check("Espaces : supprimer un espace garde ses notes, dans l'espace restant", store.spaces == [personal] && store.note(old)?.space == personal.id && store.notes.count == 2)
        model.delete(personal)
        check("Espaces : le dernier espace ne se supprime pas", store.spaces == [personal])
    }

    // MARK: Selection of several lines

    private static func selection() {
        let store = NoteStore(directory: nil)
        let model = NotesModel(store: store, settings: nil)
        let space = model.currentSpaceID
        let other = store.createSpace(named: "Autre")
        let work = store.createFolder(named: "Travail", space: space)
        let sub = store.createFolder(named: "Sous", in: work.id, space: space)
        let home = store.createFolder(named: "Maison", space: space)
        func make(_ text: String, in folder: UUID? = nil) -> UUID {
            let note = store.create(in: folder, space: space)
            store.update(note.id, content: NoteContent(text: text))
            return note.id
        }
        // The list, folders folded: Maison, Travail, then d, c, b, a (most recent first).
        let a = make("a"), b = make("b"), c = make("c"), d = make("d")
        let inside = make("dedans", in: sub.id)
        model.open(b)

        model.toggleSelection(d, row: d.uuidString)
        check("Sélection : ⌘-clic ajoute la note à celle qui est ouverte, sans en changer", model.selection == [b, d] && model.selectedID == b
              && model.isHighlighted(d) && !model.isHighlighted(a) && model.isInMultipleSelection(b))
        model.toggleSelection(b, row: b.uuidString)
        check("Sélection : ⌘-clic sur une ligne sélectionnée la retire", model.selection == [d] && !model.isInMultipleSelection(d))
        model.extendSelection(to: a.uuidString)
        check("Sélection : ⇧-clic prend tout de la dernière ligne choisie à celle-ci", model.selection == [a, b] && model.selectionCount == 2, "\(model.selectionCount)")
        model.open(c)
        check("Sélection : un clic simple revient à une seule note", model.selection.isEmpty && model.selectedID == c && model.isHighlighted(c))
        model.extendSelection(to: work.id.uuidString)
        check("Sélection : ⇧-clic part de la note ouverte, dossiers compris", model.selection == [c, d, work.id]
              && model.selectedFolders.count == 1 && model.selectedNotes.count == 2, "\(model.selectionCount)")
        model.query = "a"
        check("Sélection : rechercher l'abandonne", model.selection.isEmpty)
        model.query = ""

        model.open(a)
        model.toggleSelection(b, row: b.uuidString)
        model.beginDrag(b)
        check("Sélection : glisser une des notes sélectionnées les range toutes", model.drop(on: home.id)
              && store.note(a)?.folder == home.id && store.note(b)?.folder == home.id && store.note(c)?.folder == nil && model.selection == [a, b])
        model.beginDrag(c)
        model.drop(on: work.id)
        check("Sélection : glisser une note hors de la sélection ne déplace qu'elle", store.note(c)?.folder == work.id && store.note(a)?.folder == home.id)
        model.moveSelection(to: nil)
        check("Sélection : « Déplacer vers » range toutes les notes", store.note(a)?.folder == nil && store.note(b)?.folder == nil)

        model.clearSelection()
        model.toggleSelection(work.id, row: work.id.uuidString)
        model.toggleSelection(sub.id, row: sub.id.uuidString)
        check("Sélection : commencée par un dossier, la note ouverte n'en fait pas partie", model.selection == [work.id, sub.id])
        model.toggleSelection(inside, row: inside.uuidString)
        model.toggleSelection(d, row: d.uuidString)
        model.moveSelection(toSpace: other.id)
        check("Sélection : vers un autre espace, un dossier part entier avec ses sous-dossiers et leurs notes",
              store.folder(sub.id)?.parent == work.id && store.folder(sub.id)?.space == other.id && store.note(inside)?.folder == sub.id
              && store.note(c)?.folder == work.id && store.note(d)?.space == other.id && store.note(d)?.folder == nil && model.selection.isEmpty,
              "\(String(describing: store.folder(sub.id)))")

        model.open(a)
        model.toggleSelection(b, row: b.uuidString)
        model.askToDeleteSelection()
        check("Sélection : des notes seules vont à la corbeille sans confirmation", store.trashed(a) != nil && store.trashed(b) != nil
              && !model.confirmingSelectionDeletion && model.selection.isEmpty && model.selectedID == nil, "\(model.selected?.title ?? "nil") \(model.selected?.space == space) \(store.trashed(a) != nil) \(store.trashed(b) != nil) \(model.confirmingSelectionDeletion) \(model.selection.count)")
        let kept = make("gardée", in: home.id), gone = make("jetée")
        model.clearSelection()
        model.toggleSelection(home.id, row: home.id.uuidString)
        model.toggleSelection(gone, row: gone.uuidString)
        model.askToDeleteSelection()
        check("Sélection : avec un dossier, la suppression est confirmée d'abord", model.confirmingSelectionDeletion && store.folder(home.id) != nil && store.note(gone) != nil)
        model.deleteSelection()
        check("Sélection : confirmée, notes à la corbeille, dossiers supprimés, leurs notes gardées", store.folder(home.id) == nil && store.trashed(gone) != nil
              && store.note(kept) != nil && store.note(kept)?.folder == nil && !model.confirmingSelectionDeletion)
    }

    // MARK: Notes sent by Void

    private static func imports() {
        let store = NoteStore(directory: nil)
        let model = NotesModel(store: store, settings: nil)
        let kept = store.create(space: model.currentSpaceID)
        store.update(kept.id, content: NoteContent(text: "Déjà là"))
        model.select(kept.id)
        model.query = "là"

        let sent = URL(string: "voidnotes://new?title=Caf%C3%A9%20%26%20th%C3%A9&text=a%2Bb%0Ac%20%3D%20d&url=https%3A%2F%2Fexample.com%2Fa%3Fq%3D1%26r%3D2")!
        check("Envoi depuis Void : l'URL est reconnue", model.importNote(from: sent))
        let note = model.selected
        check("Envoi depuis Void : titre, texte puis lien de la page", note?.content.text == "Café & thé\na+b\nc = d\n\nSource : https://example.com/a?q=1&r=2",
              note?.content.text ?? "nil")
        check("Envoi depuis Void : la première ligne est le titre de la note", note?.title == "Café & thé"
              && note?.content.runs == [StyleRun(start: 0, length: 11, block: .title), StyleRun(start: 22, length: 38, block: .source)], "\(note?.content.runs ?? [])")
        let shown = NoteFormat.attributedString(from: note?.content ?? NoteContent())
        let sourceFont = shown.attribute(.font, at: shown.length - 1, effectiveRange: nil) as? NSFont
        check("Envoi depuis Void : la ligne « Source : » est petite et mono, comme les dates", sourceFont == NSFont.monospacedSystemFont(ofSize: NoteFormat.metaSize, weight: .regular)
              && NoteFormat.content(from: shown) == note?.content, "\(String(describing: sourceFont))")
        check("Envoi depuis Void : note ouverte, en tête, dans l'espace affiché, recherche close", note?.id != kept.id && store.notes.first?.id == note?.id
              && note?.space == model.currentSpaceID && note?.folder == nil && model.query.isEmpty && store.notes.count == 2)

        check("Envoi depuis Void : une page sans texte → titre et lien", NoteImport.content(from: URL(string: "voidnotes://new?title=Page&url=https%3A%2F%2Fexample.com%2F")!)?.text == "Page\nSource : https://example.com/")
        check("Envoi depuis Void : sans titre, le texte seul", NoteImport.content(from: URL(string: "voidnotes://new?text=Juste%20%C3%A7a")!) == NoteContent(text: "Juste ça"))
        let odd = NoteImport.content(from: URL(string: "voidnotes://new?title=Deux%0Alignes&text=x%EF%BF%BCy&url=file%3A%2F%2F%2Fetc%2Fpasswd")!)
        check("Envoi depuis Void : titre sur une ligne, pas de pièce jointe fantôme, lien web uniquement", odd?.text == "Deux lignes\nxy", odd?.text ?? "nil")
        let count = store.notes.count
        check("Envoi depuis Void : URL vide ou étrangère ignorée", !model.importNote(from: URL(string: "voidnotes://new")!)
              && !model.importNote(from: URL(string: "voidnotes://delete?title=x")!) && !model.importNote(from: URL(string: "https://example.com/?title=x")!)
              && store.notes.count == count)

        // An image sent by Void: left on the pasteboard, shown under the title, the pasteboard cleared.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(NoteImport.imagePasteboard))
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let withImage = URL(string: "voidnotes://new?title=Chat&url=https%3A%2F%2Fexample.com%2F&image=Mon%20chat.jpeg")!
        check("Envoi d'une image : l'URL est reconnue", model.importNote(from: withImage))
        let imageNote = model.selected
        let file = imageNote.map { store.attachmentsDirectory(of: $0.id).appendingPathComponent("Mon chat.png") }
        check("Envoi d'une image : titre, image sur sa ligne, puis lien", imageNote?.content.text == "Chat\n\u{FFFC}\nSource : https://example.com/"
              && imageNote?.content.runs == [StyleRun(start: 0, length: 5, block: .title), StyleRun(start: 5, length: 1, attachment: "Mon chat.png"),
                                              StyleRun(start: 7, length: 29, block: .source)], "\(imageNote?.content ?? NoteContent())")
        check("Envoi d'une image : copiée dans le dossier de la note, extension de son vrai format",
              file.flatMap { try? Data(contentsOf: $0) } == png, file?.path ?? "nil")
        check("Envoi d'une image : presse-papiers vidé après lecture", pasteboard.pasteboardItems?.isEmpty != false)
        check("Envoi d'une image : sans image sur le presse-papiers, la note sans image",
              model.importNote(from: withImage) && model.selected?.content.text == "Chat\nSource : https://example.com/" && model.selected?.attachments.isEmpty == true)
        pasteboard.clearContents()
        pasteboard.setData(Data("pas une image".utf8), forType: .png)
        check("Envoi d'une image : autre chose qu'une image ignoré",
              model.importNote(from: URL(string: "voidnotes://new?image=x.png")!) == false && pasteboard.pasteboardItems?.isEmpty != false)
        pasteboard.setData(png, forType: .png)
        check("Envoi d'une image : une image seule fait une note, appelée d'après elle",
              model.importNote(from: URL(string: "voidnotes://new?image=%0A")!) && model.selected?.content.text == "\u{FFFC}"
              && model.selected?.title == "Image.png", model.selected?.title ?? "nil")

        // Added to a note already written: `voidnotes://append?note=…` (Void, « Envoyer vers Void Notes » → a note).
        let daily = store.create(space: model.currentSpaceID)
        store.update(daily.id, content: NoteContent(text: "Daily\n☐ Lessive", runs: [StyleRun(start: 0, length: 6, block: .title)]))
        let before = store.notes.count
        let added = URL(string: "voidnotes://append?note=\(daily.id.uuidString)&title=Page&text=Un%20passage&url=https%3A%2F%2Fexample.com%2F")!
        check("Ajout à une note : l'URL est reconnue", NoteImport.target(of: added) == daily.id && model.importNote(from: added))
        let appended = store.note(daily.id)
        check("Ajout à une note : à la fin, après une ligne vide, le titre de la page en intertitre",
              appended?.content.text == "Daily\n☐ Lessive\n\nPage\nUn passage\n\nSource : https://example.com/"
              && appended?.content.runs == [StyleRun(start: 0, length: 6, block: .title), StyleRun(start: 17, length: 5, block: .subheading),
                                            StyleRun(start: 34, length: 29, block: .source)], "\(appended?.content ?? NoteContent())")
        check("Ajout à une note : elle s'ouvre, montrée de nouveau, sans nouvelle note",
              model.selectedID == daily.id && store.notes.count == before && store.revisions[daily.id] == 1 && store.notes.first?.id == daily.id)
        check("Ajout à une note : une note qui n'existe plus → une nouvelle note, rien de perdu",
              model.importNote(from: URL(string: "voidnotes://append?note=\(UUID().uuidString)&title=Seule")!)
              && model.selected?.content == NoteContent(text: "Seule", runs: [StyleRun(start: 0, length: 5, block: .title)]) && store.notes.count == before + 1)
        check("Ajout à une note : le style du dernier paragraphe prend son retour à la ligne",
              NoteImport.appending(NoteContent(text: "x"), to: NoteContent(text: "Titre", runs: [StyleRun(start: 0, length: 5, block: .title)]))
              == NoteContent(text: "Titre\n\nx", runs: [StyleRun(start: 0, length: 6, block: .title)]))
        check("Ajout à une note : à une note vide, le texte seul", NoteImport.appending(NoteContent(text: "x"), to: NoteContent(text: "\n")) == NoteContent(text: "x"))

        // The notes Void can add to: pinned first, then the most recent; no locked one.
        store.update(kept.id, content: NoteContent(text: "Secrète"))
        store.setLocked(true, for: kept.id)
        let listed = NoteDirectory.entries(of: store)
        check("Liste pour Void : la plus récente en tête, pas de note verrouillée, titre et espace",
              listed.first?.title == "Seule" && !listed.contains { $0.id == kept.id } && listed.count <= NoteDirectory.limit
              && listed.first?.space == store.spaces[0].id && listed.first?.folder == nil, "\(listed.map(\.title))")
        // Its tree: the folders that lead to a note, in the order of the list; an empty one left out.
        let work = store.createFolder(named: "Travail", space: model.currentSpaceID)
        let trips = store.createFolder(named: "Voyages", in: work.id, space: model.currentSpaceID)
        _ = store.createFolder(named: "Vide", space: model.currentSpaceID)
        let filed = store.create(in: trips.id, space: model.currentSpaceID)
        store.update(filed.id, content: NoteContent(text: "Lisbonne"))
        store.setPinned(true, for: daily.id)
        let tree = NoteDirectory.payload(of: store)
        let lisbon = tree.notes.first { $0.id == filed.id }
        check("Arborescence pour Void : espaces, dossier et sous-dossier menant à une note, dossier vide absent, épinglée en tête",
              tree.version == 2 && tree.spaces.map(\.id) == store.spaces.map(\.id)
              && tree.folders.map(\.name) == ["Travail", "Voyages"] && tree.folders.last?.parent == work.id
              && lisbon?.folder == trips.id && lisbon?.title == "Lisbonne" && tree.notes.first?.id == daily.id && tree.notes.first?.pinned == true,
              "\(tree.folders.map(\.name)) · \(tree.notes.map(\.title))")
    }

    // MARK: Trash

    private static func trash() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let files = { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }.count }
        let store = NoteStore(directory: directory)
        let folder = store.createFolder(named: "Dossier")
        let kept = store.create(), gone = store.create(in: folder.id), old = store.create()
        store.update(kept.id, content: NoteContent(text: "Gardée"))
        store.update(gone.id, content: NoteContent(text: "Jetée"))
        store.update(old.id, content: NoteContent(text: "Ancienne"))
        let model = NotesModel(store: store, settings: nil)
        model.select(gone.id)
        let modified = store.note(gone.id)!.modified

        model.askToDeleteSelected()
        check("Corbeille : une note supprimée y va, sans confirmation", store.note(gone.id) == nil && store.trashed(gone.id)?.deleted != nil
              && model.pendingDeletion == nil && model.selectedID != gone.id && model.selectedID != nil)
        check("Corbeille : dernière ligne de la liste, repliée", model.rows.last?.id == "trash" && model.visibleNotes.count == 2)
        model.query = "jetée"
        check("Corbeille : la recherche n'y va pas", model.visibleNotes.isEmpty)
        model.query = ""
        model.toggleTrash()
        check("Corbeille : dépliée, ses notes dessous", model.rows.last?.id == gone.id.uuidString && store.daysLeft(store.trashed(gone.id)!) == NoteStore.trashDays)
        check("Corbeille : les jours restants", store.daysLeft(store.trashed(gone.id)!, now: Date.now.addingTimeInterval(86400 * 12.5)) == 18
              && store.daysLeft(store.trashed(gone.id)!, now: Date.now.addingTimeInterval(86400 * 40)) == 0)
        store.flush()
        check("Corbeille : la note garde son fichier", files() == 3)

        var reloaded = NoteStore(directory: directory)
        check("Corbeille : relue dans la corbeille", reloaded.trashed(gone.id)?.title == "Jetée" && reloaded.notes.count == 2)

        model.restore(store.trashed(gone.id)!)
        check("Corbeille : une note restaurée retrouve son dossier, sa date, et s'ouvre", store.note(gone.id)?.folder == folder.id && store.note(gone.id)?.deleted == nil
              && store.note(gone.id)?.modified == modified && model.selectedID == gone.id && store.trash.isEmpty && !model.rows.contains { $0.id == "trash" })

        model.delete(store.note(gone.id)!)
        store.deleteFolder(folder.id)
        store.restore(gone.id)
        check("Corbeille : restaurée sans dossier si le sien n'existe plus", store.note(gone.id) != nil && store.note(gone.id)?.folder == nil)

        model.delete(store.note(gone.id)!)
        model.select(gone.id)
        model.askToDeleteSelected()
        check("Corbeille : supprimer définitivement demande confirmation", model.pendingDeletion?.id == gone.id && store.trashed(gone.id) != nil)
        model.delete(model.pendingDeletion!)
        store.flush()
        check("Corbeille : supprimée définitivement, son fichier aussi", store.trashed(gone.id) == nil && store.note(gone.id) == nil && files() == 2 && model.selectedID != gone.id)

        // Thirty days later.
        store.moveToTrash(old.id, now: Date.now.addingTimeInterval(-86400 * Double(NoteStore.trashDays) - 60))
        store.moveToTrash(kept.id, now: Date.now.addingTimeInterval(-86400 * Double(NoteStore.trashDays - 1)))
        store.flush()
        reloaded = NoteStore(directory: directory)
        check("Corbeille : après 30 jours, la note disparaît au lancement ; avant, elle reste", reloaded.trashed(old.id) == nil && reloaded.trashed(kept.id) != nil
              && files() == 1, "\(reloaded.trash.map(\.title))")
        model.emptyTrash()
        check("Corbeille : vidée", store.trash.isEmpty && model.confirmingEmptyTrash == false)
        let empty = store.create()
        store.moveToTrash(empty.id)
        check("Corbeille : une note vide n'y va pas", store.trash.isEmpty && store.note(empty.id) == nil)
    }

    // MARK: Archive

    private static func archive() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = NoteStore(directory: directory)
        let folder = store.createFolder(named: "Dossier")
        let kept = store.create(), old = store.create(in: folder.id), other = store.create()
        store.update(kept.id, content: NoteContent(text: "Gardée"))
        store.update(old.id, content: NoteContent(text: "Ancienne\nimpôts"))
        store.update(other.id, content: NoteContent(text: "Autre"))
        let model = NotesModel(store: store, settings: nil)
        model.open(old.id)
        let modified = store.note(old.id)!.modified
        let ids = { model.rows.map(\.id) }

        model.toggleArchived()
        check("Archives : une note archivée quitte son dossier dans la liste, sans changer de date ; la voisine s'ouvre", store.note(old.id)?.archived == true
              && store.note(old.id)?.modified == modified && store.note(old.id)?.folder == folder.id && !ids().contains(old.id.uuidString)
              && model.selectedID != old.id && model.selectedID != nil, "\(ids())")
        check("Archives : une ligne à part, après les dossiers et les notes, repliée", ids().last == "archive" && model.visibleNotes.count == 2)
        model.toggleAllNotes()
        check("Archives : absente de « Toutes les notes »", !ids().contains("all-\(old.id.uuidString)") && ids().contains("all-\(kept.id.uuidString)"))
        model.toggleAllNotes()
        model.toggleArchive()
        check("Archives : dépliée, ses notes dessous, une seule fois", ids().last == old.id.uuidString && ids().filter { $0 == old.id.uuidString }.count == 1)
        model.query = "impôts"
        check("Archives : la recherche les trouve", model.visibleNotes.map(\.id) == [old.id])
        model.query = ""
        model.open(old.id)
        store.update(old.id, content: NoteContent(text: "Ancienne\nimpôts 2025"))
        check("Archives : une note archivée s'écrit toujours, et reste archivée", store.note(old.id)?.archived == true && store.note(old.id)?.content.text.hasSuffix("2025") == true)
        store.moveToTrash(other.id)
        check("Archives : avant la corbeille", ids().firstIndex(of: "archive")! < ids().firstIndex(of: "trash")! && ids().last == "trash", "\(ids())")
        store.flush()
        let file = (try? String(contentsOf: directory.appendingPathComponent("\(old.id.uuidString).json"), encoding: .utf8)) ?? ""
        let reloaded = NoteStore(directory: directory)
        check("Archives : enregistrée et relue", file.contains("\"archived\" : true") && reloaded.note(old.id)?.archived == true && reloaded.note(kept.id)?.archived == false)
        let again = NotesModel(store: reloaded, settings: nil)
        check("Archives : au lancement, la note ouverte n'est pas prise dans les archives", again.selectedID == kept.id)

        model.toggleArchived()
        check("Archives : désarchivée, la note revient dans son dossier, déplié, et reste ouverte", store.note(old.id)?.archived == false && model.selectedID == old.id
              && ids().contains(old.id.uuidString) && !ids().contains("archive") && model.expanded.contains(folder.id), "\(ids())")
        model.open(kept.id)
        model.toggleSelection(old.id, row: old.id.uuidString)
        model.toggleArchived()
        check("Archives : la sélection s'archive d'un coup", store.note(old.id)?.archived == true && store.note(kept.id)?.archived == true && model.selection.isEmpty
              && model.selectedID == nil, "\(String(describing: model.selected?.title))")
        model.delete(store.note(old.id)!)
        model.restore(store.trashed(old.id)!)
        check("Archives : restaurée de la corbeille, la note retourne aux archives", store.note(old.id)?.archived == true && model.selectedID == old.id && model.showsArchive)
        let empty = store.create()
        store.setArchived(true, for: empty.id)
        check("Archives : une note vide ne s'archive pas", store.note(empty.id)?.archived == false)
    }

    // MARK: Pin

    private static func pin() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = NoteStore(directory: directory)
        let recipes = store.createFolder(named: "Recettes")
        let desserts = store.createFolder(named: "Desserts", in: recipes.id)
        let tart = store.create(in: desserts.id), shopping = store.create(), ideas = store.create()
        store.update(tart.id, content: NoteContent(text: "Tarte aux pommes\nbeurre"))
        store.update(shopping.id, content: NoteContent(text: "Courses\nbeurre"))
        store.update(ideas.id, content: NoteContent(text: "Idées\nbeurre"))
        let model = NotesModel(store: store, settings: nil)
        let ids = { model.rows.map(\.id) }
        let modified = store.note(tart.id)!.modified

        model.setPinned(true, for: tart.id)
        check("Épingler : la note passe en tête de la liste, avant « Toutes les notes », sans changer de date", ids().first == tart.id.uuidString && ids()[1] == "all"
              && store.note(tart.id)?.modified == modified, "\(ids())")
        model.toggle(recipes.id)
        model.toggle(desserts.id)
        check("Épingler : la note n'est plus montrée dans son dossier", ids().filter { $0 == tart.id.uuidString }.count == 1 && store.note(tart.id)?.folder == desserts.id, "\(ids())")
        model.toggleAllNotes()
        check("Épingler : la première de « Toutes les notes »", ids()[2] == "all-\(tart.id.uuidString)" && Set(ids()).count == ids().count, "\(ids())")
        model.toggleAllNotes()
        model.query = "beurre"
        check("Épingler : en tête des résultats de la recherche", model.visibleNotes.map(\.id) == [tart.id, ideas.id, shopping.id])
        model.query = ""

        store.flush()
        let file = (try? String(contentsOf: directory.appendingPathComponent("\(tart.id.uuidString).json"), encoding: .utf8)) ?? ""
        let reloaded = NoteStore(directory: directory)
        check("Épingler : enregistrée et relue", file.contains("\"pinned\" : true") && reloaded.note(tart.id)?.pinned == true && reloaded.note(ideas.id)?.pinned == false)

        model.setPinned(false, for: tart.id)
        check("Épingler : désépinglée, la note revient dans son dossier", ids().first == "all" && ids().contains(tart.id.uuidString) && store.note(tart.id)?.pinned == false, "\(ids())")
        model.setPinned(true, for: tart.id)
        model.archive(tart.id)
        check("Épingler : archiver une note la désépingle", store.note(tart.id)?.pinned == false && ids().first == "all")
        store.setPinned(true, for: tart.id)
        check("Épingler : une note archivée ne s'épingle pas", store.note(tart.id)?.pinned == false)
        model.unarchive(tart.id)

        model.open(shopping.id)
        model.toggleSelection(ideas.id, row: ideas.id.uuidString)
        model.togglePinned()
        check("Épingler : la sélection s'épingle d'un coup", store.note(shopping.id)?.pinned == true && store.note(ideas.id)?.pinned == true && model.selection.isEmpty)
        model.toggleSelection(shopping.id, row: shopping.id.uuidString)
        model.toggleSelection(ideas.id, row: ideas.id.uuidString)
        model.pinSelection()
        check("Épingler : toute épinglée, la sélection se désépingle", store.note(shopping.id)?.pinned == false && store.note(ideas.id)?.pinned == false)
        let empty = store.create()
        store.setPinned(true, for: empty.id)
        check("Épingler : une note vide ne s'épingle pas", store.note(empty.id)?.pinned == false)
        store.delete(empty.id)

        // The search reads the names of the folders a note is in.
        model.query = "desserts"
        check("Recherche : le nom du dossier trouve ses notes", model.visibleNotes.map(\.id) == [tart.id])
        model.query = "recettes"
        check("Recherche : le nom d'un dossier trouve les notes de ses sous-dossiers", model.visibleNotes.map(\.id) == [tart.id])
        model.query = "RECETTE pommes"
        check("Recherche : mots pris dans le dossier et dans le texte", model.visibleNotes.map(\.id) == [tart.id])
        model.query = "recettes courses"
        check("Recherche : tous les mots requis, dossier compris", model.visibleNotes.isEmpty)
        store.setLocked(true, for: tart.id)
        model.query = "desserts"
        check("Recherche : une note verrouillée se trouve par son dossier, pas par son texte", model.visibleNotes.map(\.id) == [tart.id])
        model.query = "pommes"
        check("Recherche : verrouillée, son titre la trouve toujours", model.visibleNotes.map(\.id) == [tart.id])
        model.query = "beurre"
        check("Recherche : verrouillée, son texte ne la trouve pas", !model.visibleNotes.contains { $0.id == tart.id })
        model.query = ""
    }

    // MARK: Lock

    private static func lock() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = NoteStore(directory: directory)
        let secret = store.create(), other = store.create()
        store.update(secret.id, content: NoteContent(text: "Codes\nLe coffre : 4812"))
        store.update(other.id, content: NoteContent(text: "Autre"))
        let model = NotesModel(store: store, settings: nil)
        // Touch ID, played by the test: `answer` is what it says, `pending` holds it back.
        var answer = true, asked = 0, hold = false
        var pending: (@MainActor (Bool) -> Void)?
        model.canAuthenticate = { true }
        model.authenticate = { _, completion in
            asked += 1
            if hold { pending = completion } else { completion(answer) }
        }
        model.select(secret.id)
        let modified = store.note(secret.id)!.modified

        model.lock(secret.id)
        check("Verrou : verrouiller cache la note aussitôt, sans rien demander ni changer sa date", store.note(secret.id)?.locked == true && model.isConcealed(store.note(secret.id)!)
              && asked == 0 && store.note(secret.id)?.modified == modified)
        check("Verrou : le titre reste dans la liste, pas l'aperçu", store.note(secret.id)?.title == "Codes" && store.note(secret.id)?.preview == "")
        model.query = "coffre"
        let byText = model.visibleNotes.count
        model.query = "codes"
        check("Verrou : la recherche ne lit que le titre d'une note verrouillée", byText == 0 && model.visibleNotes.map(\.id) == [secret.id])
        model.query = ""

        answer = false
        model.unlock(secret.id)
        check("Verrou : Touch ID refusé, la note reste cachée", asked == 1 && model.isConcealed(store.note(secret.id)!))
        answer = true
        model.toggleLock()
        check("Verrou : Touch ID accepté, la note s'affiche", asked == 2 && !model.isConcealed(store.note(secret.id)!) && store.note(secret.id)?.locked == true)
        model.unlock(secret.id)
        check("Verrou : une note déjà ouverte ne redemande rien", asked == 2)
        model.toggleLock()
        check("Verrou : ⇧⌘L sur une note ouverte la cache de nouveau", model.isConcealed(store.note(secret.id)!) && asked == 2)
        model.unlock(secret.id)
        model.select(other.id)
        model.select(secret.id)
        check("Verrou : quitter la note la reverrouille", model.isConcealed(store.note(secret.id)!))
        model.unlock(secret.id)
        model.relock()
        check("Verrou : la mise en veille de l'écran reverrouille", model.isConcealed(store.note(secret.id)!))

        hold = true
        model.unlock(secret.id)
        model.select(other.id)
        pending?(true)
        model.select(secret.id)
        check("Verrou : une réponse arrivée après avoir changé de note n'ouvre rien", model.isConcealed(store.note(secret.id)!))
        hold = false

        store.flush()
        let file = (try? String(contentsOf: directory.appendingPathComponent("\(secret.id.uuidString).json"), encoding: .utf8)) ?? ""
        let reloaded = NoteStore(directory: directory)
        check("Verrou : enregistré et relu", file.contains("\"locked\" : true") && reloaded.note(secret.id)?.locked == true && reloaded.note(other.id)?.locked == false
              && reloaded.note(secret.id)?.content.text == "Codes\nLe coffre : 4812")
        let otherFile = (try? String(contentsOf: directory.appendingPathComponent("\(other.id.uuidString).json"), encoding: .utf8)) ?? "locked"
        check("Verrou : rien d'écrit pour une note sans verrou", !otherFile.contains("locked"))

        model.delete(store.note(secret.id)!)
        check("Verrou : à la corbeille, la note reste verrouillée", store.trashed(secret.id)?.locked == true && model.isConcealed(store.trashed(secret.id)!))
        model.restore(store.trashed(secret.id)!)
        check("Verrou : restaurée, elle l'est toujours", model.selectedID == secret.id && model.isConcealed(store.note(secret.id)!))

        asked = 0
        answer = false
        model.removeLock(secret.id)
        check("Verrou : retirer le verrou d'une note cachée passe par Touch ID", asked == 1 && store.note(secret.id)?.locked == true)
        answer = true
        model.removeLock(secret.id)
        check("Verrou : retiré, la note se lit et se cherche comme avant", store.note(secret.id)?.locked == false && !model.isConcealed(store.note(secret.id)!)
              && store.note(secret.id)?.preview == "Le coffre : 4812" && store.note(secret.id)?.matches(["coffre"]) == true)
        model.lock(secret.id)
        model.unlock(secret.id)
        asked = 0
        model.removeLock(secret.id)
        check("Verrou : retiré sans question d'une note déjà ouverte", asked == 0 && store.note(secret.id)?.locked == false)

        model.newNote()
        let blank = model.selectedID!
        model.lock(blank)
        check("Verrou : une note vide ne se verrouille pas", store.note(blank)?.locked == false)
        model.canAuthenticate = { false }
        model.lock(secret.id)
        check("Verrou : sans Touch ID ni mot de passe, la note n'est pas verrouillée", store.note(secret.id)?.locked == false && store.errorMessage != nil)
    }

    // MARK: Attachments

    private static func attachments() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)/notes")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = NoteStore(directory: directory)
        let note = store.create()
        let folder = store.attachmentsDirectory(of: note.id)
        let files = { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

        // A picture, 120 × 80.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let source = directory.deletingLastPathComponent().appendingPathComponent("Billets.pdf")
        try? FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("%PDF-1.4".utf8).write(to: source)

        let image = store.attach(png, named: "Image.png", to: note.id), second = store.attach(png, named: "Image.png", to: note.id)
        let pdf = store.attach(source, to: note.id)
        check("Pièces jointes : copiées dans le dossier de la note, sans écraser un nom pris", image == "Image.png" && second == "Image 2.png" && pdf == "Billets.pdf"
              && files() == ["Billets.pdf", "Image 2.png", "Image.png"], "\(files())")

        let view = editor()
        view.attachmentsDirectory = folder
        type("Photos", in: view)
        step(view) { view.insertAttachments(["Image.png", "Billets.pdf"], at: view.selectedRange()) }
        type("après", in: view)
        let content = view.content
        check("Pièces jointes : chacune sur sa ligne, le texte reprend dessous", content.text == "Photos\n\u{FFFC}\n\u{FFFC}\naprès"
              && content.runs.compactMap(\.attachment) == ["Image.png", "Billets.pdf"] && content.runs.filter { $0.attachment != nil }.allSatisfy { $0.length == 1 },
              "\(content)")
        let shown = view.textStorage!
        let cell = (shown.attribute(.attachment, at: 7, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? NoteAttachmentCell
        let card = (shown.attribute(.attachment, at: 9, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? NoteAttachmentCell
        let container = view.textContainer!
        let wide = cell?.cellFrame(for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 600, height: 20), glyphPosition: .zero, characterIndex: 7).size
        let narrow = cell?.cellFrame(for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 100, height: 20), glyphPosition: .zero, characterIndex: 7).size
        check("Pièces jointes : une image à sa taille, réduite quand la colonne est étroite", wide == NSSize(width: 120, height: 80)
              && (narrow?.width ?? 999) <= 100 && abs((narrow?.width ?? 0) / (narrow?.height ?? 1) - 1.5) < 0.05, "\(String(describing: wide)) \(String(describing: narrow))")
        check("Pièces jointes : un autre fichier en carte", card?.cellFrame(for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 600, height: 20),
                                                                         glyphPosition: .zero, characterIndex: 9).height == NoteAttachmentCell.cardSize.height)
        check("Pièces jointes : le texte tapé après n'est pas une pièce jointe", shown.attribute(.attachment, at: shown.length - 1, effectiveRange: nil) == nil)
        let again = NoteFormat.attributedString(from: content, attachments: folder)
        check("Pièces jointes : aller-retour sans perte", NoteFormat.content(from: again) == content && again.attribute(.attachment, at: 7, effectiveRange: nil) != nil)
        // The five letters typed after them, then the files.
        for _ in 0..<6 { view.undoManager?.undo() }
        check("Pièces jointes : annulables", view.content.runs.allSatisfy { $0.attachment == nil } && !view.string.contains("\u{FFFC}"), view.string.debugDescription)

        store.update(note.id, content: NoteContent(text: "\u{FFFC}", runs: [StyleRun(start: 0, length: 1, attachment: "Billets.pdf")]))
        check("Pièces jointes : une note qui n'a qu'un fichier n'est pas vide et porte son nom", store.note(note.id)?.isBlank == false && store.note(note.id)?.title == "Billets.pdf")
        store.flush()
        let reloaded = NoteStore(directory: directory)
        check("Pièces jointes : relues ; les fichiers qui ne servent plus sont retirés au lancement", reloaded.note(note.id)?.attachments == ["Billets.pdf"]
              && files() == ["Billets.pdf"], "\(files())")

        // The album of images.
        let picture = directory.deletingLastPathComponent().appendingPathComponent("Plage.png")
        try? png.write(to: picture)
        let album = reloaded.create()
        let albumFolder = reloaded.attachmentsDirectory(of: album.id)
        let albumFiles = { ((try? FileManager.default.contentsOfDirectory(atPath: albumFolder.path)) ?? []).sorted() }
        reloaded.addPhotos([picture, picture], to: album.id)
        reloaded.addPhoto(png, named: "Image.png", to: album.id)
        check("Album : les images sont copiées avec la note, dans l'ordre d'ajout", reloaded.note(album.id)?.photos == ["Plage.png", "Plage 2.png", "Image.png"]
              && albumFiles() == ["Image.png", "Plage 2.png", "Plage.png"], "\(albumFiles())")
        check("Album : une note qui n'a que des images n'est pas vide, et reste sans texte", reloaded.note(album.id)?.isBlank == false
              && reloaded.note(album.id)?.content.text == "" && reloaded.notes.first?.id == album.id)
        reloaded.removePhoto("Plage 2.png", from: album.id)
        check("Album : une image retirée garde son fichier jusqu'au lancement suivant", reloaded.note(album.id)?.photos == ["Plage.png", "Image.png"] && albumFiles().count == 3)
        reloaded.flush()
        let third = NoteStore(directory: directory)
        check("Album : relu ; le fichier de l'image retirée est parti", third.note(album.id)?.photos == ["Plage.png", "Image.png"]
              && albumFiles() == ["Image.png", "Plage.png"] && third.note(note.id)?.photos == [], "\(albumFiles())")
        let routed = editor()
        var toAlbum: [URL] = [], toText: [URL] = []
        routed.addPhotos = { toAlbum += $0 }
        routed.attachFile = { toText.append($0); return $0.lastPathComponent }
        step(routed) { routed.attach(files: [picture, source]) }
        check("Album : une image jointe va dans l'album, un autre fichier dans le texte", toAlbum == [picture] && toText == [source]
              && routed.content.runs.compactMap(\.attachment) == ["Billets.pdf"], "\(routed.content)")

        store.moveToTrash(note.id)
        check("Pièces jointes : gardées tant que la note est dans la corbeille", files() == ["Billets.pdf"])
        store.delete(note.id)
        check("Pièces jointes : supprimées avec la note", !FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Synchronisation

    /// Two devices, each with its own notes, and one shared folder between them.
    private static func sync() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString)")
        let suites = ["selftest-sync-a-\(UUID().uuidString)", "selftest-sync-b-\(UUID().uuidString)", "selftest-sync-c-\(UUID().uuidString)"]
        defer {
            try? FileManager.default.removeItem(at: root)
            for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
        let cloud = root.appendingPathComponent("cloud"), file = cloud.appendingPathComponent(SyncFile.fileName)
        try? FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let mac = NoteStore(directory: root.appendingPathComponent("mac/notes")), phone = NoteStore(directory: root.appendingPathComponent("phone/notes"))
        let macSync = SyncEngine(store: mac, folder: cloud, defaults: UserDefaults(suiteName: suites[0]))
        let phoneSync = SyncEngine(store: phone, folder: cloud, defaults: UserDefaults(suiteName: suites[1]))
        /// Both devices, one after the other, until what the first one wrote is read by both.
        func both() async {
            await macSync.sync(reason: "test")
            await phoneSync.sync(reason: "test")
            await macSync.sync(reason: "test")
        }
        func snapshot() -> SyncFile? { (try? Data(contentsOf: file)).flatMap { try? SyncCoding.decoder().decode(SyncFile.self, from: $0) } }

        // The Mac has notes, a folder and a file; the phone is new.
        let work = mac.createFolder(named: "Travail")
        let first = mac.create(in: work.id)
        mac.update(first.id, content: NoteContent(text: "Réunion\nLundi 10 h", runs: [StyleRun(start: 0, length: 8, block: .title)]))
        mac.addPhoto(Data("image".utf8), named: "Photo.png", to: first.id)
        let blank = phone.create()
        await macSync.sync(reason: "test")
        check("Synchro : le premier appareil écrit le fichier du dossier", snapshot()?.data.notes.map(\.id) == [first.id] && macSync.status == .upToDate, "\(macSync.status)")
        check("Synchro : un premier envoi vers un dossier vide ne met rien de côté", !FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Backups").path))
        check("Synchro : les fichiers joints sont copiés dans le dossier", FileManager.default.fileExists(atPath: SyncAttachments.directory(of: first.id, in: cloud).appendingPathComponent("Photo.png").path))
        let written = try? Data(contentsOf: file)
        await macSync.sync(reason: "test")
        check("Synchro : sans changement, le fichier n'est pas réécrit", (try? Data(contentsOf: file)) == written)

        await phoneSync.sync(reason: "test")
        check("Synchro : le second appareil reçoit la note, son dossier et sa mise en forme", phone.note(first.id)?.content == mac.note(first.id)?.content
              && phone.note(first.id)?.folder == work.id && phone.folders.map(\.name) == ["Travail"], "\(phone.notes.map(\.title))")
        check("Synchro : « Personnel » des deux appareils ne fait qu'un espace", phone.spaces.map(\.id) == mac.spaces.map(\.id) && phone.spaces.count == 1 && phone.note(blank.id)?.space == mac.spaces[0].id, "\(phone.spaces.map(\.name))")
        check("Synchro : la note encore vide de l'appareil reste", phone.note(blank.id) != nil)
        check("Synchro : les fichiers joints arrivent, la note est réaffichée", FileManager.default.fileExists(atPath: phone.attachmentsDirectory(of: first.id).appendingPathComponent("Photo.png").path)
              && phone.note(first.id)?.photos == ["Photo.png"] && (phone.revisions[first.id] ?? 0) > 0)
        check("Synchro : la note reçue est écrite sur l'appareil", NoteStore(directory: phone.directory).note(first.id)?.title == "Réunion")

        // A change on the phone reaches the Mac.
        await sleep(0.01)
        phone.update(first.id, content: NoteContent(text: "Réunion\nMardi 14 h"))
        let second = phone.create()
        phone.update(second.id, content: NoteContent(text: "Courses"))
        await both()
        check("Synchro : une modification et une nouvelle note reviennent", mac.note(first.id)?.content.text == "Réunion\nMardi 14 h" && mac.note(second.id)?.title == "Courses"
              && (mac.revisions[first.id] ?? 0) == 1 && mac.revisions[second.id] == nil, "\(mac.notes.map(\.content.text))")

        // The same note changed on both: the last change wins, the other is saved.
        await sleep(0.01)
        phone.update(first.id, content: NoteContent(text: "Réunion\nau téléphone"))
        await sleep(0.01)
        mac.update(first.id, content: NoteContent(text: "Réunion\nsur le Mac"))
        mac.update(second.id, content: NoteContent(text: "Courses\nPain"))
        await both()
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Backups").path)) ?? []
        check("Synchro : modifiée des deux côtés, la dernière modification l'emporte", mac.note(first.id)?.content.text == "Réunion\nsur le Mac" && phone.note(first.id)?.content.text == "Réunion\nsur le Mac")
        check("Synchro : la version écartée est sauvegardée dans « Backups »", backups.count == 1 && backups[0].hasSuffix("local.json"), "\(backups)")
        check("Synchro : les autres notes modifiées ailleurs sont gardées", phone.note(second.id)?.content.text == "Courses\nPain")

        // Filing, archiving, pinning and locking don't change a note's date: they are synchronised all the same.
        await sleep(0.01)
        let home = phone.createFolder(named: "Maison")
        phone.move(second.id, to: home.id)
        phone.setArchived(true, for: first.id)
        phone.setPinned(true, for: second.id)
        mac.renameFolder(work.id, to: "Bureau")
        let perso = mac.createSpace(named: "Loisirs", icon: "leaf")
        await both()
        check("Synchro : rangement, archivage, épinglage, dossiers et espaces", mac.note(second.id)?.folder == home.id && mac.note(first.id)?.archived == true
              && mac.note(second.id)?.pinned == true
              && Set(phone.folders.map(\.name)) == ["Bureau", "Maison"] && phone.spaces.map(\.name) == ["Personnel", "Loisirs"] && phone.space(perso.id) != nil,
              "\(phone.folders.map(\.name)) \(phone.spaces.map(\.name))")
        check("Synchro : ranger une note ne change pas sa date", mac.note(second.id)?.modified == phone.note(second.id)?.modified)

        // Trash, then deletion for good.
        phone.moveToTrash(second.id)
        await both()
        check("Synchro : une note mise à la corbeille y va partout", mac.trashed(second.id) != nil && mac.note(second.id) == nil)
        mac.restore(second.id)
        await both()
        check("Synchro : restaurée, elle revient partout", phone.note(second.id) != nil && phone.trash.isEmpty)
        mac.delete(first.id)
        await both()
        check("Synchro : une note supprimée définitivement l'est partout, avec ses fichiers", phone.note(first.id) == nil
              && !FileManager.default.fileExists(atPath: phone.attachmentsDirectory(of: first.id).path)
              && !FileManager.default.fileExists(atPath: SyncAttachments.directory(of: first.id, in: cloud).path)
              && !FileManager.default.fileExists(atPath: phone.directory!.appendingPathComponent("\(first.id.uuidString).json").path))

        // A note deleted on one device and written on the other since: it is kept.
        phone.delete(second.id)
        await sleep(0.01)
        mac.update(second.id, content: NoteContent(text: "Courses\nPain, lait"))
        await both()
        await phoneSync.sync(reason: "test")
        check("Synchro : supprimée ici, modifiée ensuite ailleurs : la note est gardée", phone.note(second.id)?.content.text == "Courses\nPain, lait" && mac.note(second.id) != nil)
        mac.deleteFolder(home.id)
        mac.deleteSpace(perso.id)
        await both()
        check("Synchro : dossier et espace supprimés", phone.folders.map(\.name) == ["Bureau"] && phone.spaces.count == 1 && phone.note(second.id)?.folder == nil)
        check("Synchro : les deux appareils ont les mêmes notes", SyncMerge.hash(SyncPayload(mac)) == SyncMerge.hash(SyncPayload(phone)))

        // A third device with notes of its own joins: everything is put together.
        let tablet = NoteStore(directory: root.appendingPathComponent("tablet/notes"))
        let own = tablet.create()
        tablet.update(own.id, content: NoteContent(text: "Idées"))
        let tabletSync = SyncEngine(store: tablet, folder: cloud, defaults: UserDefaults(suiteName: suites[2]))
        await tabletSync.sync(reason: "test")
        await both()
        check("Synchro : un appareil qui a déjà des notes les ajoute aux autres", Set(mac.notes.map(\.title)) == ["Courses", "Idées"] && Set(tablet.notes.map(\.title)) == ["Courses", "Idées"]
              && tablet.spaces.map(\.id) == mac.spaces.map(\.id), "\(mac.notes.map(\.title)) \(tablet.notes.map(\.title))")

        // The window follows what another device did.
        let model = NotesModel(store: phone, settings: nil)
        model.select(own.id)
        mac.delete(own.id)
        await both()
        model.storeChanged()
        check("Synchro : la note ouverte supprimée ailleurs laisse la place à une autre", model.selectedID == second.id && model.selected != nil)

        // A file that doesn't read, or that a later version wrote, is never overwritten.
        let good = try? Data(contentsOf: file)
        try? Data("{ pas du JSON".utf8).write(to: file)
        mac.update(second.id, content: NoteContent(text: "Courses\nPain, lait, œufs"))
        await macSync.sync(reason: "test")
        check("Synchro : un fichier illisible n'est pas écrasé", (try? Data(contentsOf: file)) == Data("{ pas du JSON".utf8) && macSync.status != .upToDate, "\(macSync.status)")
        var later = good.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        later["noteFormat"] = NoteStore.formatVersion + 1
        let laterData = try? JSONSerialization.data(withJSONObject: later)
        try? laterData?.write(to: file)
        await macSync.sync(reason: "test")
        check("Synchro : un fichier d'une version ultérieure n'est pas écrasé", (try? Data(contentsOf: file)) == laterData && macSync.status == .outdated, "\(macSync.status)")
        try? good?.write(to: file)
        await both()
        check("Synchro : le fichier rétabli, la modification en attente part", phone.note(second.id)?.content.text == "Courses\nPain, lait, œufs" && macSync.status == .upToDate)
        // Quitting: what is left is sent, without waiting longer than allowed.
        mac.update(second.id, content: NoteContent(text: "Courses\nPain, lait, œufs, café"))
        let unsent = macSync.hasUnsentChanges
        let quitStart = ContinuousClock.now
        await macSync.syncBeforeExit(within: .seconds(5))
        check("Synchro : en quittant, ce qui reste à envoyer part", unsent && !macSync.hasUnsentChanges
              && snapshot()?.data.notes.contains { $0.text == "Courses\nPain, lait, œufs, café" } == true && ContinuousClock.now - quitStart < .seconds(5))

        // The merge alone: symmetric, and a deletion wins over an earlier change only.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var a = SyncPayload(), b = SyncPayload()
        let x = NoteFile(Note(created: t0, modified: t0, content: NoteContent(text: "x")))
        var y = x
        y.text = "y"
        a.notes = [x]; a.modifiedAt[x.id.uuidString] = t0
        b.notes = [y]; b.modifiedAt[x.id.uuidString] = t0.addingTimeInterval(5)
        // Dates read and written again stay as they are, to the millisecond — written by the note
        // files or by the shared folder.
        var drifts = 0
        for index in 0..<5000 {
            let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1234.567_891 + Double(index % 13) * 0.000_317)
            let once = SyncCoding.string(from: date)
            var written = once
            for _ in 0..<3 {
                written = (try? SyncCoding.decoder().decode([Date].self, from: Data("[\"\(written)\"]".utf8)))?.first.map(SyncCoding.string(from:)) ?? ""
            }
            if written != once { drifts += 1 }
        }
        check("Fusion : une date relue puis réécrite ne bouge pas", drifts == 0, "\(drifts) dates sur 5000")
        let kept = NoteStore(directory: root.appendingPathComponent("dates/notes"))
        for index in 0..<40 {
            let note = kept.create()
            kept.update(note.id, content: NoteContent(text: "Note \(index)"))
        }
        kept.flush()
        let reread = NoteStore(directory: root.appendingPathComponent("dates/notes"))
        check("Fusion : une note relue depuis son fichier a la même empreinte", kept.notes.allSatisfy { note in
            reread.note(note.id).map { SyncMerge.hash(NoteFile($0)) == SyncMerge.hash(NoteFile(note)) } == true
        })
        check("Fusion : symétrique", SyncMerge.merge(a, b) == SyncMerge.merge(b, a) && SyncMerge.merge(a, b).notes.map(\.text) == ["y"])
        var gone = SyncPayload()
        gone.deletedAt[x.id.uuidString] = t0.addingTimeInterval(2)
        check("Fusion : une suppression l'emporte sur une modification plus ancienne, pas sur une plus récente",
              SyncMerge.merge(a, gone, now: t0).notes.isEmpty && SyncMerge.merge(b, gone, now: t0).notes.map(\.text) == ["y"] && SyncMerge.merge(b, gone, now: t0).deletedAt.isEmpty)
        check("Fusion : un élément absent d'un côté sans y avoir été supprimé est gardé", SyncMerge.merge(a, SyncPayload()).notes.count == 1)

        // Backups older than a month go; the others, and whatever else is in the folder, stay.
        let shelf = root.appendingPathComponent("shelf"), oldBackups = shelf.appendingPathComponent("Backups")
        try? FileManager.default.createDirectory(at: oldBackups, withIntermediateDirectories: true)
        let recent = Date.now.addingTimeInterval(-2 * 86400).formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let names = ["void-notes-data 2020-01-01 101010 local.json", ".void-notes-data 2020-01-02 101010 conflict-iPhone.json.icloud",
                     "void-notes-data \(recent) 101010 local.json", "à garder 2020-01-01.txt"]
        for name in names { try? Data("{}".utf8).write(to: oldBackups.appendingPathComponent(name)) }
        let pruned = SyncEngine.pruneBackups(in: shelf)
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: oldBackups.path)) ?? [])
        check("Synchro : les sauvegardes de plus de \(SyncEngine.backupDays) jours sont retirées, pas les autres", pruned == 2 && left == Set(names.suffix(2)), "\(left)")
    }

    // MARK: Saved format

    private static func format() {
        let content = NoteContent(text: "Titre\nun gras ital\n• puce\ncitation", runs: [
            StyleRun(start: 0, length: 6, block: .title),
            StyleRun(start: 9, length: 4, bold: true),
            StyleRun(start: 14, length: 4, italic: true),
            StyleRun(start: 26, length: 8, block: .quote),
        ])
        let text = NoteFormat.attributedString(from: content)
        check("Format : aller-retour sans perte", NoteFormat.content(from: text) == content, "\(NoteFormat.content(from: text).runs)")
        let titleFont = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = text.attribute(.font, at: 9, effectiveRange: nil) as? NSFont
        let italicFont = text.attribute(.font, at: 14, effectiveRange: nil) as? NSFont
        check("Format : le titre est plus grand", titleFont?.pointSize == NoteFormat.size(.title))
        check("Format : gras et italique dans la police système", boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true
              && italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        let bullet = text.attribute(.paragraphStyle, at: 20, effectiveRange: nil) as? NSParagraphStyle
        check("Format : retrait des lignes d'une liste", (bullet?.headIndent ?? 0) > 0)
        let rich = NoteContent(text: "Titre\n---\nléger moyen jaune", runs: [
            StyleRun(start: 0, length: 6, block: .title),
            StyleRun(start: 6, length: 4, block: .divider),
            StyleRun(start: 10, length: 5, weight: .light),
            StyleRun(start: 16, length: 5, weight: .medium, highlight: true),
            StyleRun(start: 22, length: 5, highlight: true),
        ])
        let richText = NoteFormat.attributedString(from: rich)
        check("Format : séparateur, graisses et surlignage, aller-retour sans perte", NoteFormat.content(from: richText) == rich, "\(NoteFormat.content(from: richText).runs)")
        check("Format : le surlignage est un fond, la couleur du texte ne change pas", richText.attribute(.backgroundColor, at: 22, effectiveRange: nil) != nil
              && richText.attribute(.backgroundColor, at: 10, effectiveRange: nil) == nil
              && richText.attribute(.foregroundColor, at: 22, effectiveRange: nil) as? NSColor == Theme.primaryTextNS)
        let light = richText.attribute(.font, at: 10, effectiveRange: nil) as? NSFont, medium = richText.attribute(.font, at: 16, effectiveRange: nil) as? NSFont
        check("Format : graisses appliquées", light == NSFont.systemFont(ofSize: NoteFormat.bodySize, weight: .light)
              && medium == NSFont.systemFont(ofSize: NoteFormat.bodySize, weight: .medium))
        let firstStyle = richText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let nextStyle = richText.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle
        check("Format : la place des dates sous le premier paragraphe seulement", (firstStyle?.paragraphSpacing ?? 0) >= NoteFormat.metaSpace
              && (nextStyle?.paragraphSpacing ?? 99) < NoteFormat.metaSpace)
        let broken = NoteFormat.attributedString(from: NoteContent(text: "x\n--- non", runs: [StyleRun(start: 2, length: 7, block: .divider)]))
        check("Format : un séparateur avec du texte redevient du texte", NoteFormat.content(from: broken).runs.isEmpty)
        check("Format : un séparateur n'apparaît pas dans l'aperçu", Note(content: rich).preview == "léger moyen jaune")
        let meta = NoteDate.meta(created: Date(timeIntervalSince1970: 0), modified: .now)
        check("Dates : création sans heure, modification avec", meta.hasPrefix("Créée ") && meta.contains("1970  ·  modifiée aujourd'hui à ")
              && meta.components(separatedBy: "·").first?.contains(":") == false && meta.components(separatedBy: "·").last?.contains(":") == true, meta)
        let outside = NoteFormat.attributedString(from: NoteContent(text: "abc", runs: [StyleRun(start: 2, length: 50, bold: true)]))
        check("Format : mise en forme hors du texte tolérée", NoteFormat.content(from: outside).runs == [StyleRun(start: 2, length: 1, bold: true)])
    }

    // MARK: Checked items going down

    private static func checklistSort() async {
        func sorted(_ text: String, at location: Int) -> String? {
            let string = NSMutableAttributedString(string: text)
            guard let sort = ChecklistSort(string, around: location) else { return nil }
            string.replaceCharacters(in: sort.range, with: sort.text)
            return string.string
        }
        check("Tri des cases : ce qui est fait descend sous ce qui reste à faire, chacun dans son ordre",
              sorted("x\n☐ a\n☑ b\n☐ c\n☑ d\nfin", at: 2) == "x\n☐ a\n☐ c\n☑ b\n☑ d\nfin", sorted("x\n☐ a\n☑ b\n☐ c\n☑ d\nfin", at: 2) ?? "nil")
        check("Tri des cases : la dernière ligne de la note, sans retour à la ligne, trie aussi",
              sorted("x\n☑ a\n☐ b", at: 2) == "x\n☐ b\n☑ a", sorted("x\n☑ a\n☐ b", at: 2) ?? "nil")
        check("Tri des cases : une liste en ordre ne bouge pas, une autre liste plus bas non plus ; le titre n'en fait pas partie",
              sorted("x\n☐ a\n☑ b\n\n☑ c\n☐ d", at: 2) == nil && sorted("☑ x\n☐ a", at: 3) == nil && sorted("x\n☑ c\n☐ d\n\n☑ e\n☐ f", at: 2) == "x\n☐ d\n☑ c\n\n☑ e\n☐ f")
        let moving = NSMutableAttributedString(string: "x\n☑ un\n☐ deux")
        let sort = ChecklistSort(moving, around: 2)
        check("Tri des cases : le curseur suit sa ligne", sort?.moved(5) == 12 && sort?.moved(9) == 4 && sort?.moved(0) == 0, "\(sort?.moved(5) ?? -1) \(sort?.moved(9) ?? -1)")

        // In the editor: after a moment, the item checked goes down; typed in meanwhile, nothing moves.
        var view = editor(NoteContent(text: "x\n☐ un\n☐ deux\n☐ trois\nfin"))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        var box = view.checkboxRect(at: 2) ?? .zero
        step(view) { _ = view.toggleCheckbox(at: NSPoint(x: box.midX, y: box.midY)) }
        check("Tri des cases : la ligne cochée reste un instant à sa place", view.string == "x\n☑ un\n☐ deux\n☐ trois\nfin", view.string)
        await sleep(NoteFormat.checklistSortDelay + 0.3)
        check("Tri des cases : puis elle descend sous ce qui reste à faire, le curseur avec elle", view.string == "x\n☐ deux\n☐ trois\n☑ un\nfin"
              && view.selectedRange() == NSRange(location: 19, length: 0), "\(view.string) \(view.selectedRange())")
        check("Tri des cases : elle reste barrée et estompée", view.textStorage?.attribute(.strikethroughStyle, at: 20, effectiveRange: nil) != nil
              && view.textStorage?.attribute(.strikethroughStyle, at: 5, effectiveRange: nil) == nil)
        view.undoManager?.undo()
        check("Tri des cases : annuler la remet à sa place", view.string == "x\n☑ un\n☐ deux\n☐ trois\nfin", view.string)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        box = view.checkboxRect(at: 2) ?? .zero
        step(view) { _ = view.toggleCheckbox(at: NSPoint(x: box.midX, y: box.midY)) }
        await sleep(NoteFormat.checklistSortDelay + 0.3)
        check("Tri des cases : décochée, elle reste en haut de ce qui reste à faire", view.string == "x\n☐ un\n☐ deux\n☐ trois\nfin", view.string)

        view = editor(NoteContent(text: "x\n☐ un\n☐ deux"))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        box = view.checkboxRect(at: 2) ?? .zero
        step(view) { _ = view.toggleCheckbox(at: NSPoint(x: box.midX, y: box.midY)) }
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        type("s", in: view)
        await sleep(NoteFormat.checklistSortDelay + 0.3)
        check("Tri des cases : rien ne bouge si l'on a tapé entre-temps", view.string == "x\n☑ un\n☐ deuxs", view.string)
    }

    // MARK: The real window

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Key presses sent to the app's window, as typed on the keyboard.
    static func press(_ text: String, in window: NSWindow) {
        for character in text {
            let isReturn = character == "\n"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: isReturn ? "\r" : String(character),
                                                charactersIgnoringModifiers: isReturn ? "\r" : String(character), isARepeat: false, keyCode: isReturn ? 36 : 0) {
                    window.sendEvent(event)
                }
            }
        }
    }

    /// New note, typed in the app's own window: the keyboard reaches the text, the list follows,
    /// the note is saved without being asked.
    private static func window() async {
        let store = NoteStore.shared, model = NotesModel.shared
        guard let window = NSApp.windows.first(where: { $0.frameAutosaveName == MainWindowView.autosaveName }) else {
            return check("Fenêtre : présente", false)
        }
        check("Fenêtre : aucune note au départ", store.notes.isEmpty && model.selected == nil)
        model.newNote()
        await sleep(0.5)
        check("Fenêtre : la nouvelle note reçoit le clavier", window.firstResponder is NoteTextView, "\(String(describing: window.firstResponder))")
        press("# Essai\n- lait\n**pain**\n\n> fin", in: window)
        await sleep(0.2)
        let expected = NoteContent(text: "Essai\n• lait\n• pain\nfin", runs: [
            StyleRun(start: 0, length: 6, block: .title), StyleRun(start: 15, length: 4, bold: true), StyleRun(start: 20, length: 3, block: .quote),
        ])
        check("Fenêtre : la frappe au clavier est mise en forme et enregistrée", store.notes.first?.content == expected, "\(String(describing: store.notes.first?.content))")
        check("Fenêtre : la liste montre le titre et l'aperçu", store.notes.first?.title == "Essai" && store.notes.first?.preview == "• lait • pain fin")
        model.newNote()
        await sleep(0.3)
        check("Fenêtre : la seconde note reçoit le clavier", (window.firstResponder as? NoteTextView)?.string == "", "\(String(describing: window.firstResponder))")
        press("Seconde", in: window)
        await sleep(0.2)
        check("Fenêtre : la seconde note passe en tête", store.notes.map(\.title) == ["Seconde", "Essai"], "\(store.notes.map(\.title))")
        model.query = "lait"
        check("Fenêtre : recherche", model.visibleNotes.map(\.title) == ["Essai"])
        let second = model.selectedID
        if let found = model.visibleNotes.first { model.open(found.id) }
        await sleep(0.4)
        check("Fenêtre : un résultat ouvert reçoit le clavier", (window.firstResponder as? NoteTextView)?.string.hasPrefix("Essai") == true)
        model.query = ""
        if let second { model.open(second) }
        await sleep(0.4)
        model.askToDeleteSelected()
        await sleep(0.3)
        check("Fenêtre : supprimer met à la corbeille sans rien demander, la note voisine est ouverte", model.pendingDeletion == nil
              && store.notes.map(\.title) == ["Essai"] && store.trash.map(\.title) == ["Seconde"] && model.selected?.title == "Essai")
        if let deleted = store.trash.first { model.select(deleted.id) }
        await sleep(0.4)
        check("Fenêtre : une note de la corbeille se lit sans s'écrire", (window.firstResponder as? NoteTextView)?.isEditable != true
              && model.editor?.string == "Seconde" && model.editor?.isEditable == false && model.editor?.meta.hasPrefix("Dans la corbeille") == true)
        model.askToDeleteSelected()
        check("Fenêtre : supprimer depuis la corbeille demande confirmation", model.pendingDeletion?.title == "Seconde" && store.trash.count == 1)
        model.pendingDeletion = nil
        if let deleted = store.trash.first { model.restore(deleted) }
        await sleep(0.4)
        check("Fenêtre : une note restaurée s'écrit de nouveau", model.selected?.title == "Seconde" && model.editor?.isEditable == true && store.trash.isEmpty)

        // Touch ID says yes.
        model.canAuthenticate = { true }
        model.authenticate = { _, completion in completion(true) }
        if let id = model.selectedID { model.lock(id) }
        await sleep(0.4)
        check("Fenêtre : une note verrouillée n'a plus de texte à l'écran ni au clavier", model.editor?.window == nil && !(window.firstResponder is NoteTextView) && model.selected?.title == "Seconde",
              "\(String(describing: model.editor?.window)) \(String(describing: window.firstResponder))")
        model.toggleLock()
        await sleep(0.5)
        check("Fenêtre : déverrouillée, la note revient et s'écrit", model.editor?.string == "Seconde" && model.editor?.isEditable == true && window.firstResponder is NoteTextView,
              "\(String(describing: model.editor?.string)) \(String(describing: window.firstResponder))")
        if let id = model.selectedID { model.removeLock(id) }

        let folder = store.createFolder(named: "Dossier")
        if let id = model.selectedID { model.move(id, to: folder.id) }
        if !model.showsAllNotes { model.toggleAllNotes() }
        let tree = model.rows.map(\.id)
        AppSettings.shared.showsAllNotesRow = false
        let without = model.rows.map(\.id)
        check("Réglages : sans « Toutes les notes », la liste commence aux dossiers", tree.contains("all") && tree.contains { $0.hasPrefix("all-") }
              && without.contains(folder.id.uuidString) && !without.contains { $0.hasPrefix("all") } && model.visibleNotes.count == store.notes.count, "\(without)")
        AppSettings.shared.showsAllNotesRow = true
        check("Réglages : « Toutes les notes » revient, dépliée comme avant", model.rows.map(\.id) == tree)
    }

    // MARK: Tint of the window

    /// Réglages → Teinte: persisted, drawn behind the whole window (toolbar included), contrast
    /// kept for every hue; the pastel accents carry dark labels.
    private static func tint() async {
        let settings = AppSettings.shared, model = NotesModel.shared
        guard let window = NSApp.windows.first(where: { $0.frameAutosaveName == MainWindowView.autosaveName }) else {
            return check("Teinte : fenêtre présente", false)
        }
        let saved = (settings.chromeTint, settings.chromeTintIntensity, settings.chromeTintGradient, settings.accent, settings.theme)
        let defaults = UserDefaults(suiteName: "app.void.notes.debug")!
        settings.accent = .violet
        settings.theme = .light
        settings.chromeTint = .lavender
        settings.chromeTintIntensity = 0.15
        settings.chromeTintGradient = false
        check("Teinte : mémorisée", defaults.string(forKey: "chromeTint") == "lavender"
              && defaults.double(forKey: "chromeTintIntensity") == 0.15 && defaults.object(forKey: "chromeTintGradient") as? Bool == false)
        let expected = ChromeLook.mix(ChromeLook.warm.light, ChromeLook.pastel(ChromeTint.lavender.hue!, dark: false), 0.15)
        check("Teinte : lavande à 15 % sur la base chaude", hex(Theme.chromeNS, dark: false) == expected, String(format: "#%06X", hex(Theme.chromeNS, dark: false) ?? 0))
        let sheet = ChromeLook.mix(expected, 0xFFFFFF, ChromeLook.lift.light)
        check("Teinte : la surface de la note est le cadre, éclairci", hex(Theme.surfaceNS, dark: false) == sheet, String(format: "#%06X", hex(Theme.surfaceNS, dark: false) ?? 0))
        check("Teinte : le texte secondaire de la note passe en gris chaud", Theme.secondaryTextNS == Theme.secondaryTextWarmNS)
        let frame = window.contentView?.superview
        // Behind the toolbar, a view at the back of the title bar; behind the content, the content
        // itself. None in the window's frame view: macOS 27 would lay the toolbar out anew.
        let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview
        let backdrop = titlebar?.subviews.first { $0 is NSHostingView<AnyView> }
        // Under the bar that holds the window's buttons and the toolbar.
        let under = titlebar.map { bar in bar.subviews.firstIndex { $0 === backdrop } ?? .max < bar.subviews.firstIndex { $0 === window.standardWindowButton(.closeButton)?.superview } ?? -1 } ?? false
        check("Teinte : fond derrière toute la fenêtre, barre d'outils comprise", under && backdrop?.frame == titlebar?.bounds
              && WindowBackdrop.metrics.split && WindowBackdrop.metrics.windowHeight == window.frame.height
              && frame?.subviews.contains { $0 is NSHostingView<AnyView> } == false
              && !window.isOpaque && window.backgroundColor == .clear && backdrop?.hitTest(NSPoint(x: 10, y: 10)) == nil,
              "\(backdrop.map { "\(Swift.type(of: $0)) \($0.frame)" } ?? "nil") dans \(titlebar?.bounds ?? .zero), \(WindowBackdrop.metrics.windowHeight)/\(window.frame.height), "
              + (frame?.subviews.map { "\(Swift.type(of: $0))" }.joined(separator: " ") ?? ""))
        await sleep(0.3)
        let items = frame.map { views(of: NSView.self, in: $0).filter { "\(Swift.type(of: $0))".hasPrefix("ToolbarItemHostingView") } } ?? []
        check("Barre d'outils : ses boutons à leur hauteur, en face des boutons de la fenêtre, thème clair compris",
              !items.isEmpty && items.allSatisfy { $0.frame.height <= 30 }, items.map { "\($0.frame)" }.joined(separator: ", "))
        let blurs = { frame.map { views(of: NSVisualEffectView.self, in: $0).filter { $0.blendingMode == .behindWindow && $0.state == .active }.count } ?? 0 }
        check("Teinte : cadre légèrement translucide (bureau flouté dessous)", blurs() >= 1, "\(blurs()) vue(s) de flou")
        // The window drawn: the note shows the same frame as the list, lighter by the lift.
        if let frame, let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / frame.bounds.width
            let pixel = { (x: CGFloat) in image.colorAt(x: Int(x * scale), y: Int(frame.bounds.height * 0.6 * scale))?.usingColorSpace(.sRGB) }
            if let list = pixel(12), let note = pixel(frame.bounds.width - 40) {
                let lifted = [list.redComponent, list.greenComponent, list.blueComponent].map { $0 + (1 - $0) * ChromeLook.lift.light }
                let gap = zip(lifted, [note.redComponent, note.greenComponent, note.blueComponent]).map { abs($0 - $1) }.max() ?? 1
                // One blur behind the toolbar, one behind the content.
                check("Teinte : la note laisse voir le cadre, comme la liste, un peu plus clair", gap < 0.03 && blurs() == 2, "liste \(list), note \(note), \(blurs()) vue(s) de flou")
            } else {
                check("Teinte : la note laisse voir le cadre, comme la liste, un peu plus clair", false, "capture impossible")
            }
        }
        settings.chromeTintIntensity = 0.9
        check("Teinte : intensité plafonnée à 20 %", settings.chromeLook.amount == 0.20, "\(settings.chromeLook.amount)")
        settings.chromeTint = .none
        await sleep(0.4)
        check("Teinte : « Neutre » garde le gris d'origine, la note blanche et le gris froid, opaque", hex(Theme.chromeNS, dark: false) == 0xE9E9EE && hex(Theme.chromeNS, dark: true) == 0x0B0B0E
              && hex(Theme.surfaceNS, dark: false) == 0xFFFFFF && hex(Theme.surfaceNS, dark: true) == 0x17171C && Theme.secondaryTextNS == Theme.secondaryTextCoolNS && blurs() == 0,
              "\(blurs()) vue(s) de flou")
        let marked = AccentChoice.allCases.map { accent in ChromeTint.palette.filter { $0.isComplementary(to: accent) } }
        check("Teinte : chaque couleur a au moins une teinte complémentaire signalée", marked.allSatisfy { !$0.isEmpty },
              zip(AccentChoice.allCases, marked).map { "\($0.rawValue) → \($1.map(\.rawValue).joined(separator: "+"))" }.joined(separator: ", "))

        // Contrast (WCAG) of the warm secondary text (and, in the dark theme, of every accent) on
        // the frame and on the note's surface: every tint, its complement (the gradient's second
        // glow), every intensity; then of the note's own text (primary, secondary) on the tinted
        // surface. The light theme's accents trade contrast for softness (AccentChoice).
        var worst = (ratio: 99.0, what: "")
        var worstNote = (ratio: 99.0, what: "")
        let warm = (hex(Theme.secondaryTextWarmNS, dark: false)!, hex(Theme.secondaryTextWarmNS, dark: true)!)
        let noteText = [Theme.primaryTextNS, Theme.secondaryTextWarmNS].map { (hex($0, dark: false)!, hex($0, dark: true)!) }
        for tint in ChromeTint.palette {
            for hue in [tint.hue!, tint.hue! + 180] {
                for amount in [ChromeLook.amountRange.lowerBound * ChromeLook.gradientBase, 0.12, ChromeLook.amountRange.upperBound] {
                    let look = ChromeLook(tint: tint, amount: amount, gradient: false)
                    let tone = look.tone(hue: hue, amount: amount), sheet = look.surfaceTone(hue: hue, amount: amount)
                    for dark in [false, true] {
                        let backgrounds = [hex(tone, dark: dark)!, hex(sheet, dark: dark)!]
                        for color in noteText.map({ dark ? $0.1 : $0.0 }) {
                            let ratio = contrast(color, hex(sheet, dark: dark)!)
                            if ratio < worstNote.ratio { worstNote = (ratio, String(format: "%.0f°, %.0f %%, %@, #%06X", hue, amount * 100, dark ? "sombre" : "clair", color)) }
                        }
                        let colors = [dark ? warm.1 : warm.0] + (dark ? AccentChoice.allCases.map(\.darkHex) : [])
                        for color in colors {
                            for background in backgrounds {
                                let ratio = contrast(color, background)
                                if ratio < worst.ratio { worst = (ratio, String(format: "%.0f°, %.0f %%, %@, #%06X sur #%06X", hue, amount * 100, dark ? "sombre" : "clair", color, background)) }
                            }
                        }
                    }
                }
            }
        }
        check("Teinte : contraste ≥ 4,5:1 (texte secondaire ; accents en sombre), toutes teintes et intensités", worst.ratio >= 4.5, String(format: "pire %.2f (%@)", worst.ratio, worst.what))
        check("Teinte : texte de la note lisible sur sa surface teintée (≥ 4,5:1)", worstNote.ratio >= 4.5, String(format: "pire %.2f (%@)", worstNote.ratio, worstNote.what))
        let labels = AccentChoice.allCases.map { contrast(0x131316, $0.lightHex) }
        check("Couleurs pastel : libellé foncé lisible sur les boutons et les cases cochées (≥ 4,5:1)", labels.allSatisfy { $0 >= 4.5 }, labels.map { String(format: "%.1f", $0) }.joined(separator: " "))
        let white = AccentChoice.allCases.map { contrast(0xFFFFFF, $0.deepHex) }
        check("Couleurs pastel : blanc lisible sur le ton profond des actions de balayage (≥ 4,5:1)", white.allSatisfy { $0 >= 4.5 }, white.map { String(format: "%.1f", $0) }.joined(separator: " "))

        (settings.chromeTint, settings.chromeTintIntensity, settings.chromeTintGradient, settings.accent, settings.theme) = saved
    }

    private static func views<V: NSView>(of type: V.Type, in view: NSView) -> [V] {
        ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    /// The sRGB value of a color in the light or the dark appearance.
    private static func hex(_ color: NSColor, dark: Bool) -> UInt32? {
        var result: UInt32?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            result = [c.redComponent, c.greenComponent, c.blueComponent].reduce(0) { $0 << 8 | UInt32(($1 * 255).rounded()) }
        }
        return result
    }

    private static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let v = Double((hex >> shift) & 0xFF) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: Formatting as you type

    private static var testWindow: NSWindow?

    /// A text view in a window (for its undo manager), as in the app.
    // MARK: Links

    private static func links() {
        check("Liens : adresses reconnues", NoteFormat.linkURL(from: "void.app")?.absoluteString == "https://void.app"
              && NoteFormat.linkURL(from: " https://exemple.fr/a?b=1 ")?.absoluteString == "https://exemple.fr/a?b=1"
              && NoteFormat.linkURL(from: "nom@exemple.fr")?.absoluteString == "mailto:nom@exemple.fr"
              && NoteFormat.linkURL(from: "bonjour") == nil && NoteFormat.linkURL(from: "deux mots.fr") == nil && NoteFormat.linkURL(from: "https://") == nil)

        let view = editor()
        type("Lecture\nVoir le site demain", in: view)
        // "site ", its space left out of the link.
        view.setSelectedRange(NSRange(location: 16, length: 5))
        step(view) { view.setLink(URL(string: "https://void.app")) }
        let linked = { (view.textStorage!.attribute(.link, at: $0, effectiveRange: nil) as? URL)?.absoluteString }
        check("Liens : la sélection devient un lien, enregistré", runs(view).contains(StyleRun(start: 16, length: 4, link: "https://void.app"))
              && linked(17) == "https://void.app" && linked(15) == nil && linked(20) == nil, "\(runs(view))")
        view.setSelectedRange(NSRange(location: 20, length: 0))
        type("x", in: view)
        check("Liens : écrire au bout d'un lien ne l'allonge pas", linked(20) == nil && linked(19) == "https://void.app")
        view.setSelectedRange(NSRange(location: 18, length: 0))
        type("y", in: view)
        check("Liens : écrire au milieu d'un lien en fait partie", linked(18) == "https://void.app" && view.currentLink == "https://void.app")
        view.setSelectedRange(NSRange(location: 17, length: 0))
        step(view) { view.setLink(URL(string: "https://irum.app")) }
        check("Liens : sans sélection, l'adresse du lien du curseur change", runs(view).contains(StyleRun(start: 16, length: 5, link: "https://irum.app")), "\(runs(view))")
        let reloaded = NoteFormat.attributedString(from: view.content)
        check("Liens : relus", NoteFormat.content(from: reloaded) == view.content && (reloaded.attribute(.link, at: 17, effectiveRange: nil) as? URL)?.host() == "irum.app")
        step(view) { view.setLink(nil) }
        check("Liens : retirer le lien garde le texte", !runs(view).contains { $0.link != nil } && linked(17) == nil && view.string == "Lecture\nVoir le siytex demain", view.string)
        view.undoManager?.undo()
        check("Liens : retrait annulé", view.currentLink == "https://irum.app")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        step(view) { view.setLink(URL(string: "mailto:nom@exemple.fr")) }
        check("Liens : sans sélection hors d'un lien, l'adresse s'écrit, en lien", view.string.hasSuffix("demainnom@exemple.fr") && view.currentLink == "mailto:nom@exemple.fr", view.string)
    }

    // MARK: Spelling and grammar

    private static func proofreading() {
        let view = editor()
        type("Courses\nIl fait beau aujourdhui et demain.", in: view)
        view.setProofreading(spelling: true, grammar: true)
        view.proofReader.checkNow()
        let wrong = (view.string as NSString).range(of: "aujourdhui")
        check("Orthographe : mot inconnu marqué", view.proofReader.marks.contains { $0.kind == .spelling && $0.range == wrong }, "\(view.proofReader.marks)")
        check("Orthographe : rien d'autre dans une phrase juste", view.proofReader.marks.count == 1, "\(view.proofReader.marks.map { (view.string as NSString).substring(with: $0.range) })")
        let mark = view.proofReader.marks[0]
        let items = view.items(for: mark).map(\.title)
        check("Orthographe : le clic droit propose la correction", items.contains("aujourd’hui") || items.contains("aujourd'hui"), "\(items)")
        view.setSelectedRange(NSRange(location: 10, length: 0))
        type("x", in: view)
        check("Orthographe : la marque suit le texte", view.proofReader.marks.first?.range.location == wrong.location + 1)
        type("\u{8}", in: view)
        if let item = view.items(for: view.proofReader.marks[0]).first(where: { $0.action == #selector(NoteTextView.applyCorrection(_:)) }) {
            step(view) { view.applyCorrection(item) }
        }
        check("Orthographe : la correction remplace le mot", view.string.contains("beau aujourd") && !view.string.contains("aujourdhui") && view.proofReader.marks.isEmpty, view.string)

        // An address isn't a word.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        step(view) { view.setLink(URL(string: "https://xqzvw.example")) }
        view.proofReader.checkNow()
        check("Orthographe : les liens ne sont pas lus", view.proofReader.marks.isEmpty, "\(view.proofReader.marks)")

        let english = editor()
        type("Notes\nThis are a good idea.", in: english)
        english.setProofreading(spelling: true, grammar: true)
        english.proofReader.checkNow()
        if ProofReader.grammarIsAvailable {
            check("Grammaire : faute marquée (en bleu)", english.proofReader.marks.contains { $0.kind == .grammar }, "\(english.proofReader.marks)")
        } else {
            // This macOS doesn't check grammar: the option isn't offered, nothing is asked of it.
            check("Grammaire : macOS n'en fournit pas, rien n'est demandé au correcteur", !english.proofReader.checksGrammar)
        }
        english.setProofreading(spelling: true, grammar: false)
        check("Grammaire : réglage coupé, plus de marque", !english.proofReader.marks.contains { $0.kind == .grammar })
        english.setProofreading(spelling: false, grammar: false)
        check("Orthographe : réglages coupés, rien n'est marqué", english.proofReader.marks.isEmpty && !english.isContinuousSpellCheckingEnabled && !english.isGrammarCheckingEnabled)
    }

    private static func editor(_ content: NoteContent = NoteContent()) -> NoteTextView {
        let (scrollView, textView) = NoteTextView.makeScrollable()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        testWindow = window
        textView.load(content)
        // One undo step per key, as when typing for real (the test types everything in one go).
        textView.undoManager?.groupsByEvent = false
        return textView
    }

    /// Types `text` key by key; "\n" is Return, "\u{8}" is Backspace.
    private static func type(_ text: String, in view: NoteTextView) {
        for character in text {
            view.undoManager?.beginUndoGrouping()
            defer { view.undoManager?.endUndoGrouping() }
            switch character {
            case "\n": view.insertNewline(nil)
            case "\u{8}": view.deleteBackward(nil)
            default: view.insertText(String(character), replacementRange: view.selectedRange())
            }
        }
    }

    /// One command, one undo step.
    private static func step(_ view: NoteTextView, _ action: () -> Void) {
        view.undoManager?.beginUndoGrouping()
        action()
        view.undoManager?.endUndoGrouping()
    }

    private static func runs(_ view: NoteTextView) -> [StyleRun] { view.content.runs }

    private static func typing() {
        var view = editor()
        type("Courses\nlait", in: view)
        check("Frappe : la première ligne d'une note vide est son titre", view.content == NoteContent(text: "Courses\nlait", runs: [StyleRun(start: 0, length: 8, block: .title)]), "\(view.content)")

        view = editor()
        type("\u{8}texte\n# Titre\nsuite\n## Sous-titre\n### Intertitre\nfin", in: view)
        check("Frappe : # ## ### deviennent des titres, la marque disparaît", view.string == "texte\nTitre\nsuite\nSous-titre\nIntertitre\nfin", view.string)
        check("Frappe : après un titre, retour au texte", runs(view) == [
            StyleRun(start: 6, length: 6, block: .title), StyleRun(start: 18, length: 11, block: .heading), StyleRun(start: 29, length: 11, block: .subheading),
        ], "\(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("- un\ndeux\n\n\n* trois", in: view)
        check("Frappe : - et * deviennent des puces, Entrée continue, Entrée sur une puce vide termine", view.string == "x\n• un\n• deux\n\n• trois", view.string)

        view = editor(NoteContent(text: "x\n"))
        type("1. un\ndeux\ntrois\n\n\nfin", in: view)
        check("Frappe : liste numérotée continuée", view.string == "x\n1. un\n2. deux\n3. trois\n\nfin", view.string)

        view = editor(NoteContent(text: "x\n"))
        type("- a\u{8}\u{8}b", in: view)
        check("Frappe : retour arrière après la puce la retire", view.string == "x\nb", view.string)

        view = editor(NoteContent(text: "x\n"))
        type("un **gras** et *ital* puis _ital_ fin", in: view)
        check("Frappe : ** * _ disparaissent", view.string == "x\nun gras et ital puis ital fin", view.string)
        check("Frappe : gras et italique appliqués, pas au-delà", runs(view) == [
            StyleRun(start: 5, length: 4, bold: true), StyleRun(start: 13, length: 4, italic: true), StyleRun(start: 23, length: 4, italic: true),
        ], "\(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("2 * 3 * 4, snake_case_name, a*b*c, ** ", in: view)
        check("Frappe : * et _ isolés restent tels quels", view.string == "x\n2 * 3 * 4, snake_case_name, a*b*c, ** " && runs(view).isEmpty, "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("**gras *et ital* ensemble**", in: view)
        check("Frappe : italique dans du gras", view.string == "x\ngras et ital ensemble" && runs(view) == [
            StyleRun(start: 2, length: 5, bold: true), StyleRun(start: 7, length: 7, bold: true, italic: true), StyleRun(start: 14, length: 9, bold: true),
        ], "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("> citation\nsuite\n\naprès", in: view)
        check("Frappe : > ouvre une citation, Entrée la continue, Entrée sur une ligne vide la termine", view.string == "x\ncitation\nsuite\naprès"
              && runs(view) == [StyleRun(start: 2, length: 15, block: .quote)], "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "x\nTitre", runs: [StyleRun(start: 2, length: 5, block: .title)]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        type("\u{8}", in: view)
        check("Frappe : retour arrière au début d'un titre le remet en texte", view.string == "x\nTitre" && runs(view).isEmpty, "\(runs(view))")

        view = editor(NoteContent(text: "x\nTitre\nfin", runs: [StyleRun(start: 2, length: 6, block: .title)]))
        view.setSelectedRange(NSRange(location: 7, length: 0))
        type("\nnouveau", in: view)
        check("Frappe : Entrée à la fin d'un titre, au milieu d'une note", view.string == "x\nTitre\nnouveau\nfin"
              && runs(view) == [StyleRun(start: 2, length: 6, block: .title)], "\(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("un ==mot== fin, a == b == c, x=1", in: view)
        check("Frappe : == surligne, = isolé reste tel quel", view.string == "x\nun mot fin, a == b == c, x=1"
              && runs(view) == [StyleRun(start: 5, length: 3, highlight: true)], "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("---suite", in: view)
        check("Frappe : --- devient un séparateur, la suite est du texte", view.string == "x\n---\nsuite"
              && runs(view) == [StyleRun(start: 2, length: 4, block: .divider)], "\(view.string) \(runs(view))")
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("\u{8}", in: view)
        check("Frappe : retour arrière après un séparateur le retire", view.string == "x\nsuite" && runs(view).isEmpty, "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "x\n---\ny", runs: [StyleRun(start: 2, length: 4, block: .divider)]))
        view.setSelectedRange(NSRange(location: 5, length: 0))
        type("z", in: view)
        check("Frappe : écrire dans un séparateur en fait du texte", view.string == "x\n---z\ny" && runs(view).isEmpty, "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("a -- b, --", in: view)
        check("Frappe : -- reste tel quel", view.string == "x\na -- b, --" && runs(view).isEmpty, "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "Titre", runs: [StyleRun(start: 0, length: 5, block: .title)]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        type("\n", in: view)
        let cut = view.textStorage?.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle
        check("Frappe : un titre coupé en deux, la place des dates reste sous la première ligne", (cut?.paragraphSpacing ?? 99) < NoteFormat.metaSpace)

        view = editor()
        type("Courses", in: view)
        step(view) { view.moveDown(nil) }
        type("pain", in: view)
        check("Frappe : ↓ à la fin d'un titre seul ouvre la ligne de texte", view.content == NoteContent(text: "Courses\npain", runs: [StyleRun(start: 0, length: 8, block: .title)]), "\(view.content)")
        view = editor(NoteContent(text: "Courses", runs: [StyleRun(start: 0, length: 7, block: .title)]))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let onTitle = view.clickBelowText(at: NSPoint(x: 80, y: NoteTextView.topMargin + 10))
        step(view) { _ = view.clickBelowText(at: NSPoint(x: 80, y: 300)) }
        type("pain", in: view)
        check("Frappe : un clic sous un titre seul ouvre la ligne de texte", !onTitle && view.content == NoteContent(text: "Courses\npain", runs: [StyleRun(start: 0, length: 8, block: .title)]), "\(view.content)")
        view = editor(NoteContent(text: "x\ntexte"))
        view.moveDown(nil)
        check("Frappe : ↓ à la fin d'un texte n'ajoute rien", view.string == "x\ntexte")

        // Commands.
        view = editor(NoteContent(text: "un deux trois"))
        view.setSelectedRange(NSRange(location: 3, length: 4))
        step(view) { view.setWeight(.light) }
        check("Commandes : graisse sur une sélection", runs(view) == [StyleRun(start: 3, length: 4, weight: .light)] && view.currentWeight == .light, "\(runs(view))")
        step(view) { view.toggleBold() }
        check("Commandes : le gras remplace la graisse", runs(view) == [StyleRun(start: 3, length: 4, bold: true)], "\(runs(view))")
        step(view) { view.setWeight(nil) }
        check("Commandes : graisse normale", runs(view).isEmpty, "\(runs(view))")
        step(view) { view.toggleHighlight() }
        check("Commandes : surligner une sélection", runs(view) == [StyleRun(start: 3, length: 4, highlight: true)] && view.isHighlighted, "\(runs(view))")
        view.undoManager?.undo()
        check("Commandes : annuler retire le surlignage", runs(view).isEmpty && view.textStorage?.attribute(.backgroundColor, at: 3, effectiveRange: nil) == nil, "\(runs(view))")

        view = editor(NoteContent(text: "x "))
        view.setWeight(.semibold)
        type("fort", in: view)
        view.setWeight(nil)
        type(" non", in: view)
        check("Commandes : graisse sans sélection agit sur la suite", runs(view) == [StyleRun(start: 2, length: 4, weight: .semibold)], "\(runs(view))")

        view = editor(NoteContent(text: "a\nb"))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        step(view) { view.insertDivider() }
        check("Commandes : séparateur sous la ligne du curseur", view.string == "a\n---\nb" && runs(view) == [StyleRun(start: 2, length: 4, block: .divider)]
              && view.selectedRange().location == 6, "\(view.string) \(runs(view)) \(view.selectedRange())")
        view = editor(NoteContent(text: "a\n"))
        step(view) { view.insertDivider() }
        type("b", in: view)
        check("Commandes : séparateur sur une ligne vide, la suite est du texte", view.string == "a\n---\nb" && runs(view) == [StyleRun(start: 2, length: 4, block: .divider)],
              "\(view.string) \(runs(view))")

        view = editor(NoteContent(text: "un deux trois"))
        view.setSelectedRange(NSRange(location: 3, length: 4))
        step(view) { view.toggleBold() }
        step(view) { view.toggleItalic() }
        check("Commandes : ⌘B et ⌘I sur une sélection", runs(view) == [StyleRun(start: 3, length: 4, bold: true, italic: true)], "\(runs(view))")
        step(view) { view.toggleBold() }
        check("Commandes : ⌘B une seconde fois retire le gras", runs(view) == [StyleRun(start: 3, length: 4, italic: true)], "\(runs(view))")
        view.undoManager?.undo()
        check("Commandes : annuler rétablit la mise en forme", runs(view) == [StyleRun(start: 3, length: 4, bold: true, italic: true)], "\(runs(view))")

        view = editor(NoteContent(text: "x "))
        view.toggleBold()
        type("gras", in: view)
        view.toggleBold()
        type(" non", in: view)
        check("Commandes : ⌘B sans sélection agit sur la suite", runs(view) == [StyleRun(start: 2, length: 4, bold: true)], "\(runs(view))")

        view = editor(NoteContent(text: "a\nb\nc"))
        view.setSelectedRange(NSRange(location: 0, length: 5))
        step(view) { view.toggleList(.numbered) }
        check("Commandes : liste numérotée sur plusieurs lignes", view.string == "1. a\n2. b\n3. c", view.string)
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        step(view) { view.toggleList(.bullet) }
        check("Commandes : passage en puces", view.string == "• a\n• b\n• c", view.string)
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        step(view) { view.toggleList(.bullet) }
        check("Commandes : retrait des puces", view.string == "a\nb\nc", view.string)

        // Checklists.
        view = editor(NoteContent(text: "x\n"))
        type("[] lait\npain\n\nfin", in: view)
        check("Liste à cocher : [] ouvre une case, Entrée continue, Entrée sur une case vide termine", view.string == "x\n☐ lait\n☐ pain\nfin" && runs(view).isEmpty, view.string)
        view = editor(NoteContent(text: "x\n"))
        type("[x] fait\nsuite\n[x] aussi\n\n- [ ] markdown\n\n[ ] espace", in: view)
        check("Liste à cocher : [x] coche, même dans une case vide ; la ligne suivante est à faire ; - [ ] et [ ] reconnus", view.string == "x\n☑ fait\n☐ suite\n☑ aussi\n☐ markdown\n☐ espace", view.string)
        view = editor(NoteContent(text: "x\n"))
        type("[] a\u{8}\u{8}b [] c, t[0] = 1", in: view)
        check("Liste à cocher : retour arrière après la case la retire ; [] ailleurs qu'en début de ligne reste tel quel", view.string == "x\nb [] c, t[0] = 1", view.string)
        view = editor()
        type("[] titre", in: view)
        check("Liste à cocher : pas dans un titre", view.string == "[] titre", view.string)

        view = editor(NoteContent(text: "x\n☐ un\n☑ deux\ntrois"))
        let storage = view.textStorage!
        check("Liste à cocher : la case est dessinée, son caractère ne se voit pas ; ce qui est fait s'estompe",
              storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .clear && storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == Theme.primaryTextNS
              && storage.attribute(.foregroundColor, at: 11, effectiveRange: nil) as? NSColor == Theme.secondaryTextNS
              && ((storage.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0) > 0)
        check("Liste à cocher : ce qui est fait est barré, après la case ; le reste non", storage.attribute(.strikethroughStyle, at: 11, effectiveRange: nil) != nil
              && storage.attribute(.strikethroughStyle, at: 8, effectiveRange: nil) == nil && storage.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) == nil
              && storage.attribute(.strikethroughStyle, at: 16, effectiveRange: nil) == nil && NoteFormat.content(from: storage).runs.isEmpty)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let first = view.checkboxRect(at: 2) ?? .zero, second = view.checkboxRect(at: 7) ?? .zero
        let bulleted = editor(NoteContent(text: "x\n• un\n• deux\ntrois"))
        bulleted.layoutManager?.ensureLayout(for: bulleted.textContainer!)
        let plain = bulleted.layoutManager!.lineFragmentRect(forGlyphAt: bulleted.layoutManager!.glyphIndexForCharacter(at: 2), effectiveRange: nil)
        let item = view.layoutManager!.lineFragmentRect(forGlyphAt: view.layoutManager!.glyphIndexForCharacter(at: 2), effectiveRange: nil)
        check("Liste à cocher : une case par ligne, de la hauteur d'une ligne à puce", first.width > 10 && first.width == first.height && second.minY > first.maxY
              && second.minX == first.minX && item.height == plain.height, "\(first) \(second) \(item.height) \(plain.height)")
        view.setSelectedRange(NSRange(location: 16, length: 0))
        var hit = false
        step(view) { hit = view.toggleCheckbox(at: NSPoint(x: first.midX, y: first.midY)) }
        check("Liste à cocher : un clic sur la case la coche, le curseur ne bouge pas", hit && view.string == "x\n☑ un\n☑ deux\ntrois" && view.selectedRange() == NSRange(location: 16, length: 0)
              && storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == Theme.secondaryTextNS, view.string)
        step(view) { hit = view.toggleCheckbox(at: NSPoint(x: second.midX, y: second.midY)) }
        check("Liste à cocher : un second clic décoche et retire le trait", hit && view.string == "x\n☑ un\n☐ deux\ntrois"
              && storage.attribute(.strikethroughStyle, at: 11, effectiveRange: nil) == nil && storage.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) != nil, view.string)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("\nsuite", in: view)
        check("Liste à cocher : la ligne tapée après une ligne cochée n'est pas barrée", view.string == "x\n☑ un\n☐ suite\n☐ deux\ntrois"
              && storage.attribute(.strikethroughStyle, at: 11, effectiveRange: nil) == nil, view.string)
        for _ in 0..<6 { view.undoManager?.undo() }
        view.setSelectedRange(NSRange(location: 16, length: 0))
        check("Liste à cocher : un clic sur le texte ou hors d'une liste ne coche rien", !view.toggleCheckbox(at: NSPoint(x: first.maxX + 30, y: first.midY))
              && !view.toggleCheckbox(at: NSPoint(x: first.midX, y: first.midY - 22)) && view.string == "x\n☑ un\n☐ deux\ntrois")
        view.undoManager?.undo()
        check("Liste à cocher : annuler rend la coche", view.string == "x\n☑ un\n☑ deux\ntrois", view.string)
        view.setSelectedRange(NSRange(location: 2, length: 10))
        step(view) { view.toggleChecked() }
        check("Liste à cocher : ⇧⌘U décoche des lignes toutes cochées", view.string == "x\n☐ un\n☐ deux\ntrois" && view.isChecked == false, view.string)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        step(view) { view.toggleChecked() }
        check("Liste à cocher : ⇧⌘U coche la ligne du curseur", view.string == "x\n☐ un\n☑ deux\ntrois" && view.isChecked == true, view.string)
        view.setSelectedRange(NSRange(location: 2, length: 16))
        step(view) { view.toggleList(.checklist) }
        check("Liste à cocher : la commande met des cases aux lignes qui n'en ont pas, sans décocher les autres", view.string == "x\n☐ un\n☑ deux\n☐ trois", view.string)
        view.setSelectedRange(NSRange(location: 2, length: 18))
        step(view) { view.toggleList(.bullet) }
        check("Liste à cocher : distincte des puces, on passe de l'une à l'autre", view.string == "x\n• un\n• deux\n• trois", view.string)
        view.setSelectedRange(NSRange(location: 2, length: 18))
        step(view) { view.toggleList(.checklist) }
        view.setSelectedRange(NSRange(location: 2, length: 18))
        step(view) { view.toggleList(.checklist) }
        check("Liste à cocher : la commande, une seconde fois, retire les cases", view.string == "x\nun\ndeux\ntrois", view.string)
        view = editor(NoteContent(text: "x\n☐ un"))
        view.isEditable = false
        check("Liste à cocher : une note en lecture seule ne se coche pas", !view.toggleCheckbox(at: NSPoint(x: (view.checkboxRect(at: 2) ?? .zero).midX, y: (view.checkboxRect(at: 2) ?? .zero).midY)) && view.string == "x\n☐ un")
        check("Liste à cocher : un titre tapé en case s'affiche sans elle, l'aperçu garde les cases", Note(content: NoteContent(text: "☐ Acheter\n☑ pain")).title == "Acheter"
              && Note(content: NoteContent(text: "☐ Acheter\n☑ pain")).preview == "☑ pain")

        view = editor(NoteContent(text: "x\ny"))
        step(view) { view.setBlock(.quote) }
        step(view) { view.setBlock(.heading) }
        check("Commandes : type de paragraphe", runs(view) == [StyleRun(start: 2, length: 1, block: .heading)], "\(runs(view))")

        view = editor(NoteContent(text: "x\n"))
        type("**gras**", in: view)
        view.undoManager?.undo()
        check("Annuler : la frappe revient avec ses marques", view.string == "x\n**gras*" && runs(view).isEmpty, "\(view.string) \(runs(view))")

        // Pasting.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("Collé\r\nligne deux", forType: .string)
        view = editor()
        step(view) { view.paste(nil) }
        check("Coller : dans un titre, seule la première ligne est le titre", view.content == NoteContent(text: "Collé\nligne deux", runs: [StyleRun(start: 0, length: 6, block: .title)]), "\(view.content)")
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        testWindow = nil
    }

    // MARK: Struck through, code, indentation, numbers that follow

    private static func writingTools() {
        var view = editor(NoteContent(text: "x\n"))
        type("un ~~vieux~~ mot et `code()` fin, a ~ b, x`", in: view)
        check("Frappe : ~~ barre, ` met en code, ~ isolé reste", view.string == "x\nun vieux mot et code() fin, a ~ b, x`"
              && runs(view) == [StyleRun(start: 5, length: 5, strike: true), StyleRun(start: 18, length: 6, code: true)], "\(view.string) \(runs(view))")
        let shown = NoteFormat.attributedString(from: view.content)
        let codeFont = shown.attribute(.font, at: 18, effectiveRange: nil) as? NSFont
        check("Affichage : barré tracé, code en chasse fixe sur un fond", shown.attribute(.strikethroughStyle, at: 6, effectiveRange: nil) != nil
              && codeFont?.isFixedPitch == true && shown.attribute(.backgroundColor, at: 18, effectiveRange: nil) != nil
              && shown.attribute(.strikethroughStyle, at: 12, effectiveRange: nil) == nil)
        check("Format : barré et code relus tels quels", NoteFormat.content(from: shown) == view.content)

        view = editor(NoteContent(text: "x\n"))
        type("mot", in: view)
        view.setSelectedRange(NSRange(location: 2, length: 3))
        step(view) { view.toggleStrike() }
        step(view) { view.toggleCode() }
        check("Commandes : Barré et Code sur une sélection", runs(view) == [StyleRun(start: 2, length: 3, strike: true, code: true)] && view.isStruck && view.isCode, "\(runs(view))")
        step(view) { view.toggleStrike() }
        check("Commandes : Barré une seconde fois retiré", runs(view) == [StyleRun(start: 2, length: 3, code: true)], "\(runs(view))")

        // Tab, ⇧Tab, Return and Backspace in an indented list.
        view = editor(NoteContent(text: "x\n"))
        type("- a\n\tb\nc", in: view)
        check("Retrait : Tab indente l'élément, Entrée garde le retrait", view.string == "x\n• a\n• b\n• c"
              && NoteFormat.indent(at: 6, in: view.textStorage!) == 1 && NoteFormat.indent(at: 10, in: view.textStorage!) == 1
              && NoteFormat.indent(at: 2, in: view.textStorage!) == 0, "\(view.string) \(runs(view))")
        check("Retrait : enregistré avec l'élément", runs(view).contains { $0.start == 6 && $0.indent == 1 }, "\(runs(view))")
        let style = view.textStorage!.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle
        check("Retrait : décalé d'un pas", style?.firstLineHeadIndent == NoteFormat.indentStep, "\(style?.firstLineHeadIndent ?? -1)")
        type("\n\n", in: view)
        check("Retrait : Entrée sur un élément vide en retrait le ramène d'un pas", view.string == "x\n• a\n• b\n• c\n• " && view.currentIndent == 0, view.string)
        type("\n", in: view)
        check("Retrait : puis termine la liste", view.string == "x\n• a\n• b\n• c\n", view.string)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        type("\u{8}", in: view)
        check("Retrait : Retour arrière après la puce d'un élément en retrait le ramène d'abord", view.string == "x\n• a\n• b\n• c\n" && view.currentIndent == 0, view.string)
        step(view) { view.changeIndent(by: 1) }
        step(view) { view.insertBacktab(nil) }
        check("Retrait : ⌘] puis ⇧Tab", view.currentIndent == 0)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        type("\t", in: view)
        check("Retrait : Tab hors d'une liste… dans une liste, toujours un retrait", NoteFormat.indent(at: 2, in: view.textStorage!) == 1 && view.string == "x\n• a\n• b\n• c\n")
        view = editor(NoteContent(text: "x\nmot"))
        view.setSelectedRange(NSRange(location: 5, length: 0))
        type("\t", in: view)
        check("Retrait : Tab hors d'une liste est une tabulation", view.string == "x\nmot\t" && runs(view).isEmpty, "\(view.string) \(runs(view))")

        // Numbers that follow.
        view = editor(NoteContent(text: "x\n"))
        type("1. a\nb\nc", in: view)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        type("\nnouveau", in: view)
        check("Numéros : un élément inséré au milieu, les suivants suivent", view.string == "x\n1. a\n2. nouveau\n3. b\n4. c", view.string)
        check("Numéros : le curseur reste où l'on écrit", view.selectedRange().location == 17, "\(view.selectedRange())")
        view.undoManager?.undo()
        check("Numéros : annuler défait la frappe et les numéros ensemble", view.string == "x\n1. a\n2. nouveau\n3. b\n4. c".replacingOccurrences(of: "nouveau", with: "nouvea"), view.string)
        view = editor(NoteContent(text: "x\n"))
        type("1. a\nb\nc\nd", in: view)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        step(view) { view.changeIndent(by: 1) }
        check("Numéros : un élément en retrait recommence à 1, la liste du dessus continue", view.string == "x\n1. a\n1. b\n2. c\n3. d", view.string)
        view.setSelectedRange(NSRange(location: 12, length: 5))
        step(view) { view.delete(nil) }
        check("Numéros : une ligne supprimée, la suite se renumérote", view.string == "x\n1. a\n1. b\n2. d", view.string)
        view = editor(NoteContent(text: "x\n"))
        type("3. trois\nquatre", in: view)
        check("Numéros : une liste commence au numéro tapé", view.string == "x\n3. trois\n4. quatre", view.string)

        // What the search found, in the note.
        check("Recherche : mots trouvés dans la note, sans casse ni accent", Note.found(["ete", "LISBONNE"], in: "Été à Lisbonne, l'été") == [
            NSRange(location: 0, length: 3), NSRange(location: 6, length: 8), NSRange(location: 18, length: 3),
        ], "\(Note.found(["ete", "LISBONNE"], in: "Été à Lisbonne, l'été"))")
        view = editor(NoteContent(text: "Titre\nun mot, deux mots"))
        view.searchWords = ["mot"]
        let found = view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 9, effectiveRange: nil)
        let notFound = view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 6, effectiveRange: nil)
        check("Recherche : ce qui est trouvé est marqué dans la note, sans changer le texte", found != nil && notFound == nil && runs(view).isEmpty)
        view.searchWords = []
        check("Recherche : la marque s'en va avec la recherche", view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 9, effectiveRange: nil) == nil)

        // A note written in a hurry (menu bar, Raccourcis).
        let store = NoteStore(directory: nil)
        let model = NotesModel(store: store, settings: nil)
        check("Note rapide : rien d'écrit, rien d'ajouté", !model.addQuickNote("  \n ") && store.notes.isEmpty)
        check("Note rapide : ajoutée, la première ligne pour titre, le Markdown lu", model.addQuickNote("Idée\n- [ ] appeler **Léa**") && store.notes.count == 1
              && store.notes[0].title == "Idée" && store.notes[0].content.text == "Idée\n☐ appeler Léa"
              && store.notes[0].content.runs == [StyleRun(start: 0, length: 5, block: .title), StyleRun(start: 15, length: 3, bold: true)], "\(store.notes.first?.content ?? NoteContent())")
        check("Note rapide : la note ouverte reste ouverte", model.selectedID == nil || model.selectedID != store.notes[0].id)
        testWindow = nil
    }

    // MARK: Markdown

    private static func markdown() {
        let text = "Courses\n• pain\n• lait\n☐ œufs\n☑ café\n1. un\n2. deux\nTexte gras et lien, 2*3\ncitation\n---\nfin_de_ligne"
        func range(_ piece: String) -> NSRange { (text as NSString).range(of: piece) }
        func run(_ piece: String, _ make: (Int, Int) -> StyleRun) -> StyleRun { make(range(piece).location, range(piece).length) }
        let note = NoteContent(text: text, runs: [
            run("Courses\n") { StyleRun(start: $0, length: $1, block: .title) }, run("☐ œufs\n") { StyleRun(start: $0, length: $1, indent: 1) },
            run("gras") { StyleRun(start: $0, length: $1, bold: true) }, run(" et ") { StyleRun(start: $0 + 1, length: $1 - 2, italic: true) },
            run("lien") { StyleRun(start: $0, length: $1, link: "https://void.app") }, run("citation\n") { StyleRun(start: $0, length: $1, block: .quote) },
            run("---\n") { StyleRun(start: $0, length: $1, block: .divider) }, run("fin") { StyleRun(start: $0, length: $1, strike: true) },
        ])
        let written = NoteMarkdown.markdown(from: note)
        let expected = "# Courses\n\n- pain\n- lait\n    - [ ] œufs\n- [x] café\n1. un\n2. deux\n\nTexte **gras** *et* [lien](https://void.app), 2\\*3\n\n> citation\n\n---\n\n~~fin~~\\_de_ligne\n"
        check("Markdown : export d'une note", written == expected, "\n" + written)
        let back = NoteMarkdown.content(fromMarkdown: written)
        check("Markdown : aller-retour sans perte de mise en forme", back == note, "\(back.runs)")

        let pasted = NoteMarkdown.content(fromMarkdown: "## Plan\n\nPremier paragraphe avec `code` et ==surligné==.\n\nSecond, *ital* et __gras__.\n\n* un\n  * sous\n    1. a\n* deux\n- [X] fait\n\n> cité\n***\n```\nlet x = 1 **pas gras**\n```\n![photo](a.png) <https://exemple.fr> \\*pas italique\\*")
        check("Markdown : titres, paragraphes, listes imbriquées, citation, code", pasted.text == "Plan\nPremier paragraphe avec code et surligné.\n\nSecond, ital et gras.\n• un\n• sous\n1. a\n• deux\n☑ fait\ncité\n---\nlet x = 1 **pas gras**\nphoto https://exemple.fr *pas italique*", pasted.text)
        let attributed = NoteFormat.attributedString(from: pasted)
        let string = attributed.string as NSString
        func at(_ word: String) -> [NSAttributedString.Key: Any] { attributed.attributes(at: string.range(of: word).location, effectiveRange: nil) }
        check("Markdown : chaque marque donne sa mise en forme", NoteFormat.block(in: at("Plan")) == .heading && at("code")[NoteFormat.codeKey] != nil
              && at("surligné")[NoteFormat.highlightKey] != nil && at("ital")[NoteFormat.italicKey] != nil && at("gras.")[NoteFormat.boldKey] != nil
              && NoteFormat.indent(in: at("sous")) == 1 && NoteFormat.indent(in: at("1. a")) == 2 && NoteFormat.indent(in: at("deux")) == 0
              && NoteFormat.block(in: at("cité")) == .quote && NoteFormat.block(in: at("---")) == .divider
              && at("let x")[NoteFormat.codeKey] != nil && at("pas gras")[NoteFormat.boldKey] == nil
              && at("https://exemple.fr")[NoteFormat.linkKey] as? String == "https://exemple.fr" && at("pas italique")[NoteFormat.italicKey] == nil)
        check("Markdown : reconnu quand il y en a", NoteMarkdown.looksLikeMarkdown("# Titre") && NoteMarkdown.looksLikeMarkdown("Un **mot**")
              && NoteMarkdown.looksLikeMarkdown("- un\n- deux") && NoteMarkdown.looksLikeMarkdown("voir [ici](https://a.b)"))
        check("Markdown : pas pour du texte ordinaire", !NoteMarkdown.looksLikeMarkdown("2 * 3 = 6, nom_de_fichier et a == b")
              && !NoteMarkdown.looksLikeMarkdown("Bonjour,\nà demain.") && !NoteMarkdown.looksLikeMarkdown("#hashtag"))
        check("Markdown : la note rapide prend sa première ligne pour titre", NoteMarkdown.content(fromMarkdown: "Idée\nsuite", titled: true).runs == [StyleRun(start: 0, length: 5, block: .title)])
        check("Markdown : nom de fichier d'une note", NoteMarkdown.fileName(for: Note(content: NoteContent(text: "Projets / 2026 : idées?"))) == "Projets   2026   idées"
              && NoteMarkdown.fileName(for: Note()) == "Note")

        // Pasted in a note.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("# Liste\n- [ ] pain\n- **lait**", forType: .string)
        var view = editor(NoteContent(text: "x\n"))
        step(view) { view.paste(nil) }
        check("Coller : le Markdown arrive mis en forme", view.string == "x\nListe\n☐ pain\n• lait"
              && runs(view) == [StyleRun(start: 2, length: 6, block: .title), StyleRun(start: 17, length: 4, bold: true)], "\(view.string) \(runs(view))")
        view.undoManager?.undo()
        check("Coller : annulé d'un coup", view.string == "x\n", view.string)
        view = editor(NoteContent(text: "x\nAvant "))
        step(view) { view.paste(nil) }
        check("Coller : au milieu d'une ligne, la première ligne la continue", view.string == "x\nAvant Liste\n☐ pain\n• lait" && NoteFormat.block(in: view.textStorage!.attributes(at: 2, effectiveRange: nil)) == nil, view.string)
        view = editor(NoteContent(text: "x\n"))
        step(view) { view.pasteAsPlainText(nil) }
        check("Coller et adapter le style : les marques restent du texte", view.string == "x\n# Liste\n- [ ] pain\n- **lait**" && runs(view).isEmpty, view.string)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }

        // Exported to disk.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory.appendingPathComponent("notes"))
        let folder = store.createFolder(named: "Recettes")
        let plain = store.create(in: folder.id)
        store.update(plain.id, content: NoteContent(text: "Tarte\nPommes"))
        let withFile = store.create()
        store.update(withFile.id, content: NoteContent(text: "Photo"))
        store.addPhoto(Data([0x89, 0x50, 0x4E, 0x47]), named: "vue.png", to: withFile.id)
        let secret = store.create()
        store.update(secret.id, content: NoteContent(text: "Secret"))
        store.setLocked(true, for: secret.id)
        let out = directory.appendingPathComponent("export")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try? NoteExport.writeAll(store: store, in: out)
        let root = result?.folder
        let tarte = root.flatMap { try? String(contentsOf: $0.appendingPathComponent("Recettes/Tarte.md"), encoding: .utf8) }
        let photo = root.flatMap { try? String(contentsOf: $0.appendingPathComponent("Photo/Photo.md"), encoding: .utf8) }
        check("Export : une note par fichier, rangée dans son dossier", tarte == "Tarte\n\nPommes\n", tarte ?? "nil")
        check("Export : une note avec une image devient un dossier avec la copie", photo == "Photo\n\n![](fichiers/vue.png)\n"
              && root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Photo/fichiers/vue.png").path) } == true, photo ?? "nil")
        check("Export : les notes verrouillées sont laissées de côté et comptées", result?.locked == 1
              && root.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("Secret.md").path) } == true)
        let again = try? NoteExport.writeAll(store: store, in: out)
        check("Export : un second export ne remplace pas le premier", again?.folder != root && again?.folder.lastPathComponent.hasSuffix(" 2") == true, again?.folder.path ?? "nil")
    }
}
#endif
