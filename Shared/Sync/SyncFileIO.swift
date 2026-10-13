import Foundation

/// Reads and writes in the shared folder. Everything goes through `NSFileCoordinator`, so that
/// iCloud Drive never syncs a file while it is being accessed, and every write is atomic: a
/// temporary file, then the final file replaced.
///
/// Blocking calls: off the main thread, except when the app quits.
enum SyncFileIO {
    enum ReadResult {
        /// The file isn't there yet (a new folder).
        case missing
        /// iCloud Drive doesn't have the latest version on this device yet; the download is started.
        case notDownloaded
        case contents(Data)
    }

    /// - Parameter waitForDownload: reads through coordination even if iCloud Drive doesn't have
    ///   the latest version: the read then waits for the download. On iPhone that's the only way
    ///   to get it (another app's file is never said to be "current" before it is read).
    static func read(_ url: URL, waitForDownload: Bool = defaultWaitsForDownload) throws -> ReadResult {
        let fileManager = FileManager.default
        // Still in the cloud, as a `.name.icloud` mark.
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        // Asks iCloud Drive to check for a newer version (nothing happens if it is here already).
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.fileExists(atPath: placeholder.path) else { return .missing }
            if !waitForDownload { return .notDownloaded }
        } else if !waitForDownload && !isCurrent(url) {
            // Without a network the coordinated read could wait forever: a stale copy isn't read.
            return .notDownloaded
        }

        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        do {
            return .contents(try result.get())
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        }
    }

    #if os(iOS)
    static let defaultWaitsForDownload = true
    #else
    static let defaultWaitsForDownload = false
    #endif

    static func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result { try replaceAtomically(writeURL, with: data) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// The file or the folder is there, downloaded or still in the cloud.
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud").path)
    }

    static func remove(_ url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { deleteURL in
            try? FileManager.default.removeItem(at: deleteURL)
        }
    }

    /// Conflict copies left by iCloud Drive. They aren't resolved here: kept, and reported.
    static func unresolvedConflicts(at url: URL) -> [NSFileVersion] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }

    /// Marks as resolved the conflict copies already merged; removes the old versions once none
    /// is left to deal with.
    static func resolve(_ versions: [NSFileVersion], at url: URL) throws {
        guard !versions.isEmpty else { return }
        var coordinationError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            result = Result {
                for version in versions { version.isResolved = true }
                if unresolvedConflicts(at: writeURL).isEmpty {
                    try NSFileVersion.removeOtherVersionsOfItem(at: writeURL)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// true if the local version is the latest iCloud Drive knows, or if the file isn't in the cloud.
    private static func isCurrent(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus
        else { return true }
        return status == .current
    }

    private static func replaceAtomically(_ url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // The temporary file is out of the shared folder, on the same volume: iCloud Drive only
        // sees the final result.
        let replacementDirectory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        defer { try? fileManager.removeItem(at: replacementDirectory) }
        let temporary = replacementDirectory.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
