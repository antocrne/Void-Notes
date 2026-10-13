import Observation
import SwiftUI
import UIKit

/// Between the bar above the keyboard (SwiftUI) and the note's text view (UIKit). `format`
/// follows the cursor, so the bar shows what is on.
@MainActor @Observable
final class NoteEditorController {
    struct Format: Equatable {
        var block: NoteBlock?
        var bold = false
        var italic = false
        var highlight = false
        var strike = false
        var code = false
        var list: ListMarker.Kind?
        var indent = 0
        var link = false
    }

    private(set) var format = Format()
    private(set) var hasKeyboard = false
    /// The link of the selection is being written (an alert asks for its address).
    var askingLink = false
    var linkDraft = ""
    @ObservationIgnored weak var textView: NoteUITextView?

    func refresh() {
        guard let textView else { return }
        let updated = Format(block: textView.currentBlock, bold: textView.isBold, italic: textView.isItalic, highlight: textView.isHighlighted,
                             strike: textView.isStruck, code: textView.isCode, list: textView.currentList, indent: textView.currentIndent,
                             link: textView.currentLink != nil)
        if updated != format { format = updated }
        if hasKeyboard != textView.isFirstResponder { hasKeyboard = textView.isFirstResponder }
    }

    func focus() { textView?.becomeFirstResponder() }

    /// Asks for the address of the selection's link (the one already there, if any).
    func askLink() {
        let link = textView?.currentLink ?? ""
        linkDraft = link.hasPrefix("mailto:") ? String(link.dropFirst(7)) : link
        askingLink = true
    }

    /// The address typed: false if it isn't one.
    @discardableResult
    func applyLink() -> Bool {
        guard let url = NoteFormat.linkURL(from: linkDraft) else { return false }
        textView?.setLink(url)
        refresh()
        return true
    }

    func removeLink() {
        textView?.setLink(nil)
        refresh()
    }
    func hideKeyboard() { textView?.resignFirstResponder() }
}

/// The note's text on iPhone. One editor per note (the caller gives it the note's `id`); the
/// text view owns the text while it's shown, and every change goes to `onChange` to be saved.
struct NoteTextEditor: UIViewRepresentable {
    let note: Note
    let accent: AccentChoice
    /// Réglages: misspelled words underlined (by iOS, in red).
    var checksSpelling = true
    /// The search of the list: what it found shows in the note.
    var searchQuery = ""
    let controller: NoteEditorController
    /// Keeps the files joined to the note.
    let store: NoteStore
    let onOpenFile: (URL) -> Void
    /// true: something is typed, the buttons over the note fade; false: it's scrolled or touched.
    var onWriting: (Bool) -> Void = { _ in }
    let onChange: (NoteContent) -> Void

    func makeUIView(context: Context) -> NoteUITextView {
        let textView = NoteUITextView.make()
        // A note of the trash is read, not written.
        textView.isEditable = !note.isReadOnly && note.deleted == nil
        let id = note.id
        textView.attachmentsDirectory = store.attachmentsDirectory(of: id)
        textView.addPhotoData = { [store] in store.addPhoto($0, named: $1, to: id) }
        textView.load(note.content)
        if note.deleted != nil { textView.dimText() }
        textView.onTyping = { [onWriting] in onWriting(true) }
        textView.onTouch = { [onWriting] in onWriting(false) }
        textView.searchWords = Self.words(searchQuery)
        textView.onOpenFile = onOpenFile
        controller.textView = textView
        textView.onSelectionChange = { [controller] in controller.refresh() }

        let album = UIHostingController(rootView: NotePhotoAlbumSection(noteID: id, store: store))
        album.view.backgroundColor = .clear
        album.safeAreaRegions = []
        textView.album = album.view
        context.coordinator.album = album

        let bar = UIHostingController(rootView: FormatBar(controller: controller))
        bar.safeAreaRegions = []
        // The note's own surface behind the pill: the bar sits on the page, with no dark band
        // between the text and the keyboard.
        bar.view.backgroundColor = Theme.surfaceNS
        bar.view.frame = CGRect(x: 0, y: 0, width: 320, height: FormatBar.height)
        bar.view.autoresizingMask = [.flexibleWidth]
        textView.inputAccessoryView = bar.view
        context.coordinator.bar = bar

        // A note just made takes the keyboard; one that is read doesn't.
        if note.isBlank, textView.isEditable {
            DispatchQueue.main.async { [weak textView] in textView?.becomeFirstResponder() }
        }
        return textView
    }

    func updateUIView(_ textView: NoteUITextView, context: Context) {
        if textView.accent != accent { textView.accent = accent }
        let words = Self.words(searchQuery)
        if textView.searchWords != words { textView.searchWords = words }
        let spelling: UITextSpellCheckingType = checksSpelling ? .yes : .no
        if textView.spellCheckingType != spelling { textView.spellCheckingType = spelling }
        textView.albumHeight = note.photos.isEmpty ? 0 : NotePhotoAlbumSection.height
        textView.meta = note.deleted == nil ? (note.archived ? "Archivée  ·  " : "") + NoteDate.meta(created: note.created, modified: note.modified)
            : NoteDate.trashMeta(daysLeft: store.daysLeft(note))
        textView.onChange = { [weak textView] in
            if let textView { onChange(textView.content) }
        }
        textView.onOpenFile = onOpenFile
    }

    static func words(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var album: UIViewController?
        var bar: UIViewController?
    }
}

/// Above the keyboard, floating as a pill of glass: what is used most, always in view — the
/// paragraph menu « Aa », the three lists, bold, italic, highlighting — and the key that puts the
/// keyboard away. The rest is in « Aa »: the kind of paragraph, struck through, code, a link, the
/// quote, the divider and, in a list, its indentation — what the Mac has in its "Aa" panel.
/// No color to choose.
struct FormatBar: View {
    let controller: NoteEditorController

    static let height: CGFloat = 56

    var body: some View {
        let format = controller.format
        HStack(spacing: 0) {
            Menu {
                Picker("Style", selection: Binding(get: { style(format.block) }, set: { controller.textView?.setBlock($0.block) })) {
                    ForEach(Style.allCases) { Text($0.label).tag($0) }
                }
                Section {
                    toggle("Barré", "strikethrough", on: format.strike) { $0.toggleStrike() }
                    toggle("Code", "chevron.left.forwardslash.chevron.right", on: format.code) { $0.toggleCode() }
                    Button(format.link ? "Modifier le lien…" : "Lien…", systemImage: "link") { controller.askLink() }
                }
                Section {
                    toggle("Citation", "text.quote", on: format.block == .quote) { $0.setBlock($0.currentBlock == .quote ? nil : .quote) }
                    Button("Séparateur", systemImage: "minus") { act { $0.insertDivider() } }
                }
                if format.list != nil {
                    Section("Retrait") {
                        Button("Augmenter le retrait", systemImage: "increase.indent") { act { $0.changeIndent(by: 1) } }
                            .disabled(format.indent >= NoteFormat.maxIndent)
                        Button("Diminuer le retrait", systemImage: "decrease.indent") { act { $0.changeIndent(by: -1) } }
                            .disabled(format.indent == 0)
                    }
                }
            } label: {
                key("textformat.size", on: format.block != nil || format.strike || format.code || format.link)
            }
            .accessibilityLabel("Mise en forme")
            separator
            button("checklist", "Liste à cocher", on: format.list == .checklist) { $0.toggleList(.checklist) }
            button("list.bullet", "Liste à puces", on: format.list == .bullet) { $0.toggleList(.bullet) }
            button("list.number", "Liste numérotée", on: format.list == .numbered) { $0.toggleList(.numbered) }
            separator
            button("bold", "Gras", on: format.bold) { $0.toggleBold() }
            button("italic", "Italique", on: format.italic) { $0.toggleItalic() }
            button("highlighter", "Surligner", on: format.highlight) { $0.toggleHighlight() }
            Spacer(minLength: 0)
            Button { controller.hideKeyboard() } label: { key("keyboard.chevron.compact.down", on: false) }
                .accessibilityLabel("Masquer le clavier")
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .modifier(GlassPill())
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height, alignment: .top)
        .background(Theme.surface)
        .tint(Theme.accent)
    }

    private func act(_ action: (NoteUITextView) -> Void) {
        if let textView = controller.textView { action(textView) }
        controller.refresh()
    }

    private func toggle(_ label: String, _ symbol: String, on: Bool, action: @escaping (NoteUITextView) -> Void) -> some View {
        Button { act(action) } label: {
            Label(label, systemImage: on ? "checkmark" : symbol)
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private func button(_ symbol: String, _ label: String, on: Bool, action: @escaping (NoteUITextView) -> Void) -> some View {
        Button {
            if let textView = controller.textView { action(textView) }
            controller.refresh()
        } label: { key(symbol, on: on) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func key(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(on ? Theme.accent : Theme.primaryText)
            .frame(width: 40, height: 38)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.accentSoft : .clear))
            .contentShape(Rectangle())
    }

    /// The kinds of paragraph the menu offers.
    private enum Style: String, CaseIterable, Identifiable {
        case title, heading, subheading, body
        var id: String { rawValue }

        var label: String {
            switch self {
            case .title: "Titre"
            case .heading: "Sous-titre"
            case .subheading: "Intertitre"
            case .body: "Texte"
            }
        }

        var block: NoteBlock? {
            switch self {
            case .title: .title
            case .heading: .heading
            case .subheading: .subheading
            case .body: nil
            }
        }
    }

    private func style(_ block: NoteBlock?) -> Style {
        switch block {
        case .title: .title
        case .heading: .heading
        case .subheading: .subheading
        default: .body
        }
    }
}

/// Liquid Glass, where iOS has it (26 and later); before, the chrome's own material.
private struct GlassPill: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Theme.stroke))
        }
    }
}
