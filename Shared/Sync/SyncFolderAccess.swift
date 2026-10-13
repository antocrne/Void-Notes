import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The shared folder the user chose (typically "Void Notes" in iCloud Drive).
///
/// Without a paid developer account the app has no iCloud container of its own: access to the
/// folder is kept with a security-scoped bookmark, never with a path written in the code.
enum SyncFolderAccess {
    private static let bookmarkKey = "syncFolderBookmark"

    enum ResolveError: Error {
        case notConfigured
        case unavailable
    }

    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Remembers the folder.
    static func remember(_ url: URL) throws {
        // On iOS the picker's URL only reads once its access is open.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// The remembered folder, its access open for as long as the app runs.
    static func resolve() -> Result<URL, ResolveError> {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return .failure(.notConfigured) }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else { return .failure(.unavailable) }
        if isStale { try? remember(url) }
        return .success(url)
    }

    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope

    /// The folder panel; "Void Notes" can be made there, in iCloud Drive.
    @MainActor
    static func chooseFolder(prompt: String, message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif
}
