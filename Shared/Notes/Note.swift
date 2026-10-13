import Foundation

/// Kind of paragraph. A paragraph without one is plain body text.
enum NoteBlock: String, Codable, CaseIterable {
    case title, heading, subheading, quote
    /// A horizontal rule: a paragraph whose text is "---", shown as a line.
    case divider
    /// Where a note sent by another app comes from ("Source : https://…"): small and
    /// monospaced, like the dates under the title.
    case source

    var isHeading: Bool { self == .title || self == .heading || self == .subheading }
    /// A title, a heading or a divider is one line: Return at its end goes back to body text
    /// (a quote goes on).
    var isSingleLine: Bool { self != .quote }
}

/// Weight of a stretch of text, when it isn't the one its paragraph has by itself.
enum NoteWeight: String, Codable, CaseIterable {
    case light, medium, semibold, bold
}

/// Formatting of a stretch of text, in UTF-16 units (the units of NSString and of the editor).
/// Only what the stretch has is written: a bold word is `{"start": 4, "length": 5, "bold": true}`.
struct StyleRun: Codable, Equatable {
    var start: Int
    var length: Int
    var block: NoteBlock?
    var bold: Bool?
    var italic: Bool?
    /// A weight other than bold (bold stays `bold`, as in the first version of the format).
    var weight: NoteWeight?
    var highlight: Bool?
    /// A file joined to the note, shown where its character is (U+FFFC, one per file): its name
    /// in the note's attachments folder.
    var attachment: String?
    /// A link: the address the stretch opens (`https://…`, `mailto:…`).
    var link: String?
    /// Struck through (`~~texte~~`), apart from the done items of a checklist, which are by themselves.
    var strike: Bool?
    /// Inline code (`` `texte` ``): monospaced, on a light background.
    var code: Bool?
    /// Of a list item: how many steps it is indented (Tab), 1 to `NoteFormat.maxIndent`.
    var indent: Int?
}

/// What a note holds: its text as plain text (list markers "• ", "1. ", "☐ " and "☑ " included,
/// so the file reads on its own), and the formatting laid over it. No font, no color: those are worked out
/// when the note is shown, from the theme.
struct NoteContent: Codable, Equatable {
    var text = ""
    var runs: [StyleRun] = []
}

struct Note: Identifiable, Equatable {
    let id: UUID
    var created: Date
    var modified: Date
    var content: NoteContent { didSet { summarize() } }
    /// The images of the note's album, shown under its title: their names in the note's
    /// attachments folder, in the order they show.
    var photos: [String] = [] { didSet { summarize() } }
    /// When the note was put in the trash; nil: it isn't there.
    var deleted: Date?
    /// Put away: out of the folders and of "Toutes les notes", under "Archives". It still is a
    /// note like the others: it is written, searched, filed.
    var archived = false
    /// Pinned at the top of the list, above "Toutes les notes" and the folders — and out of its
    /// folder there, so that it shows once. Archiving a note unpins it.
    var pinned = false
    /// Shown only after Touch ID (or the Mac's password). The list still says its title; nothing
    /// else of it shows, and the search doesn't read its text.
    var locked = false { didSet { summarize() } }
    /// The folder the note is in; nil: in none.
    var folder: UUID?
    /// The space the note is in — the one of its folder, when it has one.
    var space: UUID?
    /// Written by a later version of Void Notes: shown, never rewritten.
    var isReadOnly = false

    /// First line with text in it; "" for a note without text.
    private(set) var title = ""
    /// The lines that follow, on one line.
    private(set) var preview = ""

    init(id: UUID = UUID(), created: Date = .now, modified: Date = .now, content: NoteContent = NoteContent(), folder: UUID? = nil, space: UUID? = nil) {
        self.id = id
        self.folder = folder
        self.space = space
        self.created = created
        self.modified = modified
        self.content = content
        summarize()
    }

    /// Nothing written and nothing joined.
    var isBlank: Bool { title.isEmpty }

    /// The character an attachment stands for in the text.
    static let attachmentCharacter: Character = "\u{FFFC}"

    /// Names of the files joined to the note's text, in its order.
    var attachments: [String] { content.runs.compactMap(\.attachment) }

    /// Every word of the search is somewhere in the note (title included: it's its first line) or
    /// in one of `names` — those of the folders it is in, say —, whatever the case and the accents.
    /// A locked note is found by its title only (and by those names).
    func matches(_ words: [String], alsoIn names: [String] = []) -> Bool {
        let fields = [locked ? title : content.text] + names
        return words.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Where the words of a search are in `text`, whatever the case and the accents: what the
    /// note shows on a soft background while the search lasts.
    static func found(_ words: [String], in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        for word in words where !word.isEmpty {
            var start = 0
            while start < string.length {
                let range = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: string.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                ranges.append(range)
                start = range.upperBound
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    private mutating func summarize() {
        var title = "", rest: [Substring] = []
        // The preview doesn't need more than the beginning of a long note.
        for line in content.text.prefix(2000).split(whereSeparator: \.isNewline) {
            // An image or a file isn't text.
            let trimmed = line.filter { $0 != Note.attachmentCharacter }.trimmingCharacters(in: .whitespaces)
            // A divider says nothing about the note.
            guard !trimmed.isEmpty, trimmed != NoteFormat.rule else { continue }
            if title.isEmpty { title = Note.withoutMarker(trimmed) } else { rest.append(Substring(trimmed)) }
            if rest.count == 4 { break }
        }
        // A note that is only a file is called after it.
        if title.isEmpty, let file = content.runs.lazy.compactMap(\.attachment).first ?? photos.first { title = file }
        self.title = title
        preview = locked ? "" : String(rest.joined(separator: " ").prefix(200))
    }

    /// A title typed as a list item shows without its bullet or its box.
    private static func withoutMarker(_ line: String) -> String {
        [NoteFormat.bullet, NoteFormat.unchecked, NoteFormat.checked].contains { line.hasPrefix($0) } ? String(line.dropFirst(2)) : line
    }
}
