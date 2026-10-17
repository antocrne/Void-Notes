import SwiftUI

/// Menu bar: notes, search, and the Format menu — the same formatting as the marks typed in the
/// text, for a selection or for those who prefer a shortcut.
struct NotesCommands: Commands {
    let model: NotesModel
    let settings: AppSettings
    let store: NoteStore

    /// The note's text, when it has the keyboard.
    private var editor: NoteTextView? { NSApp.keyWindow?.firstResponder as? NoteTextView }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouvelle note") { model.newNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Nouveau dossier") { model.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Ajouter des images…") { editor?.choosePhotos() }
                .disabled(model.selected == nil || model.selected?.isReadOnly == true || model.selected?.deleted != nil)
            Button("Joindre un fichier…") { editor?.chooseAttachments() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.selected == nil || model.selected?.isReadOnly == true || model.selected?.deleted != nil)
            #if BETA
            // At once, in the language and to the source of last time (the note's button offers them).
            Button(Listener.shared.isListening ? "Arrêter l'écoute" : "Écouter et transcrire") { Listener.shared.toggle(in: model.selectedID) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!Listener.shared.isListening && (Listener.shared.isActive || !Listener.shared.canListen(in: model.selected) || model.selected.map { model.isConcealed($0) } == true))
            #endif
            Divider()
            Button(model.selected.map { model.isConcealed($0) } == true ? "Déverrouiller la note…" : model.selected?.locked == true ? "Verrouiller maintenant" : "Verrouiller la note") {
                withAnimation(Theme.quick) { model.toggleLock() }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model.selected == nil || model.selected?.isBlank == true || model.selected?.isReadOnly == true
                      || (model.selected?.deleted != nil && model.selected?.locked != true))
            Button(model.selectionCount > 1 ? "Archiver la sélection" : model.selected?.archived == true ? "Désarchiver la note" : "Archiver la note") {
                withAnimation(Theme.quick) { model.toggleArchived() }
            }
            .keyboardShortcut("a", modifiers: [.command, .control])
            .disabled(model.selectionCount < 2 && (model.selected == nil || model.selected?.isBlank == true || model.selected?.isReadOnly == true || model.selected?.deleted != nil))
            Button(model.selectionCount > 1 ? "Épingler la sélection" : model.selected?.pinned == true ? "Désépingler la note" : "Épingler la note") {
                withAnimation(Theme.quick) { model.togglePinned() }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(model.selectionCount < 2 && (model.selected == nil || model.selected?.isBlank == true || model.selected?.isReadOnly == true
                      || model.selected?.deleted != nil || model.selected?.archived == true))
            Button("Retirer le verrou…") {
                if let id = model.selectedID { model.removeLock(id) }
            }
            .disabled(model.selected?.locked != true || model.selected?.deleted != nil)
            Divider()
            Button("Exporter en Markdown…") {
                if let note = model.selected { ExportPanels.export(note, store: store) }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(model.selected == nil || model.selected?.isBlank == true || model.selected.map { model.isConcealed($0) } == true)
            Button("Exporter toutes les notes…") { ExportPanels.exportAll(store: store) }
            Divider()
            // Several lines picked in the list: the command is for all of them.
            Button(model.selectionCount > 1 ? "Supprimer la sélection" : model.selected?.deleted == nil ? "Supprimer la note" : "Supprimer définitivement…") {
                if model.selectionCount > 1 { model.askToDeleteSelection() } else { model.askToDeleteSelected() }
            }
            // Not ⌘⌫ alone: in the text it deletes to the start of the line.
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(model.selectionCount < 2 && (model.selected == nil || (model.selected?.isReadOnly == true && model.selected?.deleted == nil)))
        }
        CommandGroup(replacing: .printItem) {
            Button("Imprimer…") {
                if let note = model.selected { editor?.printNote(title: note.title) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model.selected == nil || model.selected?.isBlank == true || model.selected.map { model.isConcealed($0) } == true)
        }
        CommandGroup(after: .textEditing) {
            Button("Rechercher dans les notes") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(before: .sidebar) {
            Button(settings.showsSidebar ? "Masquer la liste des notes" : "Afficher la liste des notes") {
                withAnimation(Theme.spring) { settings.showsSidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Note précédente") { model.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Note suivante") { model.step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Format") {
            Button("Gras") { editor?.toggleBold() }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italique") { editor?.toggleItalic() }
                .keyboardShortcut("i", modifiers: .command)
            Button("Surligner") { editor?.toggleHighlight() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Barré") { editor?.toggleStrike() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Code") { editor?.toggleCode() }
            Button("Lien…") { model.linkRequest += 1 }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.selected == nil || model.selected?.isReadOnly == true || model.selected?.deleted != nil)
            Button("Retirer le lien") { editor?.setLink(nil) }
            Menu("Graisse") {
                ForEach(WeightChoice.all) { choice in
                    Button(choice.label) { editor?.setWeight(choice.weight) }
                }
            }
            Divider()
            Button("Titre") { editor?.setBlock(.title) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Sous-titre") { editor?.setBlock(.heading) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Intertitre") { editor?.setBlock(.subheading) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Texte") { editor?.setBlock(nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button("Liste à cocher") { editor?.toggleList(.checklist) }
                .keyboardShortcut("6", modifiers: [.command, .option])
            Button("Cocher ou décocher") { editor?.toggleChecked() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Liste à puces") { editor?.toggleList(.bullet) }
                .keyboardShortcut("7", modifiers: [.command, .option])
            Button("Liste numérotée") { editor?.toggleList(.numbered) }
                .keyboardShortcut("8", modifiers: [.command, .option])
            Button("Augmenter le retrait") { editor?.changeIndent(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Diminuer le retrait") { editor?.changeIndent(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Citation") { editor.map { $0.setBlock($0.currentBlock == .quote ? nil : .quote) } }
                .keyboardShortcut("9", modifiers: [.command, .option])
            Button("Séparateur") { editor?.insertDivider() }
        }
        CommandGroup(replacing: .help) {}
    }
}
