import SwiftUI
import UIKit

/// Draws what a note shows that isn't text: the bar of a quote, the line of a divider, the box
/// of a checklist item.
final class NoteLayoutManager: MarkerLayoutManager {
    weak var view: NoteUITextView?

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        view?.drawDecorations(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// The text container of a note. Asking it for every line, rather than letting TextKit lay
/// lines out by itself, makes the room kept for the album hold for every paragraph: without
/// it, the text after the title, when it is the note's last paragraph, is laid out under the
/// album as if the room weren't there.
final class NoteTextContainer: NSTextContainer {
    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}

/// The text of a note on iPhone: a text view that formats as you type (see `TypingRules`), as
/// `NoteTextView` does on the Mac. What is typed shows formatted at once; the bar above the
/// keyboard does the same on a selection. Pasted text comes in in the note's style; its Markdown
/// marks are read.
final class NoteUITextView: UITextView, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// Called after every change of the text or its formatting.
    var onChange: (() -> Void)?
    /// Called when the cursor moves: the bar above the keyboard follows.
    var onSelectionChange: (() -> Void)?
    /// A tap on a joined file: shown.
    var onOpenFile: ((URL) -> Void)?
    /// Called when something is typed: the buttons over the note fade away.
    var onTyping: (() -> Void)?
    /// Called when the note is scrolled or touched: they come back.
    var onTouch: (() -> Void)?

    var accent: AccentChoice = .violet {
        didSet {
            tintColor = Theme.accentNS(accent)
            linkTextAttributes = [.foregroundColor: Theme.accentNS(accent), .underlineStyle: NSUnderlineStyle.single.rawValue]
            redrawDecorations()
        }
    }

    /// Dates of the note, written small and in monospace under its first paragraph (its title).
    var meta = "" {
        didSet {
            guard meta != oldValue else { return }
            metaLabel.text = meta
            setNeedsLayout()
        }
    }

    static let horizontalInset: CGFloat = 16
    static let topInset: CGFloat = 12

    private let metaLabel = UILabel()
    private let placeholder = UILabel()
    /// True while the view applies a change of its own, which the typing rules must not read.
    private var isApplyingRule = false
    private var isSettingTypingAttributes = false
    /// Characters changed since the last `textViewDidChange`, to be restyled.
    private var editedRange: NSRange?
    /// Return was just typed: after a title, the new line is body text.
    private var typedNewline = false

    /// A text view ready for a note. TextKit 1: the decorations are drawn from the layout
    /// manager's line rects.
    static func make() -> NoteUITextView {
        let storage = NSTextStorage()
        let layoutManager = NoteLayoutManager()
        let container = NoteTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let view = NoteUITextView(frame: .zero, textContainer: container)
        layoutManager.view = view
        return view
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        // "--" stays two dashes: the third one makes a divider.
        smartDashesType = .no
        smartQuotesType = .no
        dataDetectorTypes = []
        textContainerInset = UIEdgeInsets(top: Self.topInset, left: Self.horizontalInset, bottom: 48, right: Self.horizontalInset)
        delegate = self
        accessibilityLabel = String(localized: "Texte de la note")

        metaLabel.font = .monospacedSystemFont(ofSize: NoteFormat.metaSize, weight: .regular)
        metaLabel.textColor = Theme.secondaryTextNS
        // The dates are never cut: at large text sizes, they get a little smaller instead.
        metaLabel.adjustsFontSizeToFitWidth = true
        metaLabel.minimumScaleFactor = 0.6
        metaLabel.isAccessibilityElement = false
        addSubview(metaLabel)
        placeholder.textColor = Theme.secondaryTextNS.withAlphaComponent(0.55)
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: NoteUITextView, _: UITraitCollection) in
            view.redrawDecorations()
        }
        accent = .violet
    }

    required init?(coder: NSCoder) {
        fatalError("NoteUITextView is never archived")
    }

    private var string: NSString { textStorage.string as NSString }

    func load(_ content: NoteContent) {
        textStorage.setAttributedString(NoteFormat.attributedString(from: content, attachments: attachmentsDirectory))
        undoManager?.removeAllActions()
        selectedRange = NSRange(location: textStorage.length, length: 0)
        if content.text.isEmpty { setTyping(NoteFormat.attributes(block: .title)) }
        setNeedsLayout()
    }

    var content: NoteContent { NoteFormat.content(from: textStorage) }

    // MARK: Formatting as you type

    /// Every keystroke goes through here before it changes the text.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        onTyping?()
        if !isApplyingRule, markedTextRange == nil,
           let action = TypingRules.action(in: string, range: range, replacement: text, block: currentBlock, indent: currentIndent) {
            apply(action)
            return false
        }
        let changed = NSRange(location: range.location, length: text.utf16.count)
        editedRange = editedRange.map { NSUnionRange($0, changed) } ?? changed
        typedNewline = text == "\n"
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        // While a character is being composed (an accent, Korean…), the text is left alone.
        guard markedTextRange == nil else { return }
        let length = textStorage.length
        // What the keyboard changed without saying where (a correction): the cursor's paragraph.
        var range = editedRange ?? string.paragraphRange(for: NSRange(location: min(selectedRange.location, length), length: 0))
        editedRange = nil
        range.location = min(range.location, length)
        range.length = min(range.length, length - range.location)
        textStorage.beginEditing()
        NoteFormat.restyle(textStorage, in: range)
        textStorage.endEditing()
        if undoManager?.isUndoing != true, undoManager?.isRedoing != true { renumberLists(around: range) }
        if typedNewline {
            typedNewline = false
            // Return at the end of a title or heading: the next line is body text again.
            if currentBlock?.isSingleLine == true, string.paragraphRange(for: NSRange(location: selectedRange.location, length: 0)).length <= 1 {
                return setBlock(nil)
            }
        }
        didEdit(keepsUndo: true)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onTouch?()
    }

    /// The line being typed keeps some room under it, above the bar of the keyboard.
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        super.scrollRectToVisible(rect.insetBy(dx: 0, dy: -20), animated: animated)
    }

    /// A note of the trash is read, not written: its text steps back, as the list's does.
    func dimText() {
        textStorage.beginEditing()
        textStorage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            // The characters under the checklist boxes stay unseen.
            if value as? UIColor != .clear { textStorage.addAttribute(.foregroundColor, value: Theme.secondaryTextNS, range: range) }
        }
        textStorage.endEditing()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isSettingTypingAttributes, markedTextRange == nil else { return }
        // UIKit takes the typing attributes from the character before the cursor. What is typed
        // after a file is text, not the file again; nor the room kept after a checklist box.
        var attributes = typingAttributes
        for key in [NoteFormat.attachmentKey, .attachment, .kern, .strikethroughStyle, .strikethroughColor] { attributes[key] = nil }
        if attributes[NoteFormat.strikeKey] != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let selection = selectedRange
        if textStorage.length == 0 {
            // An empty note starts with its title.
            attributes = NoteFormat.attributes(block: .title)
        } else if selection.length == 0, selection.location == textStorage.length, textStorage.string.last?.isNewline == true,
                  NoteFormat.block(in: attributes)?.isSingleLine == true {
            // On an empty last line the character before is the previous line's break: without
            // this, the line after a title would be a title too.
            attributes = NoteFormat.attributes(block: nil)
        }
        // At the end of a link, what is typed isn't part of it.
        setTyping(NoteFormat.typingAttributes(attributes, at: selection.location, in: textStorage))
        onSelectionChange?()
    }

    private func apply(_ action: TypingRules.Action) {
        switch action {
        case .replace(let range, let text):
            replace(range, with: NSAttributedString(string: text, attributes: typingAttributes))
        case .setBlock(let block, let marker):
            if marker.length > 0 { replace(marker, with: NSAttributedString()) }
            setBlock(block)
        case .inline(let range, let content, let style):
            let key = NoteFormat.key(of: style)
            let piece = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: content))
            piece.addAttribute(key, value: true, range: NSRange(location: 0, length: piece.length))
            if style == .bold { piece.removeAttribute(NoteFormat.weightKey, range: NSRange(location: 0, length: piece.length)) }
            // What is typed next is outside the passage.
            var typing = typingAttributes
            replace(range, with: piece)
            typing[key] = nil
            setTyping(typing)
        case .divider(let range):
            placeDivider(replacing: range)
        case .indent(let steps):
            changeIndent(by: steps)
        }
    }

    /// Puts a divider in the paragraph of `range`, which holds nothing else than `range`; the
    /// cursor goes to the line that follows.
    private func placeDivider(replacing range: NSRange) {
        // An empty last line has no break yet: the divider brings the line that follows it.
        let hasBreak = range.upperBound < string.length
        replace(range, with: NSAttributedString(string: NoteFormat.rule + (hasBreak ? "" : "\n"), attributes: NoteFormat.attributes(block: .divider)))
        if hasBreak {
            selectedRange = NSRange(location: selectedRange.location + 1, length: 0)
        } else {
            setTyping(NoteFormat.attributes(block: nil))
        }
    }

    /// A change made by the view; the cursor ends up after it.
    private func replace(_ range: NSRange, with text: NSAttributedString) {
        isApplyingRule = true
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: range, with: text)
        NoteFormat.restyle(textStorage, in: NSRange(location: range.location, length: text.length))
        textStorage.endEditing()
        isApplyingRule = false
        selectedRange = NSRange(location: range.location + text.length, length: 0)
        didEdit()
        renumberLists(around: NSRange(location: range.location, length: text.length))
    }

    /// True while the numbers of a list are being written again.
    private var isRenumbering = false

    /// The numbered list around `range` counts again from its first item (see `ListNumbering`).
    private func renumberLists(around range: NSRange) {
        guard !isRenumbering else { return }
        let fixes = ListNumbering.fixes(in: textStorage, around: range)
        guard !fixes.isEmpty else { return }
        isRenumbering = true
        defer { isRenumbering = false }
        var selection = selectedRange
        for fix in fixes {
            replace(fix.range, with: NSAttributedString(string: fix.marker, attributes: textStorage.attributes(at: fix.range.location, effectiveRange: nil)))
            let start = ListNumbering.moved(selection.location, by: fix), end = ListNumbering.moved(selection.upperBound, by: fix)
            selection = NSRange(location: start, length: end - start)
        }
        selectedRange = selection
    }

    /// The text or its formatting just changed. A change made by the view itself isn't known to
    /// the keyboard's undo, whose earlier steps no longer fit the text: they are forgotten.
    private func didEdit(keepsUndo: Bool = false) {
        if !keepsUndo { undoManager?.removeAllActions() }
        redrawDecorations()
        setNeedsLayout()
        onChange?()
        onSelectionChange?()
    }

    /// Backspace at the very start of a title, heading or quote turns it back into body text.
    /// A divider goes in one piece: from its own line, or from the start of the line after it.
    override func deleteBackward() {
        let selection = selectedRange
        guard selection.length == 0, markedTextRange == nil, isEditable else { return super.deleteBackward() }
        let paragraph = string.paragraphRange(for: selection)
        if currentBlock == .divider {
            replace(TypingRules.contentRange(of: paragraph, in: string), with: NSAttributedString())
            setTyping(NoteFormat.attributes(block: nil))
        } else if paragraph.location == selection.location, currentBlock != nil {
            setBlock(nil)
        } else if paragraph.location == selection.location, selection.location > 0,
                  case let previous = string.paragraphRange(for: NSRange(location: selection.location - 1, length: 0)),
                  NoteFormat.block(in: textStorage.attributes(at: previous.location, effectiveRange: nil)) == .divider {
            replace(previous, with: NSAttributedString())
        } else {
            super.deleteBackward()
        }
    }

    /// The note ends with a title or a heading: there is no line after it to tap on. Tapping
    /// under it makes that line, in body text.
    private func startTextAfterLastHeading() -> Bool {
        guard isEditable, textStorage.length > 0, textStorage.string.last?.isNewline == false,
              NoteFormat.block(in: textStorage.attributes(at: textStorage.length - 1, effectiveRange: nil))?.isHeading == true
        else { return false }
        replace(NSRange(location: textStorage.length, length: 0), with: NSAttributedString(string: "\n", attributes: typingAttributes))
        setBlock(nil)
        return true
    }

    // MARK: Formatting commands (the bar above the keyboard)

    /// Kind of the paragraph the cursor is in.
    var currentBlock: NoteBlock? {
        let paragraph = string.paragraphRange(for: NSRange(location: min(selectedRange.location, string.length), length: 0))
        if paragraph.length > 0 {
            return NoteFormat.block(in: textStorage.attributes(at: paragraph.location, effectiveRange: nil))
        }
        // An empty last line has no character to carry its kind yet.
        return NoteFormat.block(in: typingAttributes)
    }

    /// Applies to the whole paragraphs of the selection; nil: body text.
    func setBlock(_ block: NoteBlock?) {
        guard isEditable else { return }
        let paragraphs = string.paragraphRange(for: selectedRange)
        if paragraphs.length > 0 {
            textStorage.beginEditing()
            if let block {
                textStorage.addAttribute(NoteFormat.blockKey, value: block.rawValue, range: paragraphs)
            } else {
                textStorage.removeAttribute(NoteFormat.blockKey, range: paragraphs)
            }
            NoteFormat.restyle(textStorage, in: paragraphs)
            textStorage.endEditing()
        }
        var typing = typingAttributes
        typing[NoteFormat.blockKey] = block?.rawValue
        setTyping(typing)
        didEdit()
    }

    func toggleBold() { setWeight(isOn(NoteFormat.boldKey) ? nil : .bold) }
    func toggleItalic() { toggle(NoteFormat.italicKey) }
    func toggleHighlight() { toggle(NoteFormat.highlightKey) }
    func toggleStrike() { toggle(NoteFormat.strikeKey) }
    func toggleCode() { toggle(NoteFormat.codeKey) }

    var isBold: Bool { isOn(NoteFormat.boldKey) }
    var isItalic: Bool { currentAttributes[NoteFormat.italicKey] != nil }
    var isHighlighted: Bool { currentAttributes[NoteFormat.highlightKey] != nil }
    var isStruck: Bool { currentAttributes[NoteFormat.strikeKey] != nil }
    var isCode: Bool { currentAttributes[NoteFormat.codeKey] != nil }

    /// Steps of indentation of the list item the cursor is in.
    var currentIndent: Int {
        let paragraph = string.paragraphRange(for: NSRange(location: min(selectedRange.location, string.length), length: 0))
        return paragraph.length > 0 ? NoteFormat.indent(at: paragraph.location, in: textStorage) : NoteFormat.indent(in: typingAttributes)
    }

    /// Indents the list items of the selection by `steps` (negative: back), between none and
    /// `NoteFormat.maxIndent`. The numbers of a numbered list follow.
    func changeIndent(by steps: Int) {
        guard isEditable else { return }
        let items = selectedParagraphs.filter { ListMarker.marker(in: string, paragraph: $0) != nil }
        let changes = items.map { ($0, min(max(NoteFormat.indent(at: $0.location, in: textStorage) + steps, 0), NoteFormat.maxIndent)) }
            .filter { NoteFormat.indent(at: $0.0.location, in: textStorage) != $0.1 }
        guard let first = changes.first, let last = changes.last else { return }
        let span = NSUnionRange(first.0, last.0)
        let selection = selectedRange
        textStorage.beginEditing()
        for (paragraph, indent) in changes {
            if indent > 0 {
                textStorage.addAttribute(NoteFormat.indentKey, value: indent, range: paragraph)
            } else {
                textStorage.removeAttribute(NoteFormat.indentKey, range: paragraph)
            }
        }
        NoteFormat.restyle(textStorage, in: span)
        textStorage.endEditing()
        selectedRange = selection
        // What is typed next — the item that Return makes — has the same indentation.
        var typing = typingAttributes
        let indent = currentIndent
        typing[NoteFormat.indentKey] = indent > 0 ? indent : nil
        setTyping(typing)
        didEdit()
        renumberLists(around: span)
    }

    /// ⇧Tab on a keyboard: the list item comes back one step (Tab, typed, indents it).
    override var keyCommands: [UIKeyCommand]? {
        let back = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent))
        back.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [back]
    }

    @objc private func outdent() { changeIndent(by: -1) }

    private var currentAttributes: [NSAttributedString.Key: Any] {
        let selection = selectedRange
        if selection.length > 0, selection.location < textStorage.length { return textStorage.attributes(at: selection.location, effectiveRange: nil) }
        return typingAttributes
    }

    /// On the selection, or on what is typed next when nothing is selected. nil: the weight the
    /// paragraph has by itself.
    func setWeight(_ weight: NoteWeight?) {
        change { attributes in
            attributes[NoteFormat.boldKey] = weight == .bold ? true : nil
            attributes[NoteFormat.weightKey] = weight == .bold ? nil : weight?.rawValue
        }
    }

    /// Already on everywhere: turned off; otherwise turned on everywhere.
    private func toggle(_ key: NSAttributedString.Key) {
        let on = !isOn(key)
        change { $0[key] = on ? true : nil }
    }

    /// The whole selection has the attribute (or what is typed next, when nothing is selected).
    private func isOn(_ key: NSAttributedString.Key) -> Bool {
        let range = selectedRange
        guard range.length > 0 else { return typingAttributes[key] != nil }
        var covered = NSRange()
        return textStorage.attribute(key, at: range.location, longestEffectiveRange: &covered, in: range) != nil && covered.upperBound >= range.upperBound
    }

    /// Changes semantic attributes of the selection, or of what is typed next.
    private func change(_ edit: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard isEditable else { return }
        let range = selectedRange
        guard range.length > 0 else {
            var typing = typingAttributes
            edit(&typing)
            setTyping(typing)
            onSelectionChange?()
            return
        }
        var pieces: [(NSRange, [NSAttributedString.Key: Any])] = []
        textStorage.enumerateAttributes(in: range) { attributes, piece, _ in
            var attributes = attributes
            edit(&attributes)
            pieces.append((piece, attributes))
        }
        textStorage.beginEditing()
        for (piece, attributes) in pieces { textStorage.setAttributes(attributes, range: piece) }
        NoteFormat.restyle(textStorage, in: range)
        textStorage.endEditing()
        selectedRange = range
        didEdit()
    }

    /// A divider under the paragraph of the cursor (in its place if that paragraph is empty).
    func insertDivider() {
        guard isEditable else { return }
        let paragraph = string.paragraphRange(for: NSRange(location: selectedRange.location, length: 0))
        let content = TypingRules.contentRange(of: paragraph, in: string)
        if content.length > 0 {
            replace(NSRange(location: content.upperBound, length: 0), with: NSAttributedString(string: "\n", attributes: NoteFormat.attributes(block: nil)))
        }
        placeDivider(replacing: NSRange(location: selectedRange.location, length: 0))
    }

    // MARK: Links

    /// Address of the link the cursor is in (or at the end of), or that the selection starts in.
    var currentLink: String? { NoteFormat.link(at: selectedRange.location, in: textStorage)?.address }

    /// Makes the selection a link to `url`; with nothing selected, the link the cursor is in
    /// changes address. nil: the link goes, its text stays. Nothing selected outside a link, the
    /// address itself is written, as a link.
    func setLink(_ url: URL?) {
        guard isEditable else { return }
        var range = selectedRange
        if range.length == 0, let link = NoteFormat.link(at: range.location, in: textStorage) { range = link.range }
        // A line break or a space at the end of the selection isn't part of the link.
        while range.length > 0, let scalar = UnicodeScalar(string.character(at: range.upperBound - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            range.length -= 1
        }
        if range.length == 0 {
            guard let url, selectedRange.length == 0 else { return }
            let shown = url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
            var attributes = typingAttributes
            attributes[NoteFormat.linkKey] = url.absoluteString
            replace(selectedRange, with: NSAttributedString(string: shown, attributes: attributes))
            setTyping(NoteFormat.typingAttributes(typingAttributes, at: selectedRange.location, in: textStorage))
            return
        }
        textStorage.beginEditing()
        if let url {
            textStorage.addAttribute(NoteFormat.linkKey, value: url.absoluteString, range: range)
        } else {
            textStorage.removeAttribute(NoteFormat.linkKey, range: range)
        }
        NoteFormat.restyle(textStorage, in: range)
        textStorage.endEditing()
        didEdit()
    }

    /// The paragraphs the selection touches. Empty lines of a longer selection are left out.
    private var selectedParagraphs: [NSRange] {
        let string = self.string
        let span = string.paragraphRange(for: selectedRange)
        var paragraphs: [NSRange] = []
        var location = span.location
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            location = paragraph.upperBound
        } while location < span.upperBound && paragraphs.last!.length > 0
        if paragraphs.count > 1 {
            paragraphs.removeAll { string.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return paragraphs
    }

    /// The kind of list the cursor is in; nil: in none.
    var currentList: ListMarker.Kind? {
        selectedParagraphs.first.flatMap { ListMarker.marker(in: string, paragraph: $0)?.kind }
    }

    /// Turns the selected paragraphs into list items, or back into plain paragraphs if they all
    /// are items of that kind already. An item that changes kind keeps its text; a checklist
    /// item that already is one keeps its check.
    func toggleList(_ kind: ListMarker.Kind) {
        guard isEditable else { return }
        let selection = selectedRange
        let paragraphs = selectedParagraphs
        let markers = paragraphs.map { ListMarker.marker(in: string, paragraph: $0) }
        let removing = !markers.isEmpty && markers.allSatisfy { $0?.kind == kind }
        var end = selection.upperBound
        for (index, paragraph) in paragraphs.enumerated().reversed() {
            if !removing, kind == .checklist, markers[index]?.kind == .checklist { continue }
            let old = NSRange(location: paragraph.location, length: markers[index]?.text.utf16.count ?? 0)
            let new = removing ? "" : ListMarker.text(kind, number: index + 1)
            replace(old, with: NSAttributedString(string: new, attributes: typingAttributes))
            end += new.utf16.count - old.length
        }
        selectedRange = NSRange(location: min(max(end, 0), string.length), length: 0)
    }

    // MARK: Checklists

    /// A tap at `point` (in the view): true if it was on the box of a checklist item, which it
    /// checked or unchecked.
    private func toggleCheckbox(at point: CGPoint) -> Bool {
        guard isEditable, let paragraph = checklistParagraph(at: point), let checked = ListMarker.marker(in: string, paragraph: paragraph)?.checked else { return false }
        setChecked(!checked, at: paragraph.location)
        // Felt as well as seen.
        UISelectionFeedbackGenerator().selectionChanged()
        sortChecklistsSoon(around: paragraph.location)
        return true
    }

    /// Items just checked or unchecked, whose lists are to be put in order.
    private var unsortedItems: [Int] = []
    /// The text as it was when they were: typed in since, it is left as it is.
    private var unsortedText = ""
    private var sortRequest = 0

    /// A moment after an item is checked (time to see it checked), it goes down to the end of
    /// what is still to do, as in Apple Notes; unchecked, it goes back up there. Several items
    /// checked in a row move together.
    private func sortChecklistsSoon(around location: Int) {
        unsortedItems.append(location)
        unsortedText = textStorage.string
        sortRequest += 1
        let request = sortRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + NoteFormat.checklistSortDelay) { [weak self] in
            guard let self, self.sortRequest == request else { return }
            self.sortChecklists()
        }
    }

    private func sortChecklists() {
        let locations = unsortedItems
        unsortedItems = []
        guard isEditable, textStorage.string == unsortedText else { return }
        let sorts = locations.compactMap { ChecklistSort(textStorage, around: $0) }
        guard !sorts.isEmpty else { return }
        // The lines change places in a quick cross-fade.
        UIView.transition(with: self, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            var sorted = Set<Int>()
            // Sorting keeps the length of the text: the other locations stay right.
            for sort in sorts where sorted.insert(sort.range.location).inserted {
                let selection = self.selectedRange
                self.replace(sort.range, with: sort.text)
                // The cursor follows the item it was in.
                let start = sort.moved(selection.location), end = sort.moved(selection.upperBound)
                self.selectedRange = end - start == selection.length ? NSRange(location: start, length: selection.length) : NSRange(location: start, length: 0)
            }
        }
    }

    /// The checklist item whose box is at `point`, a finger wide.
    private func checklistParagraph(at point: CGPoint) -> NSRange? {
        guard textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let index = layoutManager.characterIndex(for: inContainer, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let paragraph = string.paragraphRange(for: NSRange(location: min(index, string.length), length: 0))
        guard ListMarker.marker(in: string, paragraph: paragraph)?.checked != nil,
              let box = checkboxRect(at: paragraph.location)?.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top),
              box.insetBy(dx: -12, dy: -10).contains(point)
        else { return nil }
        return paragraph
    }

    /// Changes the marker of the checklist item that starts at `location`; the cursor stays.
    private func setChecked(_ checked: Bool, at location: Int) {
        guard location < textStorage.length else { return }
        let selection = selectedRange
        let box = String((checked ? NoteFormat.checked : NoteFormat.unchecked).prefix(1))
        replace(NSRange(location: location, length: 1), with: NSAttributedString(string: box, attributes: textStorage.attributes(at: location, effectiveRange: nil)))
        selectedRange = selection
    }

    /// Where the box of the checklist item that starts at `location` is drawn, in the text
    /// container: in place of its character, centered on the capitals of the line.
    private func checkboxRect(at location: Int) -> CGRect? {
        guard location < textStorage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = layoutManager.location(forGlyphAt: glyph)
        let font = NoteFormat.font(block: NoteFormat.block(in: textStorage.attributes(at: location, effectiveRange: nil)), weight: nil, italic: false)
        let side = NoteFormat.boxSide(font)
        let middle = line.minY + position.y - font.capHeight / 2
        return CGRect(x: (line.minX + position.x).rounded(), y: (middle - side / 2).rounded(), width: side, height: side)
    }

    private func setTyping(_ attributes: [NSAttributedString.Key: Any]) {
        var attributes = attributes
        attributes[NoteFormat.attachmentKey] = nil
        attributes[.attachment] = nil
        let block = NoteFormat.block(in: attributes)
        attributes[.font] = NoteFormat.font(block: block, attributes: attributes)
        attributes[.backgroundColor] = attributes[NoteFormat.highlightKey] != nil ? Theme.highlightNS : attributes[NoteFormat.codeKey] != nil ? Theme.codeBackgroundNS : nil
        attributes[.foregroundColor] = NoteFormat.color(block)
        attributes[.paragraphStyle] = NoteFormat.paragraphStyle(block: block, indent: NoteFormat.indent(in: attributes))
        attributes[.kern] = nil
        attributes[.strikethroughStyle] = attributes[NoteFormat.strikeKey] != nil ? NSUnderlineStyle.single.rawValue : nil
        attributes[.strikethroughColor] = nil
        // Worked out from `NoteFormat.linkKey` once typed.
        attributes[.link] = nil
        attributes[.underlineStyle] = nil
        isSettingTypingAttributes = true
        typingAttributes = attributes
        isSettingTypingAttributes = false
        setNeedsLayout()
    }

    // MARK: Pasting

    /// Text comes in in the note's style — formatted when it is written in Markdown (titles,
    /// lists, bold, links…), the marks gone. An image goes to the note's album.
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = UIPasteboard.general
        if !pasteboard.hasStrings, let image = pasteboard.image, let data = image.pngData(), let addPhotoData {
            return addPhotoData(data, "Image.png")
        }
        guard let pasted = pasteboard.string, !pasted.isEmpty else { return }
        // The character of a file copied from a note comes without its file.
        let text = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: String(Note.attachmentCharacter), with: "")
        guard !text.isEmpty else { return }
        if NoteMarkdown.looksLikeMarkdown(text) {
            let location = selectedRange.location
            let startsLine = location == 0 || string.character(at: location - 1) == 10
            return replace(selectedRange, with: NoteMarkdown.pasted(text, typing: typingAttributes, startsLine: startsLine))
        }
        let piece = NSMutableAttributedString(string: text, attributes: typingAttributes)
        // Pasted into a title, only the first line is part of the title.
        if currentBlock?.isHeading == true, let firstBreak = text.firstIndex(of: "\n") {
            let rest = NSRange(firstBreak..., in: text)
            piece.setAttributes(NoteFormat.attributes(block: nil), range: NSRange(location: rest.location + 1, length: rest.length - 1))
        }
        replace(selectedRange, with: piece)
    }

    // MARK: Attachments

    /// Folder of the files joined to the note.
    var attachmentsDirectory: URL?
    /// Adds a pasted image to the note's album.
    var addPhotoData: ((Data, String) -> Void)?

    /// Each file on a line of its own, in body text; the cursor ends up on the line after them.
    func insertAttachments(_ names: [String]) {
        guard isEditable, !names.isEmpty else { return }
        let range = selectedRange
        let body = NoteFormat.attributes(block: nil)
        let piece = NSMutableAttributedString()
        if range.location > 0, string.character(at: range.location - 1) != 10 { piece.append(NSAttributedString(string: "\n", attributes: body)) }
        for name in names {
            piece.append(NoteAttachmentCell.character(name: name, directory: attachmentsDirectory))
            piece.append(NSAttributedString(string: "\n", attributes: body))
        }
        // Already followed by a line break: no empty line is added.
        if range.upperBound < string.length, string.character(at: range.upperBound) == 10 { piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1)) }
        replace(range, with: piece)
        if selectedRange.location < string.length, string.character(at: selectedRange.location) == 10 {
            selectedRange = NSRange(location: selectedRange.location + 1, length: 0)
        }
        setTyping(body)
    }

    // MARK: Listening

    /// The tab shown: the note's own text, or its title and its transcript or summary.
    var part: NotePart = .notes

    /// Writes what the listening heard (`Listener`) at `location`, formatted like a paste — no
    /// typing rule reads it. The cursor stays where it is, or goes on after the words, in view,
    /// if it was there.
    func insertTranscript(_ text: NSAttributedString, at location: Int) {
        let selection = selectedRange
        let follows = selection.length == 0 && selection.location == location
        replace(NSRange(location: location, length: 0), with: text)
        if follows {
            scrollRangeToVisible(selectedRange)
        } else {
            selectedRange = TranscriptText.moved(selection, byInserting: text.length, at: location)
        }
    }

    /// Edits after the listening (the voices named, the summary written), the cursor kept where
    /// it was.
    func editRecording(_ edits: [(NSRange, NSAttributedString)]) {
        guard isEditable, !edits.isEmpty else { return }
        let selection = selectedRange
        undoManager?.beginUndoGrouping()
        for (range, text) in edits.sorted(by: { $0.0.location > $1.0.location }) { replace(range, with: text) }
        undoManager?.endUndoGrouping()
        let after = RecordingText.selection(selection, after: edits)
        selectedRange = NSRange(location: min(after.location, textStorage.length), length: 0)
        setNeedsLayout()
    }

    // MARK: Taps

    /// A tap on a checklist box doesn't move the cursor or bring the keyboard.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer, gestureRecognizer.delegate !== self, isEditable,
           checklistParagraph(at: gestureRecognizer.location(in: self)) != nil {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onTouch?()
        let point = gesture.location(in: self)
        if toggleCheckbox(at: point) { return }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        // Under everything written.
        layoutManager.ensureLayout(for: textContainer)
        if inContainer.y > layoutManager.usedRect(for: textContainer).maxY {
            if startTextAfterLastHeading() { becomeFirstResponder() }
            return
        }
        // A joined file: shown.
        guard textStorage.length > 0 else { return }
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(inContainer) else { return }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        // A link: opened, as in Notes.
        if index < textStorage.length, let link = (textStorage.attribute(NoteFormat.linkKey, at: index, effectiveRange: nil) as? String).flatMap(URL.init(string:)) {
            resignFirstResponder()
            UIApplication.shared.open(link)
            return
        }
        if index < textStorage.length, let file = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? NoteFileAttachment,
           let url = file.url, FileManager.default.fileExists(atPath: url.path) {
            resignFirstResponder()
            onOpenFile?(url)
        }
    }

    // MARK: Layout and drawing

    /// The note's album of images, shown under the dates. The text makes room for it.
    var album: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let album { addSubview(album) }
            setNeedsLayout()
        }
    }

    /// Height the album takes; 0: the note has no image.
    var albumHeight: CGFloat = 0 {
        didSet { if albumHeight != oldValue { setNeedsLayout() } }
    }

    private var albumRoom: CGRect?

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHeader()
    }

    /// The dates go under the first paragraph, the album under the dates; the text that follows
    /// starts below it.
    private func layoutHeader() {
        let padding = textContainer.lineFragmentPadding
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        let width = bounds.width - textContainerInset.left - textContainerInset.right - 2 * padding

        let block = NoteFormat.block(in: typingAttributes)
        placeholder.isHidden = textStorage.length > 0
        if textStorage.length == 0 {
            placeholder.font = NoteFormat.font(block: block, weight: nil, italic: false)
            placeholder.text = block == .title ? String(localized: "Titre") : String(localized: "Écrivez…")
            placeholder.sizeToFit()
            placeholder.frame.origin = CGPoint(x: origin.x + padding + (block == .quote ? NoteFormat.quoteIndent : 0), y: origin.y)
        }

        guard var place = metaPlace() else {
            metaLabel.isHidden = true
            album?.isHidden = true
            return
        }
        var top: CGFloat = 0
        if let album, albumHeight > 0 {
            // The room kept for the album moves the text, the first paragraph included when it
            // has just grown into that room: measured again until it stays where it is.
            for _ in 0..<4 {
                // Under the dates, as far from them whether text follows the title or not.
                top = max(place.bottom, place.top + NoteFormat.metaSpace + 10) + 8
                let room = CGRect(x: 0, y: place.bottom + 1, width: textContainer.size.width, height: top + albumHeight + 8 - place.bottom - 1)
                if albumRoom == room { break }
                albumRoom = room
                textContainer.exclusionPaths = [UIBezierPath(rect: room)]
                guard let moved = metaPlace(), moved != place else { break }
                place = moved
            }
            let frame = CGRect(x: origin.x + padding, y: origin.y + top, width: width, height: albumHeight)
            if album.frame != frame { album.frame = frame }
            album.isHidden = false
        } else {
            album?.isHidden = true
            if albumRoom != nil {
                albumRoom = nil
                textContainer.exclusionPaths = []
            }
        }
        metaLabel.isHidden = meta.isEmpty
        metaLabel.frame = CGRect(x: origin.x + padding, y: origin.y + place.top + 3, width: width, height: ceil(metaLabel.font.lineHeight))
    }

    /// Where the dates are written, in the text container: `top`, where their room starts, and
    /// `bottom`, the end of the first paragraph's last line. nil: the paragraph isn't laid out.
    private func metaPlace() -> (top: CGFloat, bottom: CGFloat)? {
        if textStorage.length == 0 {
            let line = max(layoutManager.extraLineFragmentRect.maxY, NoteFormat.size(.title) + 8)
            return (line, line)
        }
        let first = string.paragraphRange(for: NSRange(location: 0, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: first, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.upperBound - 1, effectiveRange: nil)
        var y = line.maxY
        // The room kept under the paragraph is part of its last line — except when the
        // paragraph is the whole note: nothing follows, nothing is kept.
        let style = textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        if first.upperBound < textStorage.length || textStorage.string.last?.isNewline == true {
            y -= style?.paragraphSpacing ?? 0
        } else {
            y += style?.lineSpacing ?? 0
        }
        return (y, line.maxY)
    }

    private func redrawDecorations() {
        guard textStorage.length > 0 else { return }
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
    }

    /// The words searched for in the list: shown in the note on a soft background while the
    /// search lasts; the first one is brought into view when the note opens.
    var searchWords: [String] = [] {
        didSet {
            guard searchWords != oldValue else { return }
            redrawDecorations()
            if oldValue.isEmpty, let first = Note.found(searchWords, in: textStorage.string).first {
                DispatchQueue.main.async { [weak self] in self?.scrollRangeToVisible(first) }
            }
        }
    }

    /// Called by the layout manager while it draws the background of `glyphs`; `origin` is
    /// where the text container starts.
    func drawDecorations(forGlyphRange glyphs: NSRange, at origin: CGPoint) {
        guard textStorage.length > 0, glyphs.length > 0 else { return }
        let string = self.string
        if !searchWords.isEmpty {
            let shownCharacters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            Theme.accentNS(accent).resolvedColor(with: traitCollection).withAlphaComponent(0.3).setFill()
            for found in Note.found(searchWords, in: string as String) where NSIntersectionRange(found, shownCharacters).length > 0 {
                layoutManager.enumerateEnclosingRects(forGlyphRange: layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil),
                                                      withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                    UIBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: 3).fill()
                }
            }
        }
        let shown = string.paragraphRange(for: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        let padding = textContainer.lineFragmentPadding
        let accentColor = Theme.accentNS(accent).resolvedColor(with: traitCollection)
        let secondary = Theme.secondaryTextNS.resolvedColor(with: traitCollection)

        var location = shown.location
        while location < shown.upperBound {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = paragraph.upperBound
            switch NoteFormat.block(in: textStorage.attributes(at: paragraph.location, effectiveRange: nil)) {
            case .quote:
                // A bar in the accent color along the quote.
                let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil), in: textContainer)
                accentColor.setFill()
                UIBezierPath(roundedRect: CGRect(x: origin.x + padding, y: origin.y + rect.minY + 2, width: 3, height: max(rect.height - 10, 8)), cornerRadius: 1.5).fill()
            case .divider:
                // A line across the column in place of the dashes.
                let dashes = layoutManager.glyphRange(forCharacterRange: NSRange(location: paragraph.location, length: 1), actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: dashes, in: textContainer)
                Theme.dividerNS.resolvedColor(with: traitCollection).setFill()
                UIRectFill(CGRect(x: origin.x + padding, y: origin.y + rect.minY + floor(NoteFormat.bodySize * 0.7), width: textContainer.size.width - 2 * padding, height: 1))
            default:
                break
            }
            // A box in place of a checklist marker: empty for what is to do, filled with the
            // accent color and checked for what is done.
            guard let checked = ListMarker.marker(in: string, paragraph: paragraph)?.checked,
                  let box = checkboxRect(at: paragraph.location)?.offsetBy(dx: origin.x, dy: origin.y)
            else { continue }
            let radius = box.width * 0.28
            if checked {
                accentColor.setFill()
                UIBezierPath(roundedRect: box, cornerRadius: radius).fill()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.53))
                check.addLine(to: CGPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.70))
                check.addLine(to: CGPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.31))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                Theme.onAccentNS.setStroke()
                check.stroke()
            } else {
                let outline = UIBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius)
                outline.lineWidth = 1.5
                secondary.setStroke()
                outline.stroke()
            }
        }
    }
}
