import Foundation
import Observation

/// A note as it is written: in its own file and, when the notes are synchronised, in the
/// snapshot of the shared folder (see `SyncPayload`).
struct NoteFile: Codable, Equatable {
    var version = NoteStore.formatVersion
    var id: UUID
    var created: Date
    var modified: Date
    var text: String
    var runs: [StyleRun]
    var folder: UUID?
    var space: UUID?
    var deleted: Date?
    var photos: [String]?
    var locked: Bool?
    var archived: Bool?
    var pinned: Bool?

    init(_ note: Note) {
        id = note.id
        created = note.created
        modified = note.modified
        text = note.content.text
        runs = note.content.runs
        folder = note.folder
        space = note.space
        deleted = note.deleted
        photos = note.photos.isEmpty ? nil : note.photos
        locked = note.locked ? true : nil
        archived = note.archived ? true : nil
        pinned = note.pinned ? true : nil
    }

    var note: Note {
        var note = Note(id: id, created: created, modified: modified, content: NoteContent(text: text, runs: runs), folder: folder, space: space)
        note.isReadOnly = version > NoteStore.formatVersion
        note.deleted = deleted
        note.photos = photos ?? []
        note.locked = locked ?? false
        note.archived = archived ?? false
        note.pinned = pinned ?? false
        return note
    }
}

/// The notes, kept on this Mac: one small JSON file per note in the app's container
/// (~/Library/Containers/app.void.notes/Data/Library/Application Support/Void Notes/notes/).
/// No account, no permission; nothing leaves the Mac unless a shared folder is chosen (see
/// `SyncEngine`): the container stays what the app reads and writes, the folder is merged with it.
///
/// One file per note rather than a single file: saving while typing rewrites only the note being
/// written, and a damaged file costs one note, not all of them. A file that can't be read is
/// never overwritten: it's moved to `illisibles/`. A file written by a later version of the app
/// is shown but never rewritten.
@MainActor @Observable
final class NoteStore {
    /// 2: dividers, highlighting, weights. 3: the note's folder. 4: its space. 5: the trash and
    /// attachments. 6: the "Source :" line. 7: the album of images. 8: locked notes. 9: archived notes. 10: links. 11: pinned notes. 12: struck-through text, inline code, indented list items. Earlier files
    /// read as they are.
    nonisolated static let formatVersion = 12
    /// A note stays this long in the trash before it is deleted for good.
    nonisolated static let trashDays = 30
    /// Typing pauses this long before the note is written.
    nonisolated static let saveDelay = 0.4

    static let shared: NoteStore = {
        #if DEBUG
        if DebugLaunch.isRequested { return NoteStore(directory: nil, notes: DebugLaunch.demoNotes, folders: DebugLaunch.demoFolders, spaces: DebugLaunch.demoSpaces) }
        #endif
        return NoteStore(directory: defaultDirectory)
    }()

    /// Most recently modified first.
    private(set) var notes: [Note] = []
    /// The notes in the trash, most recently deleted first. They are in none of the lists above.
    private(set) var trash: [Note] = []
    /// Folders and subfolders, in no particular order (see `folderRows`).
    private(set) var folders: [Folder] = []
    /// The spaces, in the order they were made. Never empty.
    private(set) var spaces: [Space] = []
    /// Files set aside at launch because they couldn't be read.
    private(set) var unreadable = 0
    /// A note couldn't be written or deleted.
    var errorMessage: String?

    /// nil: kept in memory only (demo and tests).
    @ObservationIgnored let directory: URL?
    @ObservationIgnored private var unsaved: Set<UUID> = []
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    /// Called as soon as something kept here changes (a note, the folders, the spaces): what
    /// the synchronisation sends. Not called for what it brings in itself.
    @ObservationIgnored var onLocalChange: (() -> Void)?
    @ObservationIgnored private var isApplyingRemote = false
    /// Goes up when another device changed what a note shows — its text, its album — or when
    /// its files arrive: the note on screen is shown anew.
    private(set) var revisions: [UUID: Int] = [:]

    /// The folders are one small file next to the `notes` directory.
    private struct FoldersFile: Codable {
        var version = 1
        var folders: [Folder]
    }

    private var foldersURL: URL? {
        directory?.deletingLastPathComponent().appendingPathComponent("folders.json")
    }

    /// The spaces too.
    private struct SpacesFile: Codable {
        var version = 1
        var spaces: [Space]
    }

    private var spacesURL: URL? {
        directory?.deletingLastPathComponent().appendingPathComponent("spaces.json")
    }

    /// Dates are written to the millisecond ("2026-10-01T14:05:12.345Z"): notes changed within
    /// the same second keep their order.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct Probe: Codable {
        var version: Int
    }

    nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Void Notes", isDirectory: true).appendingPathComponent("notes", isDirectory: true)
    }

    init(directory: URL?, notes: [Note] = [], folders: [Folder] = [], spaces: [Space] = []) {
        self.directory = directory
        self.notes = notes.filter { $0.deleted == nil }
        self.trash = notes.filter { $0.deleted != nil }
        self.folders = folders
        self.spaces = spaces
        if let directory {
            load(from: directory)
            loadFolders()
            loadSpaces()
        }
        // The first launch, or notes from before the spaces: everything is in "Personnel".
        if self.spaces.isEmpty {
            self.spaces = [Space()]
            saveSpaces()
        }
        assignSpaces()
        sort()
        purgeTrash()
        removeUnusedAttachments()
    }

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    /// A note of the trash.
    func trashed(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return trash.first { $0.id == id }
    }

    // MARK: Changes

    /// A new, empty note at the top of the list. It reaches the disk with its first character.
    @discardableResult
    func create(in folder: UUID? = nil, space: UUID? = nil) -> Note {
        let folder = self.folder(folder)
        let note = Note(folder: folder?.id, space: folder?.space ?? self.space(space)?.id ?? spaces[0].id)
        notes.insert(note, at: 0)
        return note
    }

    /// Called at every keystroke: the note changes at once, its file a moment after the last one.
    func update(_ id: UUID, content: NoteContent) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              !notes[index].isReadOnly, notes[index].content != content
        else { return }
        notes[index].content = content
        notes[index].modified = .now
        if index != 0 { notes.insert(notes.remove(at: index), at: 0) }
        unsaved.insert(id)
        scheduleSave()
    }

    /// Adds what another app sent at the end of a note (`NoteImport.appending`): if it is on
    /// screen, it is shown anew, with it.
    func append(_ clip: NoteContent, to id: UUID) {
        guard let note = note(id) else { return }
        update(id, content: NoteImport.appending(clip, to: note.content))
        revisions[id, default: 0] += 1
    }

    /// Deletes a note for good, wherever it is — in the list or in the trash — with its files.
    func delete(_ id: UUID) {
        guard note(id) != nil || trashed(id) != nil else { return }
        notes.removeAll { $0.id == id }
        trash.removeAll { $0.id == id }
        unsaved.remove(id)
        try? FileManager.default.removeItem(at: attachmentsDirectory(of: id))
        guard let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            changed()
        } catch {
            errorMessage = "La note n'a pas pu être supprimée du disque : \(error.localizedDescription)"
        }
    }

    // MARK: Trash

    /// Puts a note in the trash, where it stays `trashDays` days. An empty note has nothing to
    /// keep: it is deleted. A later version's note is never rewritten — it can't be marked as
    /// trashed — and never deleted for good without a word: it stays, and the user is told.
    func moveToTrash(_ id: UUID, now: Date = .now) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[index].isReadOnly, !notes[index].isBlank {
            errorMessage = Self.laterVersionMessage(notes[index].title)
            return
        }
        guard !notes[index].isBlank else { return delete(id) }
        var note = notes.remove(at: index)
        note.deleted = now
        trash.insert(note, at: 0)
        save(id)
    }

    /// Why a later version's note stays where it is.
    static func laterVersionMessage(_ title: String) -> String {
        "« \(title) » a été écrite par une version plus récente de Void Notes : elle n'est montrée qu'en lecture. Mettez l'app à jour pour la supprimer."
    }

    /// Takes a note out of the trash, back to its folder if it is still there.
    func restore(_ id: UUID) {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return }
        var note = trash.remove(at: index)
        note.deleted = nil
        let folder = self.folder(note.folder)
        note.folder = folder?.id
        note.space = folder?.space ?? space(note.space)?.id ?? spaces[0].id
        notes.append(note)
        sort()
        save(id)
    }

    /// Deletes for good the trashed notes of a space.
    func emptyTrash(of space: UUID) {
        for note in trash where note.space == space { delete(note.id) }
    }

    /// Days left before a trashed note is deleted (0: at the next launch).
    func daysLeft(_ note: Note, now: Date = .now) -> Int {
        guard let deleted = note.deleted else { return Self.trashDays }
        return max(0, Self.trashDays - Int(now.timeIntervalSince(deleted) / 86400))
    }

    /// At launch: what has been in the trash for `trashDays` days goes for good.
    private func purgeTrash(now: Date = .now) {
        for note in trash where now.timeIntervalSince(note.deleted ?? now) >= Double(Self.trashDays) * 86400 { delete(note.id) }
    }

    private func save(_ id: UUID) {
        unsaved.insert(id)
        scheduleSave()
    }

    // MARK: Lock

    /// Locks a note, or takes its lock off. Like filing, it leaves the note's date alone. An
    /// empty note has nothing to hide; a later version's note is never rewritten.
    func setLocked(_ locked: Bool, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isReadOnly, !notes[index].isBlank, notes[index].locked != locked else { return }
        notes[index].locked = locked
        save(id)
    }

    // MARK: Archive

    /// Archives a note, or takes it back. Like filing, it leaves the note's date alone.
    func setArchived(_ archived: Bool, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isReadOnly, !notes[index].isBlank, notes[index].archived != archived else { return }
        notes[index].archived = archived
        // Put away, a note no longer stands at the top of the list.
        if archived { notes[index].pinned = false }
        save(id)
    }

    // MARK: Pin

    /// Pins a note at the top of the list, or unpins it. Like filing, it leaves the note's date
    /// alone. An archived note isn't pinned.
    func setPinned(_ pinned: Bool, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isReadOnly, !notes[index].isBlank,
              notes[index].pinned != pinned, !(pinned && notes[index].archived) else { return }
        notes[index].pinned = pinned
        save(id)
    }

    // MARK: Attachments

    /// Where the files joined to the notes are kept: a folder per note, next to `notes`. Notes
    /// kept in memory only (demo, tests) have theirs in the temporary folder.
    @ObservationIgnored private(set) lazy var attachmentsRoot: URL = directory?.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true)

    func attachmentsDirectory(of note: UUID) -> URL {
        attachmentsRoot.appendingPathComponent(note.uuidString, isDirectory: true)
    }

    /// Copies a file into the note's folder; returns the name it has there (the file's own, with
    /// a number when it is taken), or nil if it couldn't be copied.
    func attach(_ file: URL, to note: UUID) -> String? {
        attach(named: file.lastPathComponent, to: note) { try FileManager.default.copyItem(at: file, to: $0) }
    }

    /// The same for data that isn't a file yet (a pasted image).
    func attach(_ data: Data, named name: String, to note: UUID) -> String? {
        attach(named: name, to: note) { try data.write(to: $0, options: .atomic) }
    }

    private func attach(named name: String, to note: UUID, write: (URL) throws -> Void) -> String? {
        let folder = attachmentsDirectory(of: note)
        // A name is one path component, whatever the file was called.
        let name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name.isEmpty ? "Fichier" : name, number = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write(folder.appendingPathComponent(candidate))
            return candidate
        } catch {
            errorMessage = "« \(name) » n'a pas pu être joint à la note : \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Photos

    /// Copies images into the note's folder and adds them at the end of its album.
    func addPhotos(_ files: [URL], to id: UUID) {
        guard note(id)?.isReadOnly == false else { return }
        addPhotos(named: files.compactMap { attach($0, to: id) }, to: id)
    }

    /// The same for an image that isn't a file yet (pasted, or picked in Photos).
    func addPhoto(_ data: Data, named name: String, to id: UUID) {
        guard note(id)?.isReadOnly == false, let name = attach(data, named: name, to: id) else { return }
        addPhotos(named: [name], to: id)
    }

    private func addPhotos(named names: [String], to id: UUID) {
        guard !names.isEmpty, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].photos += names
        touch(index)
    }

    /// Takes an image out of the album. Its file goes at the next launch, like the others.
    func removePhoto(_ name: String, from id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isReadOnly, notes[index].photos.contains(name) else { return }
        notes[index].photos.removeAll { $0 == name }
        touch(index)
    }

    /// The note just changed: it goes to the top of the list, and to the disk.
    private func touch(_ index: Int) {
        let id = notes[index].id
        notes[index].modified = .now
        if index != 0 { notes.insert(notes.remove(at: index), at: 0) }
        save(id)
    }

    /// At launch: files that no note shows anymore (their image was deleted from the text) go.
    /// While the app runs they stay, so that undoing brings the image back.
    private func removeUnusedAttachments() {
        guard directory != nil else { return }
        for note in notes + trash where !note.isReadOnly {
            let folder = attachmentsDirectory(of: note.id)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            let used = Set(note.attachments + note.photos)
            for file in files where !used.contains(file) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file)) }
        }
    }

    // MARK: Folders

    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    /// The folders as the list shows them: by name, each one followed by its subfolders.
    var folderRows: [(folder: Folder, depth: Int)] { folderRows(in: nil) }

    /// The folders of one space (nil: of all of them).
    func folderRows(in space: UUID?) -> [(folder: Folder, depth: Int)] {
        var rows: [(folder: Folder, depth: Int)] = []
        func add(_ parent: UUID?, _ depth: Int) {
            let children = folders.filter { $0.parent == parent && (space == nil || $0.space == space) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for folder in children {
                rows.append((folder, depth))
                add(folder.id, depth + 1)
            }
        }
        add(nil, 0)
        return rows
    }

    /// The folder and every folder under it.
    func subtree(of id: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var grew = true
        while grew {
            grew = false
            for folder in folders where !ids.contains(folder.id) && folder.parent.map(ids.contains) == true {
                ids.insert(folder.id)
                grew = true
            }
        }
        return ids
    }

    /// The notes of a folder and of its subfolders, most recently modified first.
    func notes(in folder: UUID) -> [Note] {
        let ids = subtree(of: folder)
        return notes.filter { $0.folder.map(ids.contains) == true }
    }

    @discardableResult
    func createFolder(named name: String = Folder.defaultName, in parent: UUID? = nil, space: UUID? = nil) -> Folder {
        let parent = self.folder(parent)
        let folder = Folder(name: name, parent: parent?.id, space: parent?.space ?? self.space(space)?.id ?? spaces[0].id)
        folders.append(folder)
        saveFolders()
        return folder
    }

    /// An empty name is not a name: the folder keeps the one it has.
    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = folders.firstIndex(where: { $0.id == id }), !name.isEmpty, folders[index].name != name else { return }
        folders[index].name = name
        saveFolders()
    }

    func setIcon(_ icon: String, for id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].icon != icon else { return }
        folders[index].icon = icon
        saveFolders()
    }

    /// Removes the folder and its subfolders. No note is deleted: theirs go to the folder above
    /// (or to none).
    func deleteFolder(_ id: UUID) {
        guard let folder = folder(id) else { return }
        let removed = subtree(of: id)
        for note in notes where note.folder.map(removed.contains) == true { move(note.id, to: folder.parent) }
        folders.removeAll { removed.contains($0.id) }
        saveFolders()
    }

    /// Filing a note doesn't count as a change of the note: its date stays.
    func move(_ id: UUID, to folder: UUID?) {
        let folder = self.folder(folder)
        guard let index = notes.firstIndex(where: { $0.id == id }), !notes[index].isReadOnly, notes[index].folder != folder?.id else { return }
        notes[index].folder = folder?.id
        if let space = folder?.space { notes[index].space = space }
        // An empty note still isn't written.
        guard !notes[index].isBlank else { return }
        unsaved.insert(id)
        scheduleSave()
    }

    // MARK: Spaces

    func space(_ id: UUID?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    /// The notes of a space, most recently modified first.
    func notes(inSpace space: UUID) -> [Note] {
        notes.filter { $0.space == space }
    }

    @discardableResult
    func createSpace(named name: String, icon: String = Space.defaultIcon) -> Space {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Space(name: name.isEmpty ? Space.newName : name, icon: icon)
        spaces.append(space)
        saveSpaces()
        return space
    }

    /// An empty name is not a name: the space keeps the one it has.
    func renameSpace(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty, spaces[index].name != name else { return }
        spaces[index].name = name
        saveSpaces()
    }

    func setIcon(_ icon: String, forSpace id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }), spaces[index].icon != icon else { return }
        spaces[index].icon = icon
        saveSpaces()
    }

    /// Removes a space — never the last one. Nothing in it is deleted: its folders and its notes
    /// go to the first of the other spaces.
    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, space(id) != nil, let heir = spaces.first(where: { $0.id != id }) else { return }
        for index in folders.indices where folders[index].space == id { folders[index].space = heir.id }
        for index in notes.indices where notes[index].space == id { setSpace(heir.id, ofNoteAt: index) }
        for index in trash.indices where trash[index].space == id {
            trash[index].space = heir.id
            save(trash[index].id)
        }
        spaces.removeAll { $0.id == id }
        saveFolders()
        saveSpaces()
    }

    /// Sends a note to another space, out of any folder. Like filing, it leaves its date alone.
    func move(_ id: UUID, toSpace space: UUID) {
        guard let space = self.space(space)?.id, let index = notes.firstIndex(where: { $0.id == id }),
              !notes[index].isReadOnly, notes[index].space != space
        else { return }
        notes[index].folder = nil
        setSpace(space, ofNoteAt: index)
    }

    /// Files a folder in another one (nil: at the top of the list), with its subfolders and their
    /// notes, which take the space of where it goes. Never in itself or in one of its subfolders.
    /// false: it can't go there, or is already there.
    @discardableResult
    func moveFolder(_ id: UUID, to parent: UUID?) -> Bool {
        let target = folder(parent)
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].parent != target?.id else { return false }
        let moved = subtree(of: id)
        if let target, moved.contains(target.id) { return false }
        folders[index].parent = target?.id
        if let space = target?.space, space != folders[index].space {
            for index in folders.indices where moved.contains(folders[index].id) { folders[index].space = space }
            for index in notes.indices where notes[index].folder.map(moved.contains) == true { setSpace(space, ofNoteAt: index) }
        }
        saveFolders()
        return true
    }

    /// Sends a folder to another space, at the top of its list, with its subfolders and their notes.
    func moveFolder(_ id: UUID, toSpace space: UUID) {
        guard let space = self.space(space)?.id, let index = folders.firstIndex(where: { $0.id == id }), folders[index].space != space else { return }
        let moved = subtree(of: id)
        folders[index].parent = nil
        for index in folders.indices where moved.contains(folders[index].id) { folders[index].space = space }
        for index in notes.indices where notes[index].folder.map(moved.contains) == true { setSpace(space, ofNoteAt: index) }
        saveFolders()
    }

    private func setSpace(_ space: UUID, ofNoteAt index: Int) {
        notes[index].space = space
        // An empty note still isn't written; a later version's note never is.
        guard !notes[index].isBlank, !notes[index].isReadOnly else { return }
        unsaved.insert(notes[index].id)
        scheduleSave()
    }

    /// After loading: every folder and every note is in a space that exists. A subfolder is in
    /// the space of its folder, a filed note in the space of its folder; what names no space, or
    /// one that is gone, is in the first one. Nothing is rewritten for that.
    private func assignSpaces() {
        let known = Set(spaces.map(\.id)), first = spaces[0].id
        var spaceOf: [UUID: UUID] = [:]
        func assign(_ parent: UUID?, _ inherited: UUID?) {
            for index in folders.indices where folders[index].parent == parent && spaceOf[folders[index].id] == nil {
                let space = inherited ?? folders[index].space.flatMap { known.contains($0) ? $0 : nil } ?? first
                folders[index].space = space
                spaceOf[folders[index].id] = space
                assign(folders[index].id, space)
            }
        }
        assign(nil, nil)
        for index in folders.indices where spaceOf[folders[index].id] == nil { folders[index].space = first }
        for index in notes.indices {
            notes[index].space = notes[index].folder.flatMap { spaceOf[$0] } ?? notes[index].space.flatMap { known.contains($0) ? $0 : nil } ?? first
        }
        // A trashed note stays in the space it was deleted from.
        for index in trash.indices {
            trash[index].space = trash[index].space.flatMap { known.contains($0) ? $0 : nil } ?? trash[index].folder.flatMap { spaceOf[$0] } ?? first
        }
    }

    private func saveSpaces() {
        guard let spacesURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: spacesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(SpacesFile(spaces: spaces)).write(to: spacesURL, options: .atomic)
            changed()
        } catch {
            errorMessage = "Les espaces n'ont pas pu être enregistrés : \(error.localizedDescription)"
        }
    }

    private func loadSpaces() {
        guard let spacesURL, let data = try? Data(contentsOf: spacesURL) else { return }
        guard let file = try? JSONDecoder().decode(SpacesFile.self, from: data) else {
            // Never overwritten: kept aside under another name.
            let aside = spacesURL.deletingLastPathComponent().appendingPathComponent("spaces-illisible-\(Int(Date.now.timeIntervalSince1970)).json")
            if (try? FileManager.default.moveItem(at: spacesURL, to: aside)) != nil { unreadable += 1 }
            return
        }
        spaces = file.spaces
        // Spaces from before they had a date keep the order they are in.
        if spaces.contains(where: { $0.created == nil }) {
            for index in spaces.indices where spaces[index].created == nil { spaces[index].created = Date(timeIntervalSinceReferenceDate: Double(index)) }
            saveSpaces()
        }
    }

    private func saveFolders() {
        guard let foldersURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: foldersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(FoldersFile(folders: folders)).write(to: foldersURL, options: .atomic)
            changed()
        } catch {
            errorMessage = "Les dossiers n'ont pas pu être enregistrés : \(error.localizedDescription)"
        }
    }

    private func loadFolders() {
        guard let foldersURL, let data = try? Data(contentsOf: foldersURL) else { return }
        guard let file = try? JSONDecoder().decode(FoldersFile.self, from: data) else {
            // Never overwritten: kept aside under another name.
            let aside = foldersURL.deletingLastPathComponent().appendingPathComponent("folders-illisible-\(Int(Date.now.timeIntervalSince1970)).json")
            if (try? FileManager.default.moveItem(at: foldersURL, to: aside)) != nil { unreadable += 1 }
            return
        }
        folders = file.folders
        // A file edited by hand: a folder whose parent is missing, or that is its own ancestor,
        // comes back to the top.
        let reachable = Set(folderRows.map(\.folder.id))
        for index in folders.indices where !reachable.contains(folders[index].id) { folders[index].parent = nil }
    }

    // MARK: Synchronisation

    private func changed() {
        if !isApplyingRemote { onLocalChange?() }
    }

    /// The first synchronisation with a folder another device filled: a space of here takes the
    /// place of the one that has its name there ("Personnel" on both), rather than showing twice.
    func adopt(_ space: Space, inPlaceOf old: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == old }), self.space(space.id) == nil else { return }
        spaces[index] = space
        for index in folders.indices where folders[index].space == old { folders[index].space = space.id }
        for index in notes.indices where notes[index].space == old { setSpace(space.id, ofNoteAt: index) }
        for index in trash.indices where trash[index].space == old {
            trash[index].space = space.id
            save(trash[index].id)
        }
        saveFolders()
        saveSpaces()
    }

    /// What the synchronisation merged becomes what is here: notes changed elsewhere are
    /// rewritten, those deleted elsewhere go with their files. A note still empty isn't in the
    /// snapshot: it stays. Returns the notes whose text or album changed.
    @discardableResult
    func apply(_ payload: SyncPayload) -> Set<UUID> {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var shown: Set<UUID> = []
        let incoming = Dictionary(payload.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = Dictionary((notes + trash).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, note) in current where incoming[id] == nil && !note.isBlank && !note.isReadOnly {
            current[id] = nil
            unsaved.remove(id)
            try? FileManager.default.removeItem(at: attachmentsDirectory(of: id))
            if let url = fileURL(id) { try? FileManager.default.removeItem(at: url) }
        }
        for (id, file) in incoming {
            if let note = current[id] {
                guard !note.isReadOnly, SyncMerge.hash(NoteFile(note)) != SyncMerge.hash(file) else { continue }
                if note.content != file.note.content || note.photos != file.note.photos { shown.insert(id) }
            }
            current[id] = file.note
            unsaved.insert(id)
        }
        notes = current.values.filter { $0.deleted == nil }
        trash = current.values.filter { $0.deleted != nil }
        let foldersChanged = folders != payload.folders, spacesChanged = spaces != payload.spaces
        folders = payload.folders
        spaces = payload.spaces.isEmpty ? [Space()] : payload.spaces
        let reachable = Set(folderRows.map(\.folder.id))
        for index in folders.indices where !reachable.contains(folders[index].id) { folders[index].parent = nil }
        assignSpaces()
        sort()
        flush()
        if foldersChanged { saveFolders() }
        if spacesChanged || payload.spaces.isEmpty { saveSpaces() }
        for id in shown { revisions[id, default: 0] += 1 }
        return shown
    }

    /// Files of these notes just arrived from the shared folder: they show.
    func attachmentsArrived(for ids: Set<UUID>) {
        for id in ids { revisions[id, default: 0] += 1 }
    }

    // MARK: Files

    /// Writes what's waiting, now: before quitting, and when the window goes to the background.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let directory else { unsaved = []; return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for id in unsaved {
            guard let note = note(id) ?? trashed(id), let url = fileURL(id) else { continue }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(NoteFile(note)).write(to: url, options: .atomic)
                unsaved.remove(id)
            } catch {
                // Stays in `unsaved`: tried again with the next change.
                errorMessage = "La note « \(note.title) » n'a pas pu être enregistrée : \(error.localizedDescription)"
            }
        }
    }

    private func scheduleSave() {
        changed()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func fileURL(_ id: UUID) -> URL? {
        directory?.appendingPathComponent("\(id.uuidString).json")
    }

    private func load(from directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.dateFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Date illisible"))
            }
            return date
        }
        for url in files where url.pathExtension == "json" {
            // The file's name is the note's identity: a copy made in the Finder under another
            // name is not a second note.
            guard let data = try? Data(contentsOf: url), let file = try? decoder.decode(NoteFile.self, from: data),
                  url.deletingPathExtension().lastPathComponent == file.id.uuidString
            else {
                // A later version's file that no longer reads here is left where it is.
                let version = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Probe.self, from: $0) }?.version ?? 0
                if version <= Self.formatVersion { setAside(url, in: directory) }
                continue
            }
            if file.deleted == nil { notes.append(file.note) } else { trash.append(file.note) }
        }
    }

    private func setAside(_ url: URL, in directory: URL) {
        let folder = directory.appendingPathComponent("illisibles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date.now.timeIntervalSince1970)
        let destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: destination)) != nil { unreadable += 1 }
    }

    private func sort() {
        notes.sort { $0.modified > $1.modified }
        trash.sort { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }
    }
}
