import Foundation
import UniformTypeIdentifiers

/// The voices named in a note's text, and the recordings an earlier beta put in it.
enum RecordingText {
    static let object = (String(Note.attachmentCharacter) as NSString).character(at: 0)

    /// A sound file: it goes with the recordings, not in the text.
    static func isAudio(_ name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .audio) == true
    }

    /// The sound files of the text (an earlier beta wrote recordings there): name and character.
    static func recordings(in text: NSAttributedString) -> [(name: String, location: Int)] {
        var out: [(String, Int)] = []
        let string = text.string as NSString
        text.enumerateAttribute(NoteFormat.attachmentKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let name = value as? String, isAudio(name) else { return }
            for index in range.location..<range.upperBound where string.character(at: index) == object { out.append((name, index)) }
        }
        return out
    }

    /// The voices named in the text: a bold name at the start of a paragraph, followed by a colon
    /// (what the listening writes, « Voix 1 : »). Each with where it is written.
    static func voices(in text: NSAttributedString) -> [(name: String, ranges: [NSRange])] {
        var out: [(name: String, ranges: [NSRange])] = []
        let string = text.string as NSString
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = paragraph.upperBound }
            guard paragraph.length > 0 else { break }
            var bold = NSRange()
            guard text.attribute(NoteFormat.boldKey, at: paragraph.location, longestEffectiveRange: &bold, in: paragraph) != nil else { continue }
            let name = string.substring(with: bold).trimmingCharacters(in: .whitespaces)
            let after = string.substring(from: bold.upperBound)
            guard !name.isEmpty, name.count <= 40, !name.contains("\n"), after.hasPrefix(" :") || after.hasPrefix(":") else { continue }
            if let index = out.firstIndex(where: { $0.name == name }) {
                out[index].ranges.append(bold)
            } else {
                out.append((name, [bold]))
            }
        }
        return out
    }

    /// The edits that rename voices, each new name keeping the look of the old one.
    static func renaming(_ names: [String: String], in text: NSAttributedString) -> [(NSRange, NSAttributedString)] {
        voices(in: text).flatMap { voice -> [(NSRange, NSAttributedString)] in
            guard let new = names[voice.name] else { return [] }
            return voice.ranges.map { range in (range, NSAttributedString(string: new, attributes: text.attributes(at: range.location, effectiveRange: nil))) }
        }
    }

    /// The edits that rename voices written as plain words (the summary's « Voix 1 : envoyer… »):
    /// each name found whole — not « Voix 1 » in « Voix 12 ».
    static func renamingWords(_ names: [String: String], in text: NSAttributedString) -> [(NSRange, NSAttributedString)] {
        let string = text.string as NSString
        var out: [(NSRange, NSAttributedString)] = []
        for (old, new) in names where !old.isEmpty {
            var from = 0
            while from < string.length {
                let found = string.range(of: old, range: NSRange(location: from, length: string.length - from))
                guard found.location != NSNotFound else { break }
                from = found.upperBound
                func isWord(_ index: Int) -> Bool {
                    guard index >= 0, index < string.length, let scalar = UnicodeScalar(string.character(at: index)) else { return false }
                    return CharacterSet.alphanumerics.contains(scalar)
                }
                guard !isWord(found.location - 1), !isWord(found.upperBound) else { continue }
                out.append((found, NSAttributedString(string: new, attributes: text.attributes(at: found.location, effectiveRange: nil))))
            }
        }
        return out
    }

    /// What goes when a sound file leaves the text: its character, and its line when it has one
    /// of its own.
    static func removal(at location: Int, in text: NSAttributedString) -> NSRange {
        let string = text.string as NSString
        let alone = (location == 0 || string.character(at: location - 1) == 10) && location + 1 < string.length && string.character(at: location + 1) == 10
        return NSRange(location: location, length: alone ? 2 : 1)
    }

    /// A selection after `edits` (applied last first).
    static func selection(_ selection: NSRange, after edits: [(NSRange, NSAttributedString)]) -> NSRange {
        var selection = selection
        for (range, text) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            let delta = text.length - range.length
            if range.upperBound <= selection.location {
                selection.location = max(range.location, selection.location + delta)
            } else if range.location < selection.upperBound {
                selection = NSRange(location: min(selection.location, range.location), length: 0)
            }
        }
        return selection
    }
}
