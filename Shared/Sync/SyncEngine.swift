import Foundation
import Observation
import OSLog
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Synchronises the notes of this device with a file of a folder in iCloud Drive, as Irum does.
///
/// The notes of the app's container stay what the window reads and writes: it never waits. At
/// every change, at launch and each time the app comes to the front, the file (and the conflict
/// copies iCloud Drive left) is merged item by item with what is here (see `SyncMerge`), then
/// the result is applied here and written back. A version that is late, or written at the same
/// time on another device, never replaces everything: only the item changed last wins. If a
/// change made here is set aside, the version of here is first saved in `Backups/`.
@MainActor
@Observable
final class SyncEngine {
    static let shared = SyncEngine(store: .shared)

    enum Status: Equatable {
        case notConfigured
        case folderUnavailable
        case syncing
        case upToDate
        /// iCloud Drive is still downloading the latest version.
        case waitingForDownload
        /// The folder was written by a later version of the app.
        case outdated
        /// A note of this device was written by a later version of the app: sending it would
        /// lose what this version can't read.
        case laterNoteHere
        case failed(String)
    }

    private(set) var status: Status = .notConfigured
    private(set) var folderURL: URL?
    private(set) var lastSyncAt: Date?
    /// Conflict copies left by iCloud Drive on the file.
    private(set) var conflictCount = 0
    /// Called when what another device did was applied here: the window follows.
    @ObservationIgnored var onApplied: (() -> Void)?

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let state: SyncState
    /// false: nothing happens by itself (the tests, which say when to synchronise).
    @ObservationIgnored private let isAutomatic: Bool
    @ObservationIgnored private let log = Logger(subsystem: "app.void.notes", category: "sync")
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var needsRerun = false
    @ObservationIgnored private var isApplyingRemote = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var downloadRetries = 0
    @ObservationIgnored private var attachmentRetries = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Old backups are removed once per launch.
    @ObservationIgnored private var prunedBackups = false

    /// A backup stays this long in `Backups/`: a change set aside is worth a month, not forever.
    nonisolated static let backupDays = 30

    private var fileURL: URL? { folderURL?.appendingPathComponent(SyncFile.fileName) }

    /// - Parameters:
    ///   - folder: a folder given as it is, without a bookmark (the tests).
    ///   - defaults: where what was last synchronised is remembered.
    init(store: NoteStore, folder: URL? = nil, defaults: UserDefaults? = nil) {
        self.store = store
        state = SyncState(defaults: defaults ?? UserDefaults(suiteName: "app.void.notes.syncState") ?? .standard)
        isAutomatic = folder == nil && store.directory != nil
        store.onLocalChange = { [weak self] in self?.localDataDidChange() }
        if let folder {
            folderURL = folder
            status = .upToDate
        } else if isAutomatic {
            connectFolder()
            observe()
        }
    }

    // MARK: Folder

    func chooseFolder() async {
        #if os(macOS)
        guard let url = await SyncFolderAccess.chooseFolder(prompt: String(localized: "Utiliser ce dossier"), message: String(localized: "Choisissez ou créez un dossier « Void Notes » dans iCloud Drive : les notes y sont synchronisées entre vos appareils.")) else { return }
        await useFolder(url)
        #endif
    }

    /// A new folder: the first synchronisation does as a first device would (no file: what is
    /// here is written; a file: both are put together).
    func useFolder(_ url: URL) async {
        #if BETA
        // The beta keeps its notes apart: never in the folder Void Notes synchronises with.
        guard !BetaFolder.isVoidNotesFolder(url) else {
            status = .failed(BetaFolder.refusal)
            return
        }
        #endif
        do {
            try SyncFolderAccess.remember(url)
        } catch {
            log.error("Bookmark of the folder failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            return
        }
        #if BETA
        BetaFolder.mark(url)
        #endif
        folderURL?.stopAccessingSecurityScopedResource()
        state.reset()
        connectFolder()
        await sync(reason: "folder chosen")
    }

    /// The notes stay on this device, and in the folder: nothing is deleted.
    func stopSyncing() {
        scheduled?.cancel()
        folderURL?.stopAccessingSecurityScopedResource()
        folderURL = nil
        SyncFolderAccess.forget()
        state.reset()
        conflictCount = 0
        status = .notConfigured
    }

    private func connectFolder() {
        switch SyncFolderAccess.resolve() {
        case .success(let url):
            folderURL = url
            status = .upToDate
        case .failure(.notConfigured):
            folderURL = nil
            status = .notConfigured
        case .failure(.unavailable):
            folderURL = nil
            status = .folderUnavailable
            log.error("Shared folder not found, or access denied")
        }
    }

    // MARK: Triggers

    private func observe() {
        let center = NotificationCenter.default
        #if os(macOS)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        let willResignActive = NSApplication.willResignActiveNotification
        #else
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        let willResignActive = UIApplication.willResignActiveNotification
        #endif
        // Back to the front (and launch): read again, iCloud Drive isn't instantaneous.
        observers.append(center.addObserver(forName: didBecomeActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(reason: "front", delay: .zero) }
        })
        observers.append(center.addObserver(forName: willResignActive, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(reason: "background", delay: .zero) }
        })
    }

    private func localDataDidChange() {
        guard !isApplyingRemote else { return }
        state.lastLocalEditAt = .now
        syncSoon(reason: "local change")
    }

    func syncNow() {
        syncSoon(reason: "asked", delay: .zero)
    }

    /// Changes close to each other (a note being typed) make one write.
    private func syncSoon(reason: String, delay: Duration = .seconds(2)) {
        guard isAutomatic, folderURL != nil || SyncFolderAccess.isConfigured else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.sync(reason: reason)
        }
    }

    // MARK: Reconciliation

    /// What was read in the folder: the file and its conflict copies.
    private struct RemoteRead {
        var main: SyncFileIO.ReadResult
        var conflicts: [(version: NSFileVersion, data: Data?)]
    }

    func sync(reason: String) async {
        if folderURL == nil, isAutomatic { connectFolder() }
        guard let fileURL else { return }
        if isRunning {
            needsRerun = true
            return
        }
        isRunning = true
        #if os(iOS)
        // Lets the write end if the app goes to the background meanwhile.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Void Notes sync")
        #endif
        defer {
            #if os(iOS)
            UIApplication.shared.endBackgroundTask(backgroundTask)
            #endif
            isRunning = false
            if needsRerun {
                needsRerun = false
                syncSoon(reason: "again", delay: .zero)
            }
        }
        status = .syncing
        log.debug("Sync (\(reason, privacy: .public))")

        guard let read = await Self.readRemote(fileURL, timeout: 45) else {
            // iCloud Drive didn't give the file in time (slow or no network): tried again later.
            log.notice("Reading the file took too long: tried again later")
            status = .waitingForDownload
            downloadRetries += 1
            if downloadRetries <= 10 { syncSoon(reason: "waiting for iCloud Drive", delay: .seconds(15)) }
            return
        }
        let remote: RemoteRead
        switch read {
        case .success(let result):
            remote = result
        case .failure(let error):
            log.error("Reading the file failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            return
        }

        // From the snapshot of what is here to the decision, everything runs on the main thread
        // without a pause: no change made here can slip in between.
        guard let plan = reconcile(remote, fileURL: fileURL) else { return }
        // Files first: another device that reads the notes already finds what they show.
        await syncAttachments()
        guard let data = plan.data else {
            finish()
            return
        }
        let conflicts = plan.resolvedConflicts
        let result = await Task.detached {
            Result {
                try SyncFileIO.write(data, to: fileURL)
                try SyncFileIO.resolve(conflicts, at: fileURL)
            }
        }.value
        switch result {
        case .success:
            log.info("Merged notes written (\(data.count) bytes)")
            conflictCount = SyncFileIO.unresolvedConflicts(at: fileURL).count
            finish()
        case .failure(let error):
            // Offline, or the folder is out of reach: what is here is up to date, tried again later.
            log.error("Writing the file failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// Reads in the background, given up after `timeout` seconds (nil) so as not to block.
    nonisolated private static func readRemote(_ fileURL: URL, timeout: TimeInterval) async -> Result<RemoteRead, Error>? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try readRemote(fileURL) }
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// The file and its conflict copies. Blocking, off the main thread.
    nonisolated private static func readRemote(_ fileURL: URL, waitForDownload: Bool = SyncFileIO.defaultWaitsForDownload) throws -> RemoteRead {
        let main = try SyncFileIO.read(fileURL, waitForDownload: waitForDownload)
        let conflicts = SyncFileIO.unresolvedConflicts(at: fileURL).map { version in
            (version: version, data: try? Data(contentsOf: version.url))
        }
        return RemoteRead(main: main, conflicts: conflicts)
    }

    private struct WritePlan {
        /// nil: the file is up to date already.
        var data: Data?
        var resolvedConflicts: [NSFileVersion]
    }

    /// Merges the file, its conflict copies and what is here; applies the result here. Returns
    /// what is left to write, or nil if it has to wait (download, file that doesn't read).
    private func reconcile(_ remote: RemoteRead, fileURL: URL) -> WritePlan? {
        // A note a later version wrote here would be sent without what this version can't read.
        guard !(store.notes + store.trash).contains(where: \.isReadOnly) else {
            status = .laterNoteHere
            return nil
        }
        var remoteFiles: [SyncFile] = []
        var mainPayload: SyncPayload?
        switch remote.main {
        case .notDownloaded:
            // The latest version is waited for before anything is written.
            status = .waitingForDownload
            downloadRetries += 1
            if downloadRetries <= 20 { syncSoon(reason: "waiting for the download", delay: .seconds(3)) }
            return nil
        case .missing:
            if !state.tracker.recordHashes.isEmpty {
                log.notice("The file is gone from the folder: written again from this device")
            }
        case .contents(let data):
            downloadRetries = 0
            guard let file = decodeFile(data) else { return nil }
            remoteFiles.append(file)
            mainPayload = try? SyncMerge.normalized(SyncMerge.dated(file))
        }

        var resolved: [NSFileVersion] = []
        for conflict in remote.conflicts {
            // Each copy is saved once, then merged and marked as resolved.
            if let data = conflict.data {
                backUp(data, label: "conflict-\(conflict.version.localizedNameOfSavingComputer ?? "unknown")")
                if let file = decodeFile(data) { remoteFiles.append(file) } else { continue }
            }
            resolved.append(conflict.version)
        }
        if !remote.conflicts.isEmpty {
            log.notice("\(remote.conflicts.count) conflict copies merged")
        }

        var adopted = false
        if state.tracker.recordHashes.isEmpty, let first = remoteFiles.first {
            adopted = adoptSpaces(of: first.data)
        }

        let tracker = state.tracker
        let merged: SyncPayload
        let localContent = SyncPayload(store)
        let local = SyncMerge.stamp(localContent, tracker: tracker, editedAt: state.lastLocalEditAt ?? .now)
        do {
            merged = try SyncMerge.normalized(remoteFiles.reduce(local) { SyncMerge.merge($0, SyncMerge.dated($1)) })
        } catch {
            log.error("Merge failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            return nil
        }

        if SyncMerge.hash(merged.content) != SyncMerge.hash(localContent) {
            if SyncMerge.dropsLocalEdits(local: localContent, merged: merged, tracker: tracker),
               let data = try? SyncCoding.encoder().encode(SyncFile(data: local, device: Self.deviceName)) {
                log.notice("A change made here gives way to a later one: the version of here is saved")
                backUp(data, label: "local")
            }
            isApplyingRemote = true
            store.apply(merged)
            isApplyingRemote = false
            adopted = true
            log.info("Changes received applied (\(remoteFiles.map(\.device).joined(separator: ", "), privacy: .public))")
        }
        if adopted { onApplied?() }
        state.tracker = SyncTracker(merged)

        let upToDate = mainPayload.map { SyncMerge.hash($0) == SyncMerge.hash(merged) } ?? false
        if upToDate && resolved.isEmpty {
            return WritePlan(data: nil, resolvedConflicts: [])
        }
        guard let data = try? SyncCoding.encoder().encode(SyncFile(data: merged, device: Self.deviceName)) else {
            status = .failed(String(localized: "encodage"))
            return nil
        }
        return WritePlan(data: data, resolvedConflicts: resolved)
    }

    /// The first time this device meets a folder another one filled: both have a "Personnel"
    /// of their own. A space of here that the folder doesn't know takes the place of the one
    /// that has its name there — or, if it is empty, of any the folder has — rather than
    /// showing twice.
    private func adoptSpaces(of remote: SyncPayload) -> Bool {
        var free = remote.spaces.filter { store.space($0.id) == nil }
        guard !free.isEmpty else { return false }
        let known = Set(remote.spaces.map(\.id))
        var adopted = false
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        for space in store.spaces where !known.contains(space.id) {
            let isEmpty = !store.folders.contains { $0.space == space.id } && !(store.notes + store.trash).contains { $0.space == space.id && !$0.isBlank }
            guard let index = free.firstIndex(where: { $0.name.compare(space.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) ?? (isEmpty ? free.indices.first : nil) else { continue }
            store.adopt(free.remove(at: index), inPlaceOf: space.id)
            adopted = true
        }
        return adopted
    }

    /// Sends the files joined here, reads those joined elsewhere, and removes those of the
    /// notes deleted for good.
    private func syncAttachments() async {
        guard let folderURL else { return }
        let wanted = (store.notes + store.trash).compactMap { note -> (note: UUID, names: [String])? in
            let names = Array(Set(note.attachments + note.photos + note.recordings))
            return names.isEmpty ? nil : (note.id, names)
        }
        let deleted = Set(state.tracker.deletedAt.keys.compactMap(UUID.init(uuidString:)))
        guard !wanted.isEmpty || !deleted.isEmpty else { return }
        let local = store.attachmentsRoot
        let result = await Task.detached {
            SyncAttachments.transfer(wanted: wanted, local: local, folder: folderURL, deleted: deleted)
        }.value
        if result.sent > 0 { log.info("\(result.sent) files sent") }
        if !result.received.isEmpty {
            store.attachmentsArrived(for: result.received)
            log.info("Files received for \(result.received.count) notes")
        }
        // Files that aren't in the folder yet: looked for again a little later.
        if result.pending > 0 {
            attachmentRetries += 1
            if attachmentRetries <= 20 { syncSoon(reason: "files awaited", delay: .seconds(10)) }
        } else {
            attachmentRetries = 0
        }
    }

    private func decodeFile(_ data: Data) -> SyncFile? {
        let file: SyncFile
        do {
            file = try SyncCoding.decoder().decode(SyncFile.self, from: data)
        } catch {
            // Damaged, or badly edited by hand: never overwritten, reported.
            log.error("The file doesn't read: \(error.localizedDescription, privacy: .public)")
            status = .failed(String(localized: "le fichier « \(SyncFile.fileName) » est illisible"))
            return nil
        }
        guard file.minReaderFormat <= SyncFile.currentFormat, file.noteFormat <= NoteStore.formatVersion else {
            log.error("File written by a later version (format \(file.minReaderFormat), notes \(file.noteFormat))")
            status = .outdated
            return nil
        }
        return file
    }

    private func finish() {
        lastSyncAt = .now
        status = .upToDate
        guard !prunedBackups, let folderURL else { return }
        prunedBackups = true
        Task.detached(priority: .utility) { Self.pruneBackups(in: folderURL) }
    }

    /// Changes made here that the folder hasn't received yet.
    var hasUnsentChanges: Bool {
        folderURL != nil && SyncTracker(SyncPayload(store)).recordHashes != state.tracker.recordHashes
    }

    /// When the app quits: what is still to be sent is sent, within `limit` — never longer, so
    /// that a busy or unreachable iCloud Drive doesn't hold the app open. The main thread stays
    /// free meanwhile; a write cut short is harmless (it is atomic) and done at the next launch.
    func syncBeforeExit(within limit: Duration) async {
        scheduled?.cancel()
        let deadline = ContinuousClock.now + limit
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                // A synchronisation already under way ends first.
                while self?.isRunning == true, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                guard let self, self.hasUnsentChanges, !Task.isCancelled else { return }
                await self.sync(reason: "quit")
            }
            group.addTask { try? await Task.sleep(until: deadline) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Conflicts and backups

    /// A dated copy in `Backups/` of the shared folder: seen in the Finder, on every device.
    private func backUp(_ data: Data, label: String) {
        guard let folderURL else { return }
        let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let safeLabel = label.replacingOccurrences(of: "/", with: "-")
        let url = folderURL.appendingPathComponent("Backups").appendingPathComponent("void-notes-data \(stamp) \(safeLabel).json")
        do {
            try SyncFileIO.write(data, to: url)
            log.notice("Backup written: \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the backups older than `backupDays` days; returns how many went. Their date is
    /// the one in their name (also for those iCloud Drive keeps in the cloud, ".….json.icloud").
    @discardableResult
    nonisolated static func pruneBackups(in folder: URL, now: Date = .now) -> Int {
        let directory = folder.appendingPathComponent("Backups")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let cutoff = day(now.addingTimeInterval(-Double(backupDays) * 86400))
        var removed = 0
        for name in names where name.contains("void-notes-data ") {
            guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression), String(name[range]) < cutoff else { continue }
            SyncFileIO.remove(directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }

    /// "2026-10-07", as the name of a backup says its day.
    nonisolated private static func day(_ date: Date) -> String {
        date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current, calendar: Calendar(identifier: .gregorian)))
    }

    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}

/// A continuation is resumed once only (the read, or its time out).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// What the last synchronisation that went through left, on this device only (never synchronised).
private final class SyncState {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The notes at the last merge: the date and the print of each item.
    var tracker: SyncTracker {
        get {
            guard let data = defaults.data(forKey: "tracker"),
                  let tracker = try? SyncCoding.decoder().decode(SyncTracker.self, from: data)
            else { return SyncTracker() }
            return tracker
        }
        set {
            defaults.set(try? SyncCoding.encoder().encode(newValue), forKey: "tracker")
        }
    }

    /// The last change made here: the date given to what changed on this device.
    var lastLocalEditAt: Date? {
        get { defaults.object(forKey: "lastLocalEditAt") as? Date }
        set { defaults.set(newValue, forKey: "lastLocalEditAt") }
    }

    /// A new folder: what was deleted there is no longer known, the first merge puts everything together.
    func reset() {
        tracker = SyncTracker()
    }
}
