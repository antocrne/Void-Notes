import Foundation
import Observation

/// What the window shows: the note being written, the search, the deletion waiting for its
/// confirmation.
@MainActor @Observable
final class NotesModel {
    static let shared = NotesModel(store: .shared, settings: .shared)

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let settings: AppSettings?

    #if os(macOS)
    /// The text view of the note being shown: what the formatting panel acts on.
    @ObservationIgnored weak var editor: NoteTextView?
    /// The window always shows a note: when the one it shows goes, its neighbor takes its place.
    static let keepsANoteOpen = true
    #else
    /// On iPhone a note that goes leaves the list in its place.
    static let keepsANoteOpen = false
    #endif

    /// Leaving a note locks it again.
    private(set) var selectedID: UUID? {
        didSet { if selectedID != oldValue { relock() } }
    }
    /// The locked notes shown for now: unlocked with Touch ID, until they are left.
    private(set) var unlocked: Set<UUID> = []
    /// Asks who is at the Mac (see `NoteLock`); replaced in the tests.
    @ObservationIgnored var authenticate: NoteLock.Authenticator = NoteLock.authenticate
    @ObservationIgnored var canAuthenticate: () -> Bool = { NoteLock.isAvailable }
    /// The space the list shows.
    private(set) var currentSpaceID: UUID
    /// "Toutes les notes" is unfolded: every note of the space shows under it, whatever its folder.
    private(set) var showsAllNotes = false
    /// "Corbeille" is unfolded: the deleted notes of the space show under it.
    private(set) var showsTrash = false
    /// "Archives" is unfolded: the archived notes of the space show under it.
    private(set) var showsArchive = false
    /// The trash of the current space is about to be emptied: waiting for its confirmation.
    var confirmingEmptyTrash = false
    /// The note each space was showing when it was left, to come back to it.
    @ObservationIgnored private var lastNote: [UUID: UUID] = [:]
    var query = "" {
        didSet { if query != oldValue { clearSelection() } }
    }
    /// Notes and folders picked together in the list (⌘-click, ⇧-click, or the menu), to be
    /// moved or deleted at once. Empty most of the time: a plain click goes back to one note.
    private(set) var selection: Set<UUID> = []
    /// The line the last pick was made on: where a ⇧-click starts from.
    @ObservationIgnored private var anchorRow: String?
    /// The selection has folders in it and is about to be deleted: waiting for its confirmation.
    var confirmingSelectionDeletion = false
    /// Folders unfolded in the list: their subfolders and notes show under them.
    private(set) var expanded: Set<UUID> = []
    /// Notes being dragged from the list, on their way to a folder: one, or those of the selection.
    private(set) var draggedNoteIDs: [UUID] = []
    /// Folders being dragged from the list, on their way into another one (or to the top).
    private(set) var draggedFolderIDs: [UUID] = []
    /// Folder whose deletion is being confirmed.
    var pendingFolderDeletion: Folder?
    /// Folder whose name is being typed in the list.
    var renamingFolderID: UUID?
    /// Trashed note whose deletion for good is being confirmed.
    var pendingDeletion: Note?
    /// Changes each time the search field should take the keyboard (⌘F).
    private(set) var searchFocusRequest = 0
    /// Changes each time the note's text should take the keyboard.
    private(set) var editorFocusRequest = 0
    /// Changes when the link of the selection is to be written (⌘K): the formatting panel opens
    /// on its address.
    var linkRequest = 0
    /// Someone is typing in the note: what surrounds the text fades away, until the pointer moves
    /// (Mac) or the note is scrolled or touched outside the keyboard (iPhone).
    var writing = false
    /// The note just put in the trash, which « Annuler » takes back (iPhone).
    private(set) var lastTrashed: Note?

    init(store: NoteStore, settings: AppSettings?) {
        self.store = store
        self.settings = settings
        expanded = Set((settings?.expandedFolders ?? []).compactMap(UUID.init(uuidString:)).filter { store.folder($0) != nil })
        showsAllNotes = settings?.showsAllNotes ?? false
        // The note left open last time, in its space — or the most recent one of the space last
        // shown. The note is shown in its folder.
        let last = store.note(settings?.lastNoteID.flatMap(UUID.init(uuidString:)))
        let space = last?.space ?? settings?.currentSpace.flatMap(UUID.init(uuidString:))
        currentSpaceID = store.space(space)?.id ?? store.spaces[0].id
        selectedID = Self.keepsANoteOpen ? last?.id ?? firstNote(in: currentSpaceID) : nil
        reveal(selectedID)
    }

    /// The most recent note of a space that isn't archived: the one shown when nothing else is.
    private func firstNote(in space: UUID, except note: UUID? = nil) -> UUID? {
        guard Self.keepsANoteOpen else { return nil }
        return store.notes(inSpace: space).first { !$0.archived && $0.id != note }?.id
    }

    /// The archived notes of the current space, most recently modified first.
    var archivedNotes: [Note] { store.notes(inSpace: currentSpaceID).filter(\.archived) }

    /// The note being shown: one of the list, or one of the trash (read only).
    var selected: Note? { store.note(selectedID) ?? store.trashed(selectedID) }

    /// The list starts with "Toutes les notes" (Réglages).
    var showsAllNotesRow: Bool { settings?.showsAllNotesRow ?? true }

    /// The deleted notes of the current space, most recently deleted first.
    var trashedNotes: [Note] { store.trash.filter { $0.space == currentSpaceID } }

    var currentSpace: Space { store.space(currentSpaceID) ?? store.spaces[0] }

    /// One line of the list: "Toutes les notes", a folder, or a note, `depth` folders deep.
    enum Row: Identifiable {
        case allNotes
        case folder(Folder, depth: Int)
        /// `inAll`: under "Toutes les notes" (the note may show a second time, in its folder).
        case note(Note, depth: Int, inAll: Bool = false)
        /// "Archives": the notes under it are `.note` lines, like the others.
        case archive
        case trash
        case trashed(Note)

        var id: String {
            switch self {
            case .archive: "archive"
            case .allNotes: "all"
            case .folder(let folder, _): folder.id.uuidString
            case .note(let note, _, let inAll): (inAll ? "all-" : "") + note.id.uuidString
            case .trash: "trash"
            case .trashed(let note): note.id.uuidString
            }
        }

        /// What the line stands for, when it can be part of a selection: a note or a folder.
        var item: UUID? {
            switch self {
            case .folder(let folder, _): folder.id
            case .note(let note, _, _): note.id
            case .allNotes, .archive, .trash, .trashed: nil
            }
        }
    }

    /// The list of the current space, as a tree: first the pinned notes, out of their folders;
    /// "Toutes les notes" (unless Réglages hides it), which unfolds to every note of the space,
    /// the pinned ones first; the folders by name, each unfolded one followed by its subfolders
    /// then its notes; after the folders, the notes that are in none. Notes are most recently
    /// modified first. Last, apart, "Archives" then "Corbeille", when there is something in them: archived
    /// notes show nowhere else. An empty space has no line at all.
    var rows: [Row] {
        var rows: [Row] = []
        let notes = store.notes(inSpace: currentSpaceID).filter { !$0.archived }
        let archived = archivedNotes
        let deleted = trashedNotes
        var trash: [Row] = archived.isEmpty ? [] : [.archive]
        if showsArchive { trash += archived.map { .note($0, depth: 1) } }
        if !deleted.isEmpty { trash.append(.trash) }
        if showsTrash { trash += deleted.map { .trashed($0) } }
        let folders = store.folders.filter { $0.space == currentSpaceID }
        guard !folders.isEmpty || !notes.isEmpty else { return trash }
        let pinned = notes.filter(\.pinned)
        rows += pinned.map { .note($0, depth: 0) }
        if showsAllNotesRow {
            rows.append(.allNotes)
            if showsAllNotes { rows += (pinned + notes.filter { !$0.pinned }).map { .note($0, depth: 1, inAll: true) } }
        }
        let known = Set(folders.map(\.id))
        func add(_ parent: UUID?, _ depth: Int) {
            for folder in folders.filter({ $0.parent == parent }).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                rows.append(.folder(folder, depth: depth))
                if expanded.contains(folder.id) { add(folder.id, depth + 1) }
            }
            // The notes under the folders. A note whose folder is gone is in none.
            for note in notes where !note.pinned && note.folder.flatMap({ known.contains($0) ? $0 : nil }) == parent {
                rows.append(.note(note, depth: depth))
            }
        }
        add(nil, 0)
        return rows + trash
    }

    /// The notes one can go through: those the list shows, in its order (each one once) — or
    /// what the search finds, in every folder of the space, the pinned notes first.
    var visibleNotes: [Note] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if !words.isEmpty {
            let names = folderNames(in: currentSpaceID)
            let found = store.notes(inSpace: currentSpaceID).filter { $0.matches(words, alsoIn: $0.folder.flatMap { names[$0] } ?? []) }
            return found.filter(\.pinned) + found.filter { !$0.pinned }
        }
        var seen: Set<UUID> = []
        return rows.compactMap { if case .note(let note, _, _) = $0, seen.insert(note.id).inserted { note } else { nil } }
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What the search reads besides a note's text: for each folder of the space, its name and
    /// those of the folders it is in — a folder's name finds the notes of its subfolders too.
    /// (Tags, if they come, would be read the same way.)
    private func folderNames(in space: UUID) -> [UUID: [String]] {
        var names: [UUID: [String]] = [:]
        // Each folder comes after the one it is in.
        for row in store.folderRows(in: space) {
            names[row.folder.id] = [row.folder.name] + (row.folder.parent.flatMap { names[$0] } ?? [])
        }
        return names
    }

    /// The lines on screen: the tree, or — while searching — what was found, flat.
    var listRows: [Row] { isSearching ? visibleNotes.map { .note($0, depth: 0) } : rows }

    // MARK: Selection of several notes and folders

    /// The notes of the selection, in the order of the store.
    var selectedNotes: [Note] { selection.isEmpty ? [] : store.notes(inSpace: currentSpaceID).filter { selection.contains($0.id) } }
    /// The folders of the selection.
    var selectedFolders: [Folder] { selection.isEmpty ? [] : store.folders.filter { $0.space == currentSpaceID && selection.contains($0.id) } }
    var selectionCount: Int { selectedNotes.count + selectedFolders.count }

    /// The line wears the selection: picked — or, when nothing is, the note being shown.
    func isHighlighted(_ item: UUID) -> Bool { selection.isEmpty ? item == selectedID : selection.contains(item) }

    /// Part of a selection of several: what is asked of it is asked of all.
    func isInMultipleSelection(_ item: UUID) -> Bool { selection.contains(item) && selectionCount > 1 }

    /// ⌘-click: adds a note or a folder to the selection, or takes it out. A selection started
    /// on a note has the note being shown as its first, as long as the list shows it.
    func toggleSelection(_ item: UUID, row: String) {
        if selection.isEmpty, store.note(item) != nil, let shown = store.note(selectedID), !shown.isBlank, shown.id != item,
           listRows.contains(where: { $0.item == shown.id }) {
            selection.insert(shown.id)
        }
        if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
        anchorRow = row
    }

    /// ⇧-click: selects every note and folder between the last line picked (or the note being
    /// shown) and this one.
    func extendSelection(to row: String) {
        let rows = listRows
        guard let end = rows.firstIndex(where: { $0.id == row }), rows[end].item != nil else { return }
        let start = anchorRow.flatMap { anchor in rows.firstIndex { $0.id == anchor } }
            ?? rows.firstIndex { $0.item != nil && $0.item == selectedID }
        guard let start else {
            selection = Set([rows[end].item].compactMap { $0 })
            anchorRow = row
            return
        }
        if anchorRow == nil { anchorRow = rows[start].id }
        selection = Set(rows[min(start, end)...max(start, end)].compactMap(\.item))
    }

    func clearSelection() {
        selection = []
        anchorRow = nil
    }

    /// Files the selection in a folder (nil: in none), which unfolds to show it. A folder goes
    /// with what is in it; the folder itself, or one of its subfolders, stays where it is.
    func moveSelection(to folder: UUID?) {
        let (notes, folders) = selectionRoots
        for note in notes { store.move(note.id, to: folder) }
        for moved in folders { store.moveFolder(moved.id, to: folder) }
        expand(folder)
    }

    /// Whether the selection can be filed in that folder: it isn't one of the selected folders,
    /// nor in one of them.
    func canMoveSelection(to folder: UUID?) -> Bool {
        guard let folder else { return true }
        return !selectedFolders.contains { store.subtree(of: $0.id).contains(folder) }
    }

    /// Sends the selection to another space. A folder goes with what is in it: only the folders
    /// that are in no other selected folder, and the notes that are in none of them, are moved.
    func moveSelection(toSpace space: UUID) {
        let (notes, folders) = selectionRoots
        clearSelection()
        for note in notes { move(note.id, toSpace: space) }
        for folder in folders { move(folder, toSpace: space) }
    }

    /// Notes go to the trash without a question; folders are deleted, and that is asked first.
    func askToDeleteSelection() {
        if selectedFolders.isEmpty { deleteSelection() } else { confirmingSelectionDeletion = true }
    }

    /// The notes of the selection go to the trash, then its folders are removed (the notes left
    /// in them go to the folder above).
    func deleteSelection() {
        confirmingSelectionDeletion = false
        let notes = selectedNotes, folders = selectedFolders
        clearSelection()
        for note in notes { delete(note) }
        for folder in folders where store.folder(folder.id) != nil { delete(folder) }
    }

    private var selectionRoots: (notes: [Note], folders: [Folder]) {
        let folders = selectedFolders
        let roots = folders.filter { folder in
            !folders.contains { $0.id != folder.id && store.subtree(of: $0.id).contains(folder.id) }
        }
        let covered = roots.reduce(into: Set<UUID>()) { $0.formUnion(store.subtree(of: $1.id)) }
        return (selectedNotes.filter { $0.folder.map(covered.contains) != true }, roots)
    }

    // MARK: Actions

    func select(_ id: UUID?) {
        clearSelection()
        guard id != selectedID else { return }
        discardIfBlank(selectedID)
        selectedID = id
        settings?.lastNoteID = id?.uuidString
    }

    /// Opens a note from the list and puts the cursor in it.
    func open(_ id: UUID) {
        select(id)
        // Found by the search in a folded folder: it will be in view when the search ends.
        reveal(id)
        editorFocusRequest += 1
    }

    /// A new note next to the one being read: in the same folder.
    func newNote() {
        let near = store.note(selectedID)
        #if BETA
        newNote(in: near?.space == currentSpaceID ? openPart(of: near?.folder) : nil)
        #else
        newNote(in: near?.space == currentSpaceID ? near?.folder : nil)
        #endif
    }

    #if BETA
    /// The deepest folder of that one's path that the list shows open: a folder closed since
    /// keeps the new note out, and with every folder closed it is in none.
    private func openPart(of folder: UUID?) -> UUID? {
        var path: [UUID] = []
        var next = store.folder(folder)
        // `count`: a file edited by hand could make a folder its own ancestor.
        while let folder = next, path.count <= store.folders.count {
            path.append(folder.id)
            next = store.folder(folder.parent)
        }
        return path.reversed().prefix { expanded.contains($0) }.last
    }
    #endif

    func newNote(in folder: UUID?) {
        let folder = store.folder(folder)?.id
        // Already on an empty note of that folder: that's the new note.
        if selected?.isBlank != true || selected?.folder != folder || selected?.space != currentSpaceID || selected?.deleted != nil {
            // A new note wouldn't match the search and would be missing from the list.
            query = ""
            select(store.create(in: folder, space: currentSpaceID).id)
        }
        reveal(selectedID)
        editorFocusRequest += 1
    }

    /// A note sent by another app (see NoteImport): created in the space shown, out of any
    /// folder, and opened. false: the URL isn't a note.
    @discardableResult
    func importNote(from url: URL) -> Bool {
        let image = NoteImport.image(for: url)
        guard NoteImport.content(from: url, image: image?.name) != nil else { return false }
        // `voidnotes://append`: at the end of that note — or, if it is gone, locked or can't be
        // written, in a new one, so that nothing sent is lost.
        let target = NoteImport.target(of: url).flatMap(store.note).flatMap { $0.locked || $0.isReadOnly ? nil : $0 }
        // The note wouldn't match the search and would be missing from the list.
        query = ""
        if let space = target?.space, space != currentSpaceID { switchSpace(to: space) }
        let note = target ?? store.create(space: currentSpaceID)
        // The image goes into the folder of the note, which exists from now on.
        let attached = image.flatMap { store.attach($0.data, named: $0.name, to: note.id) }
        let clip = NoteImport.content(from: url, image: attached, appended: target != nil) ?? NoteContent()
        if target != nil { store.append(clip, to: note.id) } else { store.update(note.id, content: clip) }
        select(note.id)
        reveal(note.id)
        editorFocusRequest += 1
        #if os(macOS)
        // What was added is at the end: in view once the note is shown anew.
        if target != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, selectedID == note.id else { return }
                editor?.scrollRangeToVisible(editor?.selectedRange() ?? NSRange())
            }
        }
        #endif
        NoteDirectory.publish(store)
        return true
    }

    /// A note written in a hurry — from the menu bar, Raccourcis or Siri — read as Markdown, its
    /// first line its title: added to the space shown, out of any folder, without leaving the
    /// note being written. false: nothing was written.
    @discardableResult
    func addQuickNote(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let note = store.create(space: currentSpaceID)
        store.update(note.id, content: NoteMarkdown.content(fromMarkdown: text, titled: true))
        store.flush()
        return true
    }

    /// The note being shown goes to the trash, without a question: it can be taken back. From
    /// the trash, deleting is for good, and asked first.
    func askToDeleteSelected() {
        guard let selected else { return }
        clearSelection()
        if selected.deleted != nil { pendingDeletion = selected } else { delete(selected) }
    }

    /// Puts the note in the trash — or, for a note that is there already, deletes it for good —
    /// and shows its neighbor in the list.
    func delete(_ note: Note) {
        pendingDeletion = nil
        let trashed = store.trashed(note.id) != nil
        // A later version's note stays (the store says why): the list doesn't move.
        if !trashed, let current = store.note(note.id), current.isReadOnly, !current.isBlank { return store.moveToTrash(note.id) }
        let next = note.id != selectedID ? nil : trashed ? firstNote(in: currentSpaceID) : neighbor(of: note.id)
        if trashed { store.delete(note.id) } else { store.moveToTrash(note.id) }
        lastTrashed = trashed || note.isBlank ? nil : note
        if note.id == selectedID {
            selectedID = next
            settings?.lastNoteID = next?.uuidString
        }
        if trashedNotes.isEmpty { showsTrash = false }
    }

    /// « Annuler » after a note went to the trash: it is back where it was, the list doesn't move.
    func undoLastTrash() {
        guard let note = lastTrashed else { return }
        lastTrashed = nil
        store.restore(note.id)
        if trashedNotes.isEmpty { showsTrash = false }
    }

    /// The « Annuler » offer has had its time.
    func forgetLastTrash(_ note: Note) {
        if lastTrashed?.id == note.id { lastTrashed = nil }
    }

    /// Takes a note out of the trash and opens it where it is back.
    func restore(_ note: Note) {
        store.restore(note.id)
        if trashedNotes.isEmpty { showsTrash = false }
        guard let restored = store.note(note.id) else { return }
        if restored.space != currentSpaceID, let space = restored.space { switchSpace(to: space) }
        open(restored.id)
    }

    /// Unfolds or folds "Corbeille".
    func toggleTrash() {
        showsTrash.toggle()
    }

    /// Deletes for good everything in the trash of the current space.
    func emptyTrash() {
        confirmingEmptyTrash = false
        if store.trashed(selectedID) != nil {
            selectedID = firstNote(in: currentSpaceID)
            settings?.lastNoteID = selectedID?.uuidString
        }
        store.emptyTrash(of: currentSpaceID)
        showsTrash = false
    }

    // MARK: Archive

    /// Unfolds or folds "Archives".
    func toggleArchive() {
        showsArchive.toggle()
    }

    /// Puts a note away under "Archives"; the list shows its neighbor.
    func archive(_ id: UUID) {
        guard let note = store.note(id), !note.archived else { return }
        // Its neighbor among the notes that aren't archived, even with "Archives" unfolded.
        let list = visibleNotes.filter { !$0.archived || $0.id == id }
        let index = list.firstIndex { $0.id == id }
        let next = !Self.keepsANoteOpen ? nil : index.map { $0 + 1 < list.count ? list[$0 + 1].id : $0 > 0 ? list[$0 - 1].id : nil } ?? firstNote(in: currentSpaceID, except: id)
        store.setArchived(true, for: id)
        guard store.note(id)?.archived == true, id == selectedID else { return }
        selectedID = next
        settings?.lastNoteID = next?.uuidString
    }

    /// Takes a note back from the archive, to the folder it was in, which unfolds.
    func unarchive(_ id: UUID) {
        store.setArchived(false, for: id)
        reveal(id)
    }

    /// The notes of the selection go to the archive.
    func archiveSelection() {
        let notes = selectedNotes
        clearSelection()
        for note in notes { archive(note.id) }
    }

    /// ⌃⌘A: the selection, or the note in the window — archived, or taken back if it was.
    func toggleArchived() {
        if selectionCount > 1 { return archiveSelection() }
        guard let selected, selected.deleted == nil else { return }
        if selected.archived { unarchive(selected.id) } else { archive(selected.id) }
    }

    // MARK: Pin

    /// Pins a note at the top of the list — or unpins it: it goes back among the notes of its
    /// folder, which unfolds.
    func setPinned(_ pinned: Bool, for id: UUID) {
        store.setPinned(pinned, for: id)
        if !pinned { reveal(id) }
    }

    /// The notes of the selection are pinned — or unpinned, when they all were.
    func pinSelection() {
        let notes = selectedNotes.filter { !$0.archived }
        let pin = notes.contains { !$0.pinned }
        clearSelection()
        for note in notes { setPinned(pin, for: note.id) }
    }

    /// ⌃⌘P: the selection, or the note in the window — pinned, or unpinned if it was.
    func togglePinned() {
        if selectionCount > 1 { return pinSelection() }
        guard let selected, selected.deleted == nil, !selected.archived else { return }
        setPinned(!selected.pinned, for: selected.id)
    }

    // MARK: Lock

    /// The note is locked and hasn't been unlocked: nothing of it shows but its title.
    func isConcealed(_ note: Note) -> Bool { note.locked && !unlocked.contains(note.id) }

    /// Locks a note — one that is locked already and open is hidden again. No question asked:
    /// it is to open it that Touch ID is needed.
    func lock(_ id: UUID) {
        guard let note = store.note(id) else { return }
        if !note.locked {
            guard canAuthenticate() else {
                #if os(macOS)
                store.errorMessage = String(localized: "Cette note ne pourrait plus être déverrouillée : ce Mac n'a ni Touch ID ni mot de passe de session.")
                #else
                store.errorMessage = String(localized: "Cette note ne pourrait plus être déverrouillée : cet iPhone n'a ni Face ID ni code.")
                #endif
                return
            }
            store.setLocked(true, for: id)
        }
        unlocked.remove(id)
    }

    /// Shows a locked note, once Touch ID (or the Mac's password) has said yes — if it is still
    /// the note in the window by then.
    func unlock(_ id: UUID) {
        guard let note = store.note(id) ?? store.trashed(id), isConcealed(note) else { return }
        authenticate(String(localized: "déverrouiller une note")) { [weak self] success in
            guard let self, success, self.selectedID == id, (self.store.note(id) ?? self.store.trashed(id))?.locked == true else { return }
            self.unlocked.insert(id)
            self.editorFocusRequest += 1
        }
    }

    /// Takes the lock off a note for good. Asked of a note that isn't open, it is confirmed with
    /// Touch ID first.
    func removeLock(_ id: UUID) {
        guard let note = store.note(id), note.locked else { return }
        guard isConcealed(note) else {
            unlocked.remove(id)
            return store.setLocked(false, for: id)
        }
        authenticate(String(localized: "retirer le verrou d'une note")) { [weak self] success in
            if success { self?.store.setLocked(false, for: id) }
        }
    }

    /// ⇧⌘L on the note in the window: locks it, or unlocks it if it is hidden.
    func toggleLock() {
        guard let selected else { return }
        if isConcealed(selected) { unlock(selected.id) } else { lock(selected.id) }
    }

    /// Every locked note is hidden again: the note is left, the screen sleeps or is locked.
    func relock() {
        if !unlocked.isEmpty { unlocked = [] }
    }

    // MARK: Spaces

    /// Shows another space: its folders, its notes, and the note it was showing last.
    func switchSpace(to space: UUID) {
        guard space != currentSpaceID, store.space(space) != nil else { return }
        clearSelection()
        lastNote[currentSpaceID] = selectedID
        query = ""
        renamingFolderID = nil
        // First: leaving an empty note deletes it, while it still belongs to the space shown.
        let notes = store.notes(inSpace: space)
        select(Self.keepsANoteOpen ? notes.first { $0.id == lastNote[space] }?.id ?? firstNote(in: space) : nil)
        currentSpaceID = space
        settings?.currentSpace = space.uuidString
        reveal(selectedID)
    }

    /// Previous (-1) or next (+1) space, without going round.
    func stepSpace(_ offset: Int) {
        guard let index = store.spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        switchSpace(to: store.spaces[min(max(index + offset, 0), store.spaces.count - 1)].id)
    }

    /// A new, empty space, shown at once.
    func newSpace(named name: String, icon: String) {
        settings?.showsSidebar = true
        switchSpace(to: store.createSpace(named: name, icon: icon).id)
    }

    /// Removes a space; what was in it goes to the first of the others.
    func delete(_ space: Space) {
        guard store.spaces.count > 1 else { return }
        if space.id == currentSpaceID, let other = store.spaces.first(where: { $0.id != space.id }) { switchSpace(to: other.id) }
        lastNote[space.id] = nil
        store.deleteSpace(space.id)
    }

    /// Sends a note to another space. The list stays where it is and shows the note's neighbor.
    func move(_ note: UUID, toSpace space: UUID) {
        let neighbor = self.neighbor(of: note)
        store.move(note, toSpace: space)
        guard note == selectedID, store.note(note)?.space != currentSpaceID else { return }
        selectedID = neighbor
        settings?.lastNoteID = neighbor?.uuidString
    }

    /// Sends a folder, with everything in it, to another space.
    func move(_ folder: Folder, toSpace space: UUID) {
        store.moveFolder(folder.id, toSpace: space)
        if let selected, selected.space != currentSpaceID {
            selectedID = firstNote(in: currentSpaceID)
            settings?.lastNoteID = selectedID?.uuidString
        }
    }

    /// Unfolds or folds "Toutes les notes".
    func toggleAllNotes() {
        showsAllNotes.toggle()
        settings?.showsAllNotes = showsAllNotes
    }

    /// The note the list shows next to this one: the one after it, or else the one before. For a
    /// note the list doesn't show (its folder was folded), the most recent other one of the space.
    private func neighbor(of note: UUID) -> UUID? {
        let list = visibleNotes
        guard Self.keepsANoteOpen else { return nil }
        guard let index = list.firstIndex(where: { $0.id == note }) else {
            return firstNote(in: currentSpaceID, except: note)
        }
        return index + 1 < list.count ? list[index + 1].id : index > 0 ? list[index - 1].id : nil
    }

    // MARK: Folders

    /// Unfolds or folds a folder.
    func toggle(_ folder: UUID) {
        clearSelection()
        if expanded.contains(folder) { expanded.remove(folder) } else { expanded.insert(folder) }
        saveExpanded()
    }

    /// A new folder, its name ready to be typed.
    func newFolder(in parent: UUID? = nil) {
        settings?.showsSidebar = true
        query = ""
        expand(parent)
        renamingFolderID = store.createFolder(in: parent, space: currentSpaceID).id
    }

    func delete(_ folder: Folder) {
        pendingFolderDeletion = nil
        expanded.subtract(store.subtree(of: folder.id))
        store.deleteFolder(folder.id)
        saveExpanded()
    }

    /// Files a note in a folder (nil: in none), which unfolds to show it.
    func move(_ note: UUID, to folder: UUID?) {
        store.move(note, to: folder)
        expand(store.note(note)?.folder)
    }

    /// Files a folder in another one (nil: at the top of the list), which unfolds to show it.
    func moveFolder(_ folder: UUID, to parent: UUID?) {
        guard store.moveFolder(folder, to: parent) else { return }
        expand(parent)
    }

    /// The folders a folder can be filed in: all those of its space but itself and its subfolders.
    func destinations(for folder: Folder) -> [(folder: Folder, depth: Int)] {
        let inside = store.subtree(of: folder.id)
        return store.folderRows(in: folder.space).filter { !inside.contains($0.folder.id) }
    }

    /// A note leaves the list under the pointer — with the other notes of the selection, when
    /// it is one of several.
    func beginDrag(_ note: UUID) {
        if isInMultipleSelection(note) { beginDraggingSelection() } else {
            draggedNoteIDs = [note].filter { store.note($0)?.isReadOnly == false }
            draggedFolderIDs = []
        }
    }

    /// A folder leaves the list under the pointer — with the rest of the selection, when it is
    /// one of several.
    func beginDrag(folder: UUID) {
        if isInMultipleSelection(folder) { beginDraggingSelection() } else {
            draggedNoteIDs = []
            draggedFolderIDs = [folder]
        }
    }

    private func beginDraggingSelection() {
        let (notes, folders) = selectionRoots
        draggedNoteIDs = notes.map(\.id).filter { store.note($0)?.isReadOnly == false }
        draggedFolderIDs = folders.map(\.id)
    }

    /// Whether what is dragged can be dropped on that folder: no folder goes into itself.
    func canDrop(on folder: UUID?) -> Bool {
        guard let folder else { return true }
        return !draggedFolderIDs.contains { store.subtree(of: $0).contains(folder) }
    }

    /// The dragged notes and folders are dropped on a folder (nil: out of every folder). A folder
    /// dropped on itself, or on one of its subfolders, stays where it is.
    @discardableResult
    func drop(on folder: UUID?) -> Bool {
        guard !draggedNoteIDs.isEmpty || !draggedFolderIDs.isEmpty, canDrop(on: folder) else { return false }
        let notes = draggedNoteIDs, folders = draggedFolderIDs
        draggedNoteIDs = []
        draggedFolderIDs = []
        for note in notes { move(note, to: folder) }
        for moved in folders { moveFolder(moved, to: folder) }
        return true
    }

    /// Unfolds what hides the note: its folder — or "Archives".
    private func reveal(_ note: UUID?) {
        if store.note(note)?.archived == true { showsArchive = true } else { expand(store.note(note)?.folder) }
    }

    /// Unfolds the folder and those it is in.
    private func expand(_ folder: UUID?) {
        var next = store.folder(folder)
        var added = false
        // `count`: a file edited by hand could make a folder its own ancestor.
        var count = 0
        while let folder = next, count <= store.folders.count {
            added = expanded.insert(folder.id).inserted || added
            next = store.folder(folder.parent)
            count += 1
        }
        if added { saveExpanded() }
    }

    private func saveExpanded() {
        settings?.expandedFolders = expanded.map(\.uuidString).sorted()
    }

    /// Previous (-1) or next (+1) note of the list.
    func step(_ offset: Int) {
        let list = visibleNotes
        guard !list.isEmpty else { return }
        guard let index = list.firstIndex(where: { $0.id == selectedID }) else { return select(list[0].id) }
        select(list[min(max(index + offset, 0), list.count - 1)].id)
    }

    func focusSearch() {
        settings?.showsSidebar = true
        searchFocusRequest += 1
    }

    /// Leaves the search and goes back to the text.
    func endSearch() {
        query = ""
        editorFocusRequest += 1
    }

    /// Another device changed the notes (see `SyncEngine`): what the window was showing may be
    /// gone, or elsewhere.
    func storeChanged() {
        if store.space(currentSpaceID) == nil {
            currentSpaceID = store.spaces[0].id
            settings?.currentSpace = currentSpaceID.uuidString
        }
        lastNote = lastNote.filter { store.space($0.key) != nil }
        if selectedID != nil, selected.map({ $0.space != currentSpaceID }) ?? true {
            selectedID = firstNote(in: currentSpaceID)
            settings?.lastNoteID = selectedID?.uuidString
        }
        let folders = Set(store.folders.map(\.id))
        if !expanded.isSubset(of: folders) {
            expanded.formIntersection(folders)
            saveExpanded()
        }
        if selection.contains(where: { store.note($0) == nil && !folders.contains($0) }) { clearSelection() }
        if let id = renamingFolderID, !folders.contains(id) { renamingFolderID = nil }
        if let folder = pendingFolderDeletion, !folders.contains(folder.id) { pendingFolderDeletion = nil }
        if let note = pendingDeletion, store.trashed(note.id) == nil { pendingDeletion = nil }
        if trashedNotes.isEmpty { showsTrash = false }
        if archivedNotes.isEmpty { showsArchive = false }
    }

    /// Before quitting: nothing empty is left behind, and everything typed is on disk.
    func prepareToQuit() {
        discardIfBlank(selectedID)
        store.flush()
    }

    /// A note left without any text isn't kept.
    private func discardIfBlank(_ id: UUID?) {
        if let note = store.note(id), note.isBlank, !note.isReadOnly { store.delete(note.id) }
    }
}
