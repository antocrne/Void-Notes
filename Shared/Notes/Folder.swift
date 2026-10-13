import Foundation

/// A folder of notes. A folder with a `parent` is a subfolder; a note says which folder it is in
/// (`Note.folder`), a folder never lists its notes.
struct Folder: Identifiable, Codable, Equatable {
    static let defaultIcon = "folder"
    static let defaultName = "Nouveau dossier"

    /// The icons offered for a folder (SF Symbols).
    static let icons = [
        "folder", "tray.full", "archivebox", "doc.text", "book", "bookmark",
        "star", "heart", "flag", "tag", "lightbulb", "sparkles",
        "briefcase", "graduationcap", "calendar", "person", "house", "cart",
        "fork.knife", "paperplane", "map", "globe", "leaf", "pawprint",
        "camera", "music.note", "film", "gamecontroller", "hammer", "creditcard",
    ]

    let id: UUID
    var name: String
    /// SF Symbol name.
    var icon: String
    var parent: UUID?
    /// The space the folder is in — the one of its parent. Missing in files written before the
    /// spaces: the store puts the folder in the first one.
    var space: UUID?

    init(id: UUID = UUID(), name: String = Folder.defaultName, icon: String = Folder.defaultIcon, parent: UUID? = nil, space: UUID? = nil) {
        self.space = space
        self.id = id
        self.name = name
        self.icon = icon
        self.parent = parent
    }
}

/// Folder and space icons are all drawn in outline, like the rest of the chrome. The few symbols
/// chosen before, that only exist filled, are shown by their outline neighbour.
enum OutlineSymbol {
    static func name(_ symbol: String) -> String { replacements[symbol] ?? symbol }
    private static let replacements = ["airplane": "paperplane"]
}
