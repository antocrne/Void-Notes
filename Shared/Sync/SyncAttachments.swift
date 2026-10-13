import Foundation

/// The files joined to the notes, in the shared folder: `attachments/<note>/<name>`, as in the
/// app's container. A file never changes once joined: it is copied there once, read once by
/// each device, and goes when its note is deleted for good. Blocking calls, off the main thread.
enum SyncAttachments {
    static let directoryName = "attachments"

    struct Transfer: Sendable {
        var sent = 0
        /// The notes that received files.
        var received: Set<UUID> = []
        /// Files that aren't on this device yet: iCloud Drive is still downloading them, or the
        /// device that has them hasn't sent them.
        var pending = 0
    }

    nonisolated static func directory(of note: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(note.uuidString, isDirectory: true)
    }

    /// - Parameters:
    ///   - wanted: the files each note shows.
    ///   - local: where the notes of this device keep their files.
    ///   - deleted: notes deleted for good, whose files go.
    nonisolated static func transfer(wanted: [(note: UUID, names: [String])], local: URL, folder: URL, deleted: Set<UUID>) -> Transfer {
        var result = Transfer()
        let fileManager = FileManager.default
        for (note, names) in wanted {
            let here = local.appendingPathComponent(note.uuidString, isDirectory: true)
            let there = directory(of: note, in: folder)
            for name in names {
                let source = here.appendingPathComponent(name), shared = there.appendingPathComponent(name)
                let isHere = fileManager.fileExists(atPath: source.path), isThere = SyncFileIO.exists(shared)
                if isHere && !isThere {
                    if let data = try? Data(contentsOf: source, options: .mappedIfSafe), (try? SyncFileIO.write(data, to: shared)) != nil { result.sent += 1 }
                } else if !isHere && isThere, case .contents(let data)? = try? SyncFileIO.read(shared),
                          (try? fileManager.createDirectory(at: here, withIntermediateDirectories: true)) != nil,
                          (try? data.write(to: source, options: .atomic)) != nil {
                    result.received.insert(note)
                } else if !isHere {
                    result.pending += 1
                }
            }
        }
        for note in deleted {
            let url = directory(of: note, in: folder)
            if SyncFileIO.exists(url) { SyncFileIO.remove(url) }
        }
        return result
    }
}
