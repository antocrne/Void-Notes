import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The note's text view, as the listening writes into it (Mac: `NoteTextView`, iPhone:
/// `NoteUITextView`).
@MainActor
protocol TranscriptHost: AnyObject {
    var transcriptStorage: NSTextStorage? { get }
    /// In a window: what is written there is seen.
    var isShown: Bool { get }
    /// The part of the note it shows: its own text, or — under its title — its transcript or its
    /// summary.
    var shownPart: NotePart { get }
    /// The cursor's place.
    var caret: Int { get }
    /// Writes `text` at `location`, formatted as the note would (one change, like a paste): the
    /// cursor stays where it is — or, if it was at `location`, goes on after the text, in view.
    func insertTranscript(_ text: NSAttributedString, at location: Int)
    /// Characters being composed (an accent, Japanese…): the text isn't touched meanwhile.
    var isComposing: Bool { get }
    /// Replaces ranges of the text (the last first), in one step of undo, the cursor kept where
    /// it was: the voices named once the listening ends, or renamed.
    func editRecording(_ edits: [(NSRange, NSAttributedString)])
}

/// Where the words heard go in a note, and how they are put together: plain sentences, a space
/// between them, a new paragraph after a pause or once a paragraph is long.
enum TranscriptText {
    /// Where the part shown starts in a tab's text (`Note.composite`): after the title — or at
    /// the start, for the note's own text.
    static func partStart(of part: NotePart, in string: NSString) -> Int {
        guard part != .notes, string.length > 0 else { return 0 }
        return string.paragraphRange(for: NSRange(location: 0, length: 0)).upperBound
    }

    /// Silence, in seconds, after which the next sentence starts a paragraph.
    static let pause: TimeInterval = 2.5
    /// Characters after which a paragraph ends at the next sentence.
    static let paragraphLength = 600

    /// What to write at `location` for a sentence: a line break or a space before it, as the text
    /// around asks. Nothing before it at the start of an empty line.
    static func piece(_ sentence: String, at location: Int, in string: NSString, newParagraph: Bool) -> String {
        guard location > 0, location <= string.length else { return sentence }
        let before = string.character(at: location - 1)
        if before == 10 { return sentence }
        if newParagraph { return "\n" + sentence }
        if let scalar = UnicodeScalar(before), CharacterSet.whitespaces.contains(scalar) { return sentence }
        return " " + sentence
    }

    /// The end of the paragraph `location` is in, before its line break: the listening never
    /// cuts a paragraph in two.
    static func paragraphEnd(of location: Int, in string: NSString) -> Int {
        let location = min(max(location, 0), string.length)
        let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
        return TypingRules.contentRange(of: paragraph, in: string).upperBound
    }

    /// The place where the next words go, after the text changed elsewhere: `edited` is the
    /// changed range as it is now, `delta` the change in length. What is typed right at that
    /// place pushes it along: the words heard come after it.
    static func anchor(_ anchor: Int, afterEditing edited: NSRange, delta: Int) -> Int {
        let oldEnd = edited.upperBound - delta
        if oldEnd <= anchor { return max(0, anchor + delta) }
        if edited.location < anchor { return max(edited.location, anchor + delta) }
        return anchor
    }

    /// A selection after `length` characters were written at `location`.
    static func moved(_ selection: NSRange, byInserting length: Int, at location: Int) -> NSRange {
        if selection.location >= location { return NSRange(location: selection.location + length, length: selection.length) }
        if selection.upperBound > location { return NSRange(location: selection.location, length: selection.length + length) }
        return selection
    }
}

/// When the next sentence starts a paragraph: after a pause, once a paragraph is long, and when
/// the other source speaks (the microphone after the Mac, or the other way).
struct TranscriptFlow {
    private var lastEnd: TimeInterval?
    private var lastChannel: ListenChannel?
    private var length = 0
    /// The microphone was away for a while (a call): what follows starts anew.
    var breaks = true

    mutating func startsParagraph(_ sentence: String, from start: TimeInterval, to end: TimeInterval, channel: ListenChannel = .microphone) -> Bool {
        defer {
            lastEnd = end
            lastChannel = channel
            breaks = false
        }
        let starts = breaks || lastEnd.map { start - $0 >= TranscriptText.pause } ?? true || length >= TranscriptText.paragraphLength
            || lastChannel != channel
        length = (starts ? 0 : length + 1) + sentence.count
        return starts
    }
}
