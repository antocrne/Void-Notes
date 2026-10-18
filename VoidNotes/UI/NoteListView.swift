import SwiftUI
import UniformTypeIdentifiers

/// Left of the window, on the chrome: the search field, then the notes of the current space as a
/// tree, then the spaces. "Toutes les notes" and the folders unfold in place (a click): the first
/// shows every note of the space, a folder its subfolders then its notes; only the pinned notes
/// come above the folders. A note, or a folder, is filed by dragging it onto a folder. While searching,
/// the list is flat: what was found, in every folder of the space. Shown or hidden with the
/// toolbar's sidebar button (⌃⌘S).
struct NoteListView: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model

    static let width: CGFloat = 264

    /// "Archives" or "Corbeille", whose notes are hidden while it unfolds or folds.
    @State private var veiled: String?
    /// The pointer is over the list: the chevrons of the folders show.
    @State private var hovering = false

    var body: some View {
        let rows = model.listRows
        // "Archives" and "Corbeille" stand apart from the folders, at the bottom, just above the
        // spaces — at the end of the list when it is taller than the window.
        let apart = rows.firstIndex { $0.id == "archive" || $0.id == "trash" } ?? rows.endIndex
        VStack(spacing: 8) {
            // What makes something new, side by side: a folder, a note.
            HStack(spacing: 2) {
                SearchField()
                    .padding(.trailing, 2)
                ChromeButton(symbol: "folder.badge.plus", help: "Nouveau dossier (⇧⌘N)", size: 12) { model.newFolder() }
                ChromeButton(symbol: "square.and.pencil", help: "Nouvelle note (⌘N)", size: 12) { model.newNote() }
            }
            .padding(.horizontal, 8)
            if rows.isEmpty {
                Text(model.isSearching ? "Aucun résultat" : "Aucune note")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 24)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            VStack(spacing: 2) {
                                LazyVStack(spacing: 2) {
                                    ForEach(rows[..<apart]) { rowView($0) }
                                }
                                Spacer(minLength: 0)
                                LazyVStack(spacing: 2) {
                                    ForEach(rows[apart...]) { row in
                                        rowView(row)
                                            // Unfolding or folding, the notes don't cross the lines that move.
                                            .opacity(veiled != nil && veiled == FoldMotion.group(of: row, in: rows[apart...]) ? 0 : 1)
                                            .modifier(SetApart(active: row.id == rows[apart].id))
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                        }
                        .scrollIndicators(.never)
                    }
                    // Dropped under the list, out of any row: the note leaves its folder.
                    .onDrop(of: [.voidNote], isTargeted: nil) { _ in model.drop(on: nil) }
                    // The note chosen from the keyboard (⌥⌘↑ / ⌥⌘↓) stays in view.
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id.uuidString) }
                    }
                }
            }
            if store.unreadable > 0 {
                Text(store.unreadable == 1 ? "1 fichier illisible a été mis de côté." : "\(store.unreadable) fichiers illisibles ont été mis de côté.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .help("Ils sont dans le sous-dossier « illisibles » du dossier des notes (Réglages → Notes).")
            }
            SpaceBar()
                .padding(.horizontal, 8)
        }
        .padding(.top, 2)
        .frame(width: Self.width)
        .animation(Theme.quick, value: rows.map(\.id))
        .background(SpaceSwipeCatcher { model.stepSpace($0) })
        // Folded or unfolded shows by what is under a folder; the chevrons wait for the pointer.
        .environment(\.showsChevrons, hovering || model.isSearching)
        .onHover { hovering in withAnimation(Theme.quick) { self.hovering = hovering } }
    }

    @ViewBuilder private func rowView(_ row: NotesModel.Row) -> some View {
        switch row {
        case .allNotes:
            AllNotesRow(expanded: model.showsAllNotes)
        case .folder(let folder, let depth):
            FolderRow(folder: folder, depth: depth, expanded: model.expanded.contains(folder.id), selected: model.selection.contains(folder.id))
        case .note(let note, let depth, _):
            NoteRow(note: note, depth: depth, row: row.id, selected: model.isHighlighted(note.id))
        case .archive:
            ArchiveRow(expanded: model.showsArchive) {
                FoldMotion.fold("archive", open: !model.showsArchive, veiled: $veiled) { model.toggleArchive() }
            }
        case .trash:
            TrashRow(expanded: model.showsTrash) {
                FoldMotion.fold("trash", open: !model.showsTrash, veiled: $veiled) { model.toggleTrash() }
            }
        case .trashed(let note):
            TrashedNoteRow(note: note, selected: note.id == model.selectedID)
        }
    }
}

/// Searches the text of the notes, and the names of their folders, as you type. ⌘F puts the
/// cursor here; Escape empties the field and goes back to the note.
private struct SearchField: View {
    @Environment(NotesModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
            // The space's name is under the list (`SpaceBar`): the field says only what it does.
            TextField(model.currentSpace.name, text: $model.query, prompt: Text("Rechercher"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.primaryText)
                .focused($focused)
                .focusEffectDisabled()
                .onExitCommand { model.endSearch() }
                // Return opens the first note found.
                .onSubmit {
                    if let first = model.visibleNotes.first { model.open(first.id) }
                }
                .accessibilityLabel("Rechercher dans les notes")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Effacer la recherche")
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Theme.accent : .clear, lineWidth: 1.5))
        .animation(Theme.quick, value: focused)
        .onChange(of: model.searchFocusRequest) { focused = true }
    }
}

/// First line of the list: unfolded, every note of the space shows under it, most recently
/// modified first, whatever its folder.
private struct AllNotesRow: View {
    let expanded: Bool
    @Environment(NotesModel.self) private var model
    @Environment(\.showsChevrons) private var showsChevrons
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(showsChevrons ? 1 : 0)
            Image(systemName: "tray.full")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
            Text("Toutes les notes")
                .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: FolderRow.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.quick) { model.toggleAllNotes() } }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Toutes les notes")
        .accessibilityValue(expanded ? "Déplié" : "Replié")
        .accessibilityAddTraits(.isButton)
    }
}

/// After the folders and the notes, when notes of the space were archived: unfolded, they show
/// under it, most recently modified first.
private struct ArchiveRow: View {
    let expanded: Bool
    let fold: () -> Void
    @Environment(\.showsChevrons) private var showsChevrons
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(showsChevrons ? 1 : 0)
            Image(systemName: "archivebox")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
            Text("Archives").lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: FolderRow.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: fold)
        .onHover { hovering = $0 }
        .help("Les notes archivées : hors des dossiers, gardées sans limite de temps.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Archives")
        .accessibilityValue(expanded ? "Dépliées" : "Repliées")
        .accessibilityAddTraits(.isButton)
    }
}

/// Last line of the list, when notes were deleted in the space: unfolded, they show under it,
/// most recently deleted first. The menu (right click) empties it.
private struct TrashRow: View {
    let expanded: Bool
    let fold: () -> Void
    @Environment(NotesModel.self) private var model
    @Environment(\.showsChevrons) private var showsChevrons
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(showsChevrons ? 1 : 0)
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
            Text("Corbeille").lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondaryText)
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: FolderRow.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: fold)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Vider la corbeille…", role: .destructive) { model.confirmingEmptyTrash = true }
        }
        .help("Les notes supprimées y restent \(NoteStore.trashDays) jours.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Corbeille")
        .accessibilityValue(expanded ? "Dépliée" : "Repliée")
        .accessibilityAddTraits(.isButton)
    }
}

/// A deleted note, under "Corbeille": its title and the days it has left. A click shows it, read
/// only; the menu (right click) takes it back or deletes it for good.
private struct TrashedNoteRow: View {
    let note: Note
    let selected: Bool
    @Environment(NotesModel.self) private var model
    @Environment(NoteStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(note.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                .lineLimit(1)
            if note.locked { TitleMark(symbol: "lock.fill") }
            Spacer(minLength: 0)
            Text("\(store.daysLeft(note)) j")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.leading, FolderRow.indent(1) + FolderRow.textInset)
        .padding(.trailing, 10)
        .frame(height: FolderRow.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(note.id) }
        .onHover { hovering = $0 }
        .help(NoteDate.trashMeta(daysLeft: store.daysLeft(note)))
        .contextMenu {
            Button("Restaurer") { withAnimation(Theme.quick) { model.restore(note) } }
            Divider()
            Button("Supprimer définitivement…", role: .destructive) { model.pendingDeletion = note }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.title)
        .accessibilityValue("Dans la corbeille, encore \(store.daysLeft(note)) jours")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(note.id) }
    }
}

/// One note of the list, `depth` folders deep: its title and, at the end of the line, the date of
/// its last change — one line, as tall as a folder. The selected one wears the accent color.
/// ⌘-click and ⇧-click select several lines, notes and folders alike.
private struct NoteRow: View {
    let note: Note
    let depth: Int
    /// The line's identity in the list (a note may show twice: under "Toutes les notes" too).
    let row: String
    let selected: Bool
    /// Another note is dragged over this one, on its way to the same folder.
    @State private var targeted = false
    @Environment(NotesModel.self) private var model
    @Environment(NoteStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(note.isBlank ? String(localized: "Nouvelle note") : note.title)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Theme.accent : note.isBlank ? Theme.secondaryText : Theme.primaryText)
                .lineLimit(1)
            if note.pinned { TitleMark(symbol: "pin.fill") }
            if note.locked { TitleMark(symbol: "lock.fill") }
            TagDots(tags: note.tags, size: 7)
            Spacer(minLength: 0)
            Text(NoteDate.label(note.modified))
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .layoutPriority(1)
        }
        // The title starts under the icon of the folder the note is in.
        .padding(.leading, FolderRow.indent(depth) + FolderRow.textInset)
        .padding(.trailing, 10)
        .frame(height: FolderRow.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Theme.accentSoft : hovering || targeted ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            switch SelectionClick.current {
            case .toggle: model.toggleSelection(note.id, row: row)
            case .extend: model.extendSelection(to: row)
            case nil: model.open(note.id)
            }
        }
        // Dropped among the notes of a folder, a note joins them.
        .onDrop(of: [.voidNote], isTargeted: $targeted) { _ in model.drop(on: note.folder) }
        // Dragged onto a folder, the note is filed there.
        .onDrag {
            let id = note.id
            DispatchQueue.main.async { model.beginDrag(id) }
            return UTType.voidNoteProvider(id)
        }
        .onHover { hovering = $0 }
        .help(note.preview)
        .contextMenu {
            if model.isInMultipleSelection(note.id) {
                SelectionMenu()
            } else {
                let folders = store.folderRows(in: model.currentSpaceID)
                Menu("Déplacer vers") {
                    Button("Aucun dossier") { model.move(note.id, to: nil) }
                        .disabled(store.folder(note.folder) == nil)
                    Divider()
                    ForEach(folders, id: \.folder.id) { row in
                        Button(String(repeating: "    ", count: row.depth) + row.folder.name) { model.move(note.id, to: row.folder.id) }
                            .disabled(note.folder == row.folder.id)
                    }
                }
                .disabled(folders.isEmpty || note.isReadOnly)
                if store.spaces.count > 1 {
                    Menu("Déplacer vers l'espace") {
                        ForEach(store.spaces.filter { $0.id != note.space }) { space in
                            Button { withAnimation(Theme.quick) { model.move(note.id, toSpace: space.id) } } label: { Label(space.name, systemImage: OutlineSymbol.name(space.icon)) }
                        }
                    }
                    .disabled(note.isReadOnly)
                }
                Button(model.selection.contains(note.id) ? "Désélectionner" : "Sélectionner") { model.toggleSelection(note.id, row: row) }
                Button(note.pinned ? "Désépingler" : "Épingler") { withAnimation(Theme.quick) { model.setPinned(!note.pinned, for: note.id) } }
                    .disabled(note.isBlank || note.isReadOnly || note.archived)
                if note.archived {
                    Button("Désarchiver") { withAnimation(Theme.quick) { model.unarchive(note.id) } }
                } else {
                    Button("Archiver") { withAnimation(Theme.quick) { model.archive(note.id) } }
                        .disabled(note.isBlank || note.isReadOnly)
                }
                if note.locked {
                    Button("Retirer le verrou…") { model.removeLock(note.id) }
                } else {
                    Button("Verrouiller") { withAnimation(Theme.quick) { model.lock(note.id) } }
                        .disabled(note.isBlank || note.isReadOnly)
                }
                Divider()
                TagPalette(notes: [note])
                Divider()
                Button("Mettre à la corbeille", role: .destructive) { withAnimation(Theme.quick) { model.delete(note) } }
                    .disabled(note.isReadOnly)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.isBlank ? String(localized: "Nouvelle note") : note.title)
        .accessibilityValue([note.pinned ? String(localized: "Épinglée") : nil, note.locked ? String(localized: "Verrouillée") : nil, TagDots.label(note.tags), NoteDate.label(note.modified)].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.open(note.id) }
    }
}

/// A line above the first of "Archives" and "Corbeille": they stand apart from the folders.
private struct SetApart: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(height: 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 7)
                content
            }
        } else {
            content
        }
    }
}

/// After the title of a pinned or a locked note.
private struct TitleMark: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// The chevrons of the list's folders show (the pointer is over the list).
    @Entry var showsChevrons = true
}

extension UTType {
    /// A note dragged in the list (declared in Info.plist). Not text: dropped on the note being
    /// written, it isn't pasted in it; text dragged from another app isn't taken for a note.
    static let voidNote = UTType(exportedAs: "app.void.notes.note")

    /// What a line of the list carries while it is dragged (a folder's too: only this app reads it).
    static func voidNoteProvider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: voidNote.identifier, visibility: .ownProcess) { load in
            load(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

/// What a click on a line of the list means when a modifier key is held.
enum SelectionClick {
    /// ⌘: the line joins or leaves the selection.
    case toggle
    /// ⇧: everything from the last line picked to this one.
    case extend

    /// nil: a plain click.
    @MainActor static var current: SelectionClick? {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        return flags.contains(.command) ? .toggle : flags.contains(.shift) ? .extend : nil
    }
}

/// The menu (right click) of a line that is one of several selected: what it does, it does to
/// all of them.
struct SelectionMenu: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model

    var body: some View {
        let notes = model.selectedNotes
        let folders = store.folderRows(in: model.currentSpaceID)
        Text("\(model.selectionCount) éléments sélectionnés")
        Divider()
        Menu("Déplacer vers") {
            Button("Aucun dossier") { withAnimation(Theme.quick) { model.moveSelection(to: nil) } }
            Divider()
            ForEach(folders, id: \.folder.id) { row in
                Button(String(repeating: "    ", count: row.depth) + row.folder.name) { withAnimation(Theme.quick) { model.moveSelection(to: row.folder.id) } }
                    // A selected folder doesn't go into itself.
                    .disabled(!model.canMoveSelection(to: row.folder.id))
            }
        }
        if store.spaces.count > 1 {
            Menu("Déplacer vers l'espace") {
                ForEach(store.spaces.filter { $0.id != model.currentSpaceID }) { space in
                    Button { withAnimation(Theme.quick) { model.moveSelection(toSpace: space.id) } } label: { Label(space.name, systemImage: OutlineSymbol.name(space.icon)) }
                }
            }
        }
        Button(notes.allSatisfy { $0.pinned || $0.archived } ? "Désépingler" : "Épingler") { withAnimation(Theme.quick) { model.pinSelection() } }
            .disabled(notes.allSatisfy(\.archived))
        Button("Archiver") { withAnimation(Theme.quick) { model.archiveSelection() } }
            .disabled(notes.allSatisfy(\.archived))
        Button("Tout désélectionner") { model.clearSelection() }
        Divider()
        TagPalette(notes: notes)
        Divider()
        Button(model.selectedFolders.isEmpty ? "Mettre à la corbeille" : "Supprimer…", role: .destructive) {
            withAnimation(Theme.quick) { model.askToDeleteSelection() }
        }
    }
}

