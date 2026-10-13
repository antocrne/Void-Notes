import Foundation

/// Merges two versions of the notes, item by item.
///
/// For each identifier the version changed last wins; a deletion wins over earlier changes. An
/// item missing on one side without having been deleted there is kept. The merge is symmetric:
/// two devices merging the same versions get the same result, whatever the order.
enum SyncMerge {
    /// Earlier deletions are forgotten.
    static let deletionRetention: TimeInterval = 365 * 24 * 3600

    // MARK: Dating what is here

    /// Dates what is here from the last synchronisation: an item that didn't change keeps its
    /// date, one that changed or is new takes the date of the last change made here, one that
    /// was known and is gone becomes a deletion.
    static func stamp(_ payload: SyncPayload, tracker: SyncTracker, editedAt: Date) -> SyncPayload {
        var stamped = payload
        stamped.deletedAt = tracker.deletedAt
        var present = Set<String>()

        /// `ownDate`: the date the item carries itself.
        func visit<Record: SyncRecord>(_ records: [Record], ownDate: (Record) -> Date?) {
            for record in records {
                let id = record.id.uuidString
                present.insert(id)
                let known = tracker.modifiedAt[id]
                if tracker.recordHashes[id] == hash(record), let known {
                    stamped.modifiedAt[id] = known
                } else if let date = ownDate(record), known.map({ date.timeIntervalSince($0) > 0.002 }) ?? true {
                    stamped.modifiedAt[id] = date
                } else {
                    stamped.modifiedAt[id] = after(editedAt, known)
                }
                stamped.deletedAt[id] = nil
            }
        }
        visit(payload.spaces) { _ in nil }
        visit(payload.folders) { _ in nil }
        // A note says when it was written or put in the trash: several notes changed while the
        // folder was out of reach each keep their own date. Filing, locking or archiving leaves
        // those dates alone: such a change takes the date of the last change made here.
        visit(payload.notes) { max($0.modified, $0.deleted ?? .distantPast) }

        for id in tracker.recordHashes.keys where !present.contains(id) && stamped.deletedAt[id] == nil {
            stamped.deletedAt[id] = after(editedAt, tracker.modifiedAt[id])
        }
        return stamped
    }

    /// A file whose items have no date (edited by hand): the notes keep their own, the rest
    /// takes the date the file was written.
    static func dated(_ file: SyncFile) -> SyncPayload {
        var payload = file.data
        func fill<Record: SyncRecord>(_ records: [Record], date: (Record) -> Date) {
            for record in records where payload.modifiedAt[record.id.uuidString] == nil {
                payload.modifiedAt[record.id.uuidString] = date(record)
            }
        }
        fill(payload.spaces) { _ in file.exportedAt }
        fill(payload.folders) { _ in file.exportedAt }
        fill(payload.notes) { max($0.modified, $0.deleted ?? .distantPast) }
        return payload
    }

    // MARK: Merge

    static func merge(_ a: SyncPayload, _ b: SyncPayload, now: Date = .now) -> SyncPayload {
        var merged = SyncPayload()
        merged.deletedAt = a.deletedAt.merging(b.deletedAt, uniquingKeysWith: max)
        merged.spaces = mergeRecords(a.spaces, a, b.spaces, b, into: &merged)
        merged.folders = mergeRecords(a.folders, a, b.folders, b, into: &merged)
        merged.notes = mergeRecords(a.notes, a, b.notes, b, into: &merged)
        merged.sort()

        let horizon = now.addingTimeInterval(-deletionRetention)
        merged.deletedAt = merged.deletedAt.filter { $0.value > horizon }
        return merged
    }

    private static func mergeRecords<Record: SyncRecord>(
        _ aRecords: [Record], _ a: SyncPayload,
        _ bRecords: [Record], _ b: SyncPayload,
        into merged: inout SyncPayload
    ) -> [Record] {
        var chosen: [String: (record: Record, date: Date)] = [:]
        for (records, payload) in [(aRecords, a), (bRecords, b)] {
            for record in records {
                let id = record.id.uuidString
                let date = payload.modifiedAt[id] ?? .distantPast
                if let current = chosen[id] {
                    let isNewer = date > current.date || (date == current.date && hash(record) > hash(current.record))
                    if isNewer { chosen[id] = (record, date) }
                } else {
                    chosen[id] = (record, date)
                }
            }
        }
        var kept: [Record] = []
        for (id, entry) in chosen {
            if let deleted = merged.deletedAt[id], deleted >= entry.date { continue }
            merged.deletedAt[id] = nil
            merged.modifiedAt[id] = entry.date
            kept.append(entry.record)
        }
        return kept
    }

    // MARK: Tools

    /// true if the merge sets aside a change made here since the last synchronisation.
    static func dropsLocalEdits(local: SyncPayload, merged: SyncPayload, tracker: SyncTracker) -> Bool {
        func check<Record: SyncRecord>(_ localRecords: [Record], _ mergedRecords: [Record]) -> Bool {
            let mergedHashes = Dictionary(mergedRecords.map { ($0.id.uuidString, hash($0)) }, uniquingKeysWith: { first, _ in first })
            return localRecords.contains { record in
                let id = record.id.uuidString
                let localHash = hash(record)
                return tracker.recordHashes[id] != localHash && mergedHashes[id] != localHash
            }
        }
        return check(local.spaces, merged.spaces) || check(local.folders, merged.folders) || check(local.notes, merged.notes)
    }

    /// Goes through the file's encoding: the dates are rounded as once written then read.
    static func normalized(_ payload: SyncPayload) throws -> SyncPayload {
        try SyncCoding.decoder().decode(SyncPayload.self, from: SyncCoding.encoder().encode(payload))
    }

    static func hash<Value: Encodable>(_ value: Value) -> String {
        SyncCoding.hash((try? SyncCoding.encoder().encode(value)) ?? Data())
    }

    /// `date`, or just after `previous` if the clock would put it before — by more than the
    /// millisecond the file keeps of a date.
    private static func after(_ date: Date, _ previous: Date?) -> Date {
        guard let previous, date.timeIntervalSince(previous) < 0.002 else { return date }
        return previous.addingTimeInterval(0.002)
    }
}

/// What was here at the last synchronisation that went through, on this device only: it dates
/// the changes and tells what was deleted here.
struct SyncTracker: Codable, Equatable {
    var recordHashes: [String: String] = [:]
    var modifiedAt: [String: Date] = [:]
    var deletedAt: [String: Date] = [:]

    init() {}

    init(_ payload: SyncPayload) {
        func add<Record: SyncRecord>(_ records: [Record]) {
            for record in records { recordHashes[record.id.uuidString] = SyncMerge.hash(record) }
        }
        add(payload.spaces)
        add(payload.folders)
        add(payload.notes)
        modifiedAt = payload.modifiedAt
        deletedAt = payload.deletedAt
    }
}
