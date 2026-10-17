import Foundation
#if os(macOS)
import AppKit

extension NoteTextView: TranscriptHost {
    var transcriptStorage: NSTextStorage? { textStorage }
    var isShown: Bool { window != nil }
    var shownPart: NotePart { part }
    var caret: Int { selectedRange().location }
    var isComposing: Bool { hasMarkedText() }

    /// Through `replace`, like a paste: no typing rule reads it ("- " stays a dash), it is
    /// formatted, and ⌘Z takes it back.
    func insertTranscript(_ text: NSAttributedString, at location: Int) {
        let selection = selectedRange()
        let follows = selection.length == 0 && selection.location == location
        replace(NSRange(location: location, length: 0), with: text)
        if follows {
            scrollRangeToVisible(selectedRange())
        } else {
            setSelectedRange(TranscriptText.moved(selection, byInserting: text.length, at: location))
        }
    }
}

// MARK: Recordings

extension NoteTextView {
    /// Edits of the text in one step of ⌘Z, the cursor kept where it was.
    func editRecording(_ edits: [(NSRange, NSAttributedString)]) {
        guard isEditable, !edits.isEmpty else { return }
        let selection = selectedRange()
        undoManager?.beginUndoGrouping()
        for (range, text) in edits.sorted(by: { $0.0.location > $1.0.location }) { replace(range, with: text) }
        undoManager?.endUndoGrouping()
        let after = RecordingText.selection(selection, after: edits)
        setSelectedRange(NSRange(location: min(after.location, (string as NSString).length), length: 0))
    }
}
#else
import UIKit

/// `insertTranscript` is in `NoteUITextView` itself: it goes through its own `replace`.
extension NoteUITextView: TranscriptHost {
    var transcriptStorage: NSTextStorage? { textStorage }
    var isShown: Bool { window != nil }
    /// The iPhone shows no tabs: the transcript goes to the note saved.
    var shownPart: NotePart { .notes }
    var caret: Int { selectedRange.location }
    var isComposing: Bool { markedTextRange != nil }
}
#endif
