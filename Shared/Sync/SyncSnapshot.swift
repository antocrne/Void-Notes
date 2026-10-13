import CryptoKit
import Foundation

/// The file of the shared folder: a header and everything that is synchronised, as readable JSON.
///
/// Every field of the header is optional when read and falls back on a sensible default; unknown
/// keys are ignored. `minReaderFormat` only goes up for a change an earlier version couldn't
/// merge; `noteFormat` is the format of the notes in it (`NoteStore.formatVersion`): a device
/// whose app is older would lose what it doesn't know by writing them again, so it waits.
struct SyncFile: Codable {
    static let fileName = "void-notes-data.json"
    static let currentFormat = 1

    var format: Int
    var minReaderFormat: Int
    var noteFormat: Int
    var exportedAt: Date
    var device: String
    var data: SyncPayload

    init(data: SyncPayload, device: String) {
        self.format = Self.currentFormat
        self.minReaderFormat = 1
        self.noteFormat = NoteStore.formatVersion
        self.exportedAt = .now
        self.device = device
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, default: 1)
        minReaderFormat = c.value(.minReaderFormat, default: 1)
        noteFormat = c.value(.noteFormat, default: 1)
        exportedAt = c.value(.exportedAt, default: .distantPast)
        device = c.value(.device, default: "")
        data = try c.decodeIfPresent(SyncPayload.self, forKey: .data) ?? SyncPayload()
    }
}

/// Everything that is synchronised, written the same way whatever the device (keys and items
/// sorted). Each item has the date it last changed, and deletions are kept: two versions merge
/// item by item (see `SyncMerge`). The files joined to the notes are apart (see `SyncAttachments`).
struct SyncPayload: Codable, Equatable {
    var spaces: [Space] = []
    var folders: [Folder] = []
    /// The notes, those of the trash included. A note still empty isn't here.
    var notes: [NoteFile] = []
    /// When each item last changed, by identifier.
    var modifiedAt: [String: Date] = [:]
    /// Deleted items, by identifier: a deletion wins over an earlier change.
    var deletedAt: [String: Date] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        notes = try c.decodeIfPresent([NoteFile].self, forKey: .notes) ?? []
        modifiedAt = c.value(.modifiedAt, default: [:])
        deletedAt = c.value(.deletedAt, default: [:])
    }

    /// What is here now.
    @MainActor
    init(_ store: NoteStore) {
        spaces = store.spaces
        folders = store.folders
        notes = (store.notes + store.trash).filter { !$0.isBlank }.map(NoteFile.init)
        sort()
    }

    /// The items alone, without their synchronisation dates.
    var content: SyncPayload {
        var content = self
        content.modifiedAt = [:]
        content.deletedAt = [:]
        return content
    }

    /// The same order on every device: the spaces as they were made, the rest by identifier.
    mutating func sort() {
        spaces.sort { ($0.created ?? .distantPast, $0.id.uuidString) < ($1.created ?? .distantPast, $1.id.uuidString) }
        folders.sort { $0.id.uuidString < $1.id.uuidString }
        notes.sort { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }
}

protocol SyncRecord: Codable { var id: UUID { get } }
extension Space: SyncRecord {}
extension Folder: SyncRecord {}
extension NoteFile: SyncRecord {}

enum SyncCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    /// A date to the nearest millisecond, as the note files have it. The format cuts the
    /// fraction rather than rounding it, and a date read back from "….186Z" may fall just under
    /// .186: written again, it would lose a millisecond each time — an item that never changed
    /// would look changed at every synchronisation. Rounded, then a tenth of a millisecond past
    /// it, the date is cut where it should be, and stays the same however often it is read and
    /// written.
    static func string(from date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1000 + 0.0001)
            .formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    /// Reads ISO 8601 dates with or without a fraction of a second, or a number of seconds
    /// since 1970 (handy for a file edited by hand).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted)) {
                return date
            }
            if let date = try? Date(string, strategy: .iso8601) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date illisible : \(string)")
        }
        return decoder
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension KeyedDecodingContainer {
    /// The value if it is there and of the right type, the default otherwise.
    func value<T: Decodable>(_ key: Key, default defaultValue: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? defaultValue()
    }
}
