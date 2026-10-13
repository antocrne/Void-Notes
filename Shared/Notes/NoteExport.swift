import Foundation

/// Notes written out as Markdown, to be read and kept without Void Notes: one `.md` file per
/// note — or, for a note with images or joined files, a folder holding its `.md` file and a copy
/// of its files in « fichiers ».
@MainActor
enum NoteExport {
    /// Where a note's files go, next to its Markdown.
    static let filesFolder = String(localized: "fichiers", comment: "Folder of a note's files, next to its exported Markdown")

    /// The images and files of the note that are there to be copied.
    private static func files(of note: Note, store: NoteStore) -> [String] {
        let directory = store.attachmentsDirectory(of: note.id)
        var seen = Set<String>()
        return (note.photos + note.attachments).filter {
            seen.insert($0).inserted && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// The note is written as a folder rather than as a single file.
    static func needsFolder(_ note: Note, store: NoteStore) -> Bool { !files(of: note, store: store).isEmpty }

    /// Writes the note at `url`: the `.md` file — or, when `needsFolder`, the folder, its `.md`
    /// file named after it.
    static func write(_ note: Note, to url: URL, store: NoteStore) throws {
        let files = files(of: note, store: store)
        let markdown = Data(NoteMarkdown.markdown(from: note.content, photos: note.photos, files: files.isEmpty ? nil : filesFolder).utf8)
        guard !files.isEmpty else { return try markdown.write(to: url, options: .atomic) }
        let manager = FileManager.default
        let copies = url.appendingPathComponent(filesFolder, isDirectory: true)
        try manager.createDirectory(at: copies, withIntermediateDirectories: true)
        let source = store.attachmentsDirectory(of: note.id)
        for name in files {
            let copy = copies.appendingPathComponent(name)
            if manager.fileExists(atPath: copy.path) { try manager.removeItem(at: copy) }
            try manager.copyItem(at: source.appendingPathComponent(name), to: copy)
        }
        try markdown.write(to: url.appendingPathComponent(url.lastPathComponent + ".md"), options: .atomic)
    }

    /// Every note — not those of the trash, nor the locked ones — in a new folder of `directory`,
    /// filed as in the list: a folder per space (when there are several), per folder and
    /// subfolder, and « Archives ». Returns that folder, and how many locked notes were left out.
    static func writeAll(store: NoteStore, in directory: URL, now: Date = .now) throws -> (folder: URL, locked: Int) {
        let manager = FileManager.default
        let date = now.formatted(.dateTime.day().month(.wide).year())
        let root = unique(directory, "Void Notes – \(date)", ext: nil)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var locked = 0
        for note in store.notes where !note.isBlank {
            if note.locked {
                locked += 1
                continue
            }
            var folder = root
            if store.spaces.count > 1, let space = store.space(note.space) {
                folder.appendPathComponent(NoteMarkdown.safeName(space.name, otherwise: String(localized: "Espace")), isDirectory: true)
            }
            if note.archived { folder.appendPathComponent(String(localized: "Archives"), isDirectory: true) }
            for name in folderPath(of: note.folder, store: store) {
                folder.appendPathComponent(NoteMarkdown.safeName(name, otherwise: "Dossier"), isDirectory: true)
            }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let needsFolder = needsFolder(note, store: store)
            try write(note, to: unique(folder, NoteMarkdown.fileName(for: note), ext: needsFolder ? nil : "md"), store: store)
        }
        return (root, locked)
    }

    /// The names of a folder and of those it is in, from the top.
    private static func folderPath(of id: UUID?, store: NoteStore) -> [String] {
        var names: [String] = []
        var seen = Set<UUID>()
        var current = store.folder(id)
        while let folder = current, seen.insert(folder.id).inserted {
            names.insert(folder.name, at: 0)
            current = store.folder(folder.parent)
        }
        return names
    }

    /// `name` in `directory`, followed by a number when that name is taken: « Courses 2 ».
    private static func unique(_ directory: URL, _ name: String, ext: String?) -> URL {
        func url(_ name: String) -> URL {
            ext.map { directory.appendingPathComponent(name).appendingPathExtension($0) } ?? directory.appendingPathComponent(name, isDirectory: true)
        }
        var candidate = url(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(name) \(number)")
            number += 1
        }
        return candidate
    }
}
