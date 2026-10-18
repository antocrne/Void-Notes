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

    /// Where its first paragraph — the title — ends, its line break included (UTF-16, like the runs).
    var headLength: Int {
        let string = text as NSString
        return string.length == 0 ? 0 : string.paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
    }

    /// The text of `range`, with its runs.
    func slice(_ range: NSRange) -> NoteContent {
        let string = text as NSString
        let range = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        let runs = runs.compactMap { run -> StyleRun? in
            let kept = NSIntersectionRange(NSRange(location: run.start, length: run.length), range)
            guard kept.length > 0 else { return nil }
            var run = run
            run.start = kept.location - range.location
            run.length = kept.length
            return run
        }
        return NoteContent(text: string.substring(with: range), runs: runs)
    }

    /// From `location` to the end.
    func slice(from location: Int) -> NoteContent {
        slice(NSRange(location: location, length: max(0, (text as NSString).length - location)))
    }

    static func + (lhs: NoteContent, rhs: NoteContent) -> NoteContent {
        let shift = (lhs.text as NSString).length
        return NoteContent(text: lhs.text + rhs.text, runs: lhs.runs + rhs.runs.map { run in
            var run = run
            run.start += shift
            return run
        })
    }
}

/// What a note holds besides its own text: the transcript of what its
/// listenings heard, and their summary — each shown in a tab of its own, under the title.
enum NotePart: String, CaseIterable {
    case notes, transcript, summary
}

/// A color a note is marked with, as the Finder's tags: several on one note, shown as dots after
/// its title. Only notes have them, not folders.
enum NoteTag: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }

    var label: String {
        switch self {
        case .red: String(localized: "Rouge")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Jaune")
        case .green: String(localized: "Vert")
        case .blue: String(localized: "Bleu")
        case .purple: String(localized: "Violet")
        case .gray: String(localized: "Gris")
        }
    }
}

struct Note: Identifiable, Equatable {
    let id: UUID
    var created: Date
    var modified: Date
    var content: NoteContent { didSet { summarize() } }
    /// The images of the note's album, shown under its title: their names in the note's
    /// attachments folder, in the order they show.
    var photos: [String] = [] { didSet { summarize() } }
    /// The sound recorded in the note (what the listening heard): their names
    /// in the note's attachments folder, in the order they were made. Shown in a section of their
    /// own, under the title, never in the text.
    var recordings: [String] = [] { didSet { summarize() } }
    /// What its listenings heard, apart from what is written in it; nil: never listened in.
    var transcript: NoteContent?
    /// The summary of the transcript; nil: never summarised.
    var summary: NoteContent?
    /// When the note was put in the trash; nil: it isn't there.
    var deleted: Date?
    /// Put away: out of the folders and of "Toutes les notes", under "Archives". It still is a
    /// note like the others: it is written, searched, filed.
    var archived = false
    /// Pinned at the top of the list, above "Toutes les notes" and the folders — and out of its
    /// folder there, so that it shows once. Archiving a note unpins it.
    var pinned = false
    /// Its colors, in the order of `NoteTag.allCases`, each once.
    var tags: [NoteTag] = []
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

    /// The text of one of its parts: the note's own, its transcript, its summary.
    func content(of part: NotePart) -> NoteContent? {
        switch part {
        case .notes: content
        case .transcript: transcript
        case .summary: summary
        }
    }

    /// Its title, then the text of `part`: what a tab shows.
    func composite(_ part: NotePart) -> NoteContent {
        guard part != .notes else { return content }
        var head = content.slice(NSRange(location: 0, length: content.headLength))
        if !head.text.hasSuffix("\n") { head.text += "\n" }
        return head + (content(of: part) ?? NoteContent())
    }

    /// Nothing written and nothing joined.
    var isBlank: Bool { title.isEmpty }

    /// The character an attachment stands for in the text.
    static let attachmentCharacter: Character = "\u{FFFC}"

    /// Names of the files joined to the note's text, in its order.
    var attachments: [String] { content.runs.compactMap(\.attachment) }

    /// Every word of the search is somewhere in the note (title included: it's its first line; its
    /// transcript and summary, if any) or
    /// in one of `names` — those of the folders it is in, say —, whatever the case and the accents.
    /// A locked note is found by its title only (and by those names).
    func matches(_ words: [String], alsoIn names: [String] = []) -> Bool {
        // Its transcript and its summary too (what the listenings heard).
        let fields = (locked ? [title] : [content.text, transcript?.text ?? "", summary?.text ?? ""]) + names
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
        if title.isEmpty, let file = content.runs.lazy.compactMap(\.attachment).first ?? photos.first ?? recordings.first { title = file }
        self.title = title
        preview = locked ? "" : String(rest.joined(separator: " ").prefix(200))
    }

    /// A title typed as a list item shows without its bullet or its box.
    private static func withoutMarker(_ line: String) -> String {
        [NoteFormat.bullet, NoteFormat.unchecked, NoteFormat.checked].contains { line.hasPrefix($0) } ? String(line.dropFirst(2)) : line
    }
}
