import Foundation

/// A separate set of folders and notes (Personnel, Travail…), as in Void: the list shows one
/// space at a time. A folder and a note say which space they are in; there is always at least one.
struct Space: Identifiable, Codable, Equatable {
    static var defaultName: String { String(localized: "Personnel") }
    static let defaultIcon = "person"
    static var newName: String { String(localized: "Nouvel espace") }

    /// The icons offered for a space (SF Symbols).
    static let icons = [
        "person", "briefcase", "house", "book", "graduationcap", "gamecontroller", "paintpalette", "music.note",
        "leaf", "flame", "star", "heart", "cart", "paperplane", "hammer", "circle",
    ]

    let id: UUID
    var name: String
    /// SF Symbol name.
    var icon: String
    /// When the space was made: the order of the spaces, the same on every device. Missing in
    /// files written before the synchronisation: the store dates them in the order they are in.
    var created: Date?

    init(id: UUID = UUID(), name: String = Space.defaultName, icon: String = Space.defaultIcon, created: Date? = .now) {
        self.created = created
        self.id = id
        self.name = name
        self.icon = icon
    }
}
