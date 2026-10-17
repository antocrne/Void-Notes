import SwiftUI
import UniformTypeIdentifiers

/// The first screen: the notes of the current space as a tree — the same as on the Mac: "Toutes
/// les notes" and the folders unfold in place, the notes in no folder come after them,
/// "Archives" and "Corbeille" stand apart — then the spaces. The search field shows when the
/// magnifier asks for it. A tap on a note opens it; a swipe or a long press does the rest.
struct NotesScreen: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @State private var showsSettings = false
    /// Folder whose icon is being chosen.
    @State private var iconFolder: Folder?
    /// Height the list has for its rows, to keep "Archives" and "Corbeille" at its bottom.
    @State private var listHeight: CGFloat = 0
    /// "Archives" or "Corbeille", whose notes are hidden while it unfolds or folds.
    @State private var veiled: String?
    /// The magnifier was touched: the search field shows (it stays while something is searched).
    @State private var searching = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                if searching || model.isSearching {
                    SearchField { withAnimation(Theme.quick) { searching = false } }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                list
                if store.unreadable > 0 {
                    Text(store.unreadable == 1 ? "1 fichier illisible a été mis de côté." : "\(store.unreadable) fichiers illisibles ont été mis de côté.")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                }
                SpaceBar()
            }
            .background(ChromeBackground().ignoresSafeArea())
            .navigationTitle(model.currentSpace.name)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ChromeNavigationBar(flat: Theme.chrome))
            .toolbar {
                // In the text's color: the accent is for what is chosen, not for the chrome.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .tint(Theme.primaryText)
                        .accessibilityLabel("Réglages")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { withAnimation(Theme.quick) { searching = true } } label: { Image(systemName: "magnifyingglass") }
                        .tint(Theme.primaryText)
                        .accessibilityLabel("Rechercher")
                    Button { model.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                        .tint(Theme.primaryText)
                        .accessibilityLabel("Nouveau dossier")
                    Button { model.newNote(in: nil) } label: { Image(systemName: "square.and.pencil") }
                        .tint(Theme.primaryText)
                        .accessibilityLabel("Nouvelle note")
                }
            }
            .navigationDestination(isPresented: Binding(get: { model.selectedID != nil }, set: { if !$0 { model.select(nil) } })) {
                NoteScreen()
            }
        }
        #if BETA
        // Above the keyboard in a note, above the spaces in the list.
        .safeAreaInset(edge: .bottom, spacing: 0) { ListeningOverlay() }
        .modifier(ListeningAlerts(listener: .shared))
        #endif
        .sheet(isPresented: $showsSettings) { SettingsScreen() }
        // A note just put in the trash: « Annuler » for a few seconds, above the spaces.
        .overlay(alignment: .bottom) {
            if let note = model.lastTrashed, model.selectedID == nil {
                UndoToast(note: note)
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.quick, value: model.lastTrashed?.id)
        .sensoryFeedback(.impact(weight: .light), trigger: model.lastTrashed?.id) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: model.currentSpaceID)
        .sheet(item: $iconFolder) { folder in
            IconSheet(title: folder.name, icons: Folder.icons, selected: store.folder(folder.id)?.icon ?? folder.icon) { store.setIcon($0, for: folder.id) }
        }
        .modifier(FolderNameAlert())
        .confirmationDialog("Supprimer « \(model.pendingDeletion?.title ?? "") » ?", isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("Supprimer définitivement", role: .destructive) {
                if let note = model.pendingDeletion { withAnimation(Theme.quick) { model.delete(note) } }
            }
            Button("Annuler", role: .cancel) { model.pendingDeletion = nil }
        } message: {
            Text("La note et ses pièces jointes sont supprimées définitivement.")
        }
        .confirmationDialog("Vider la corbeille de « \(model.currentSpace.name) » ?", isPresented: $model.confirmingEmptyTrash, titleVisibility: .visible) {
            Button("Vider la corbeille", role: .destructive) { withAnimation(Theme.quick) { model.emptyTrash() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(model.trashedNotes.count == 1 ? "La note qui s'y trouve est supprimée définitivement." : "Les \(model.trashedNotes.count) notes qui s'y trouvent sont supprimées définitivement.")
        }
        .confirmationDialog("Supprimer le dossier « \(model.pendingFolderDeletion?.name ?? "") » ?", isPresented: Binding(get: { model.pendingFolderDeletion != nil }, set: { if !$0 { model.pendingFolderDeletion = nil } }), titleVisibility: .visible) {
            Button("Supprimer le dossier", role: .destructive) {
                if let folder = model.pendingFolderDeletion { withAnimation(Theme.quick) { model.delete(folder) } }
            }
            Button("Annuler", role: .cancel) { model.pendingFolderDeletion = nil }
        } message: {
            Text("Ses sous-dossiers sont supprimés avec lui. Aucune note n'est supprimée : les siennes reviennent dans le dossier au-dessus.")
        }
        .alert("Opération impossible", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder private var list: some View {
        let rows = model.listRows
        // "Archives" and "Corbeille" stand apart from the folders, under a thin line, at the
        // bottom of the list.
        let apart = rows.firstIndex { $0.id == "archive" || $0.id == "trash" }
        // Room above that line that keeps them just above the spaces while the list is shorter
        // than the screen. Every line is as tall: the room is known along with the rows, and
        // changes in the same animation as them.
        let room = apart == nil ? 0 : max(0, listHeight - CGFloat(rows.count) * RowMetrics.height - SeparatorRow.height)
        if rows.isEmpty {
            VStack(spacing: 14) {
                if !model.isSearching { VoidLogo(size: 44).opacity(0.9) }
                Text(model.isSearching ? "Aucun résultat" : "Aucune note")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(rows[..<(apart ?? rows.endIndex)]) { rowView($0) }
                if let apart {
                    SeparatorRow(room: room)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    ForEach(rows[apart...]) { row in
                        rowView(row)
                            // Unfolding or folding, the notes don't cross the lines that move.
                            .opacity(veiled != nil && veiled == FoldMotion.group(of: row, in: rows[apart...]) ? 0 : 1)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Each row sets its own height; the room above the line may be none.
            .environment(\.defaultMinListRowHeight, 0)
            .modifier(ListHeight(height: $listHeight))
            .animation(Theme.quick, value: rows.map(\.id))
        }
    }

    private func rowView(_ row: NotesModel.Row) -> some View {
        Group {
            switch row {
            case .allNotes:
                FoldRow(symbol: "tray.full", name: String(localized: "Toutes les notes"), depth: 0, expanded: model.showsAllNotes) { model.toggleAllNotes() }
            case .folder(let folder, let depth):
                FolderRow(folder: folder, depth: depth, chooseIcon: { iconFolder = folder })
            case .note(let note, let depth, _):
                NoteRow(note: note, depth: depth)
            case .archive:
                FoldRow(symbol: "archivebox", name: String(localized: "Archives"), depth: 0, expanded: model.showsArchive, dimmed: true, animated: false) {
                    FoldMotion.fold("archive", open: !model.showsArchive, veiled: $veiled) { model.toggleArchive() }
                }
            case .trash:
                FoldRow(symbol: "trash", name: String(localized: "Corbeille"), depth: 0, expanded: model.showsTrash, dimmed: true, animated: false) {
                    FoldMotion.fold("trash", open: !model.showsTrash, veiled: $veiled) { model.toggleTrash() }
                }
                .contextMenu {
                    Button("Vider la corbeille…", systemImage: "xmark.bin", role: .destructive) { model.confirmingEmptyTrash = true }
                }
            case .trashed(let note):
                TrashedNoteRow(note: note)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// The measures of the list, which grow with the text size chosen in iOS (Dynamic Type).
enum RowMetrics {
    private static func scaled(_ value: CGFloat) -> CGFloat { UIFontMetrics(forTextStyle: .callout).scaledValue(for: value) }
    /// A line of the list: as tall as a finger needs.
    static var height: CGFloat { scaled(44) }
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * scaled(18) }
    /// Where a note's title starts: under the icon of the folder it is in.
    static var textInset: CGFloat { 8 + chevronWidth + 6 }
    static var chevronWidth: CGFloat { scaled(12) }
    static var iconWidth: CGFloat { scaled(24) }
}

/// « Annuler », a few seconds after a note went to the trash.
private struct UndoToast: View {
    let note: Note
    @Environment(NotesModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text("Mise à la corbeille")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
            Button("Annuler") { withAnimation(Theme.quick) { model.undoLastTrash() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .modifier(ToastBackground())
        .task(id: note.id) {
            try? await Task.sleep(for: .seconds(6))
            withAnimation(Theme.quick) { model.forgetLastTrash(note) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Annuler") { model.undoLastTrash() }
    }
}

/// The navigation bar in the flat color of what is under it; over a gradient, which a flat bar
/// would cut, none: iOS 26 blurs what scrolls under it, earlier versions get a thin material.
struct ChromeNavigationBar: ViewModifier {
    let flat: Color
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        if settings.chromeLook.gradient && settings.chromeTint != .none {
            if #available(iOS 26.0, *) {
                content.toolbarBackground(.hidden, for: .navigationBar)
            } else {
                content.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            }
        } else {
            content.toolbarBackground(flat, for: .navigationBar)
        }
    }
}

private struct ToastBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(.regularMaterial)).overlay(Capsule().strokeBorder(Theme.stroke))
        }
    }
}

/// A thin line above "Archives" and "Corbeille", and the room above it that pushes them down.
private struct SeparatorRow: View {
    let room: CGFloat

    /// The line and the space around it.
    static let height: CGFloat = 17

    var body: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(height: room + Self.height, alignment: .bottom)
            .accessibilityHidden(true)
    }
}

/// Measures the height the list shows its rows in. Before iOS 18, it stays 0: "Archives" and
/// "Corbeille" follow the folders.
private struct ListHeight: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            } action: { _, new in
                height = new
            }
        } else {
            content
        }
    }
}

/// Searches the text of the notes of the space, and the names of their folders, as you type.
/// It takes the keyboard when it shows; « Annuler », or leaving it empty, puts it away.
private struct SearchField: View {
    let end: () -> Void
    @Environment(NotesModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 12) {
            field
            Button("Annuler") {
                model.query = ""
                end()
            }
            .font(.callout)
            .foregroundStyle(Theme.accent)
        }
        .onAppear { focused = true }
        .onChange(of: focused) { _, focused in
            if !focused, model.query.isEmpty { end() }
        }
    }

    private var field: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
            TextField("Rechercher dans \(model.currentSpace.name)", text: $model.query)
                .font(.callout)
                .foregroundStyle(Theme.primaryText)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityLabel("Rechercher dans les notes")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.hover))
    }
}

/// A line that unfolds in place: "Toutes les notes", "Archives", "Corbeille".
private struct FoldRow: View {
    let symbol: String
    let name: String
    let depth: Int
    let expanded: Bool
    var dimmed = false
    /// false: the action animates by itself.
    var animated = true
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { if animated { withAnimation(Theme.quick) { action() } } else { action() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: RowMetrics.chevronWidth)
                Image(systemName: symbol)
                    .font(.subheadline.weight(.medium))
                    .frame(width: RowMetrics.iconWidth)
                Text(name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(dimmed ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, 6 + RowMetrics.indent(depth))
            .frame(height: RowMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Déplié" : "Replié")
    }
}

/// A folder: a tap unfolds it, a long press makes a note or a subfolder in it, renames it,
/// changes its icon, files it in another folder, sends it to another space or deletes it.
private struct FolderRow: View {
    let folder: Folder
    let depth: Int
    let chooseIcon: () -> Void
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model

    var body: some View {
        FoldRow(symbol: OutlineSymbol.name(folder.icon), name: folder.name, depth: depth, expanded: model.expanded.contains(folder.id)) { model.toggle(folder.id) }
            .contextMenu {
                Button("Nouvelle note", systemImage: "square.and.pencil") { model.newNote(in: folder.id) }
                Button("Nouveau sous-dossier", systemImage: "folder.badge.plus") { model.newFolder(in: folder.id) }
                Divider()
                Button("Renommer", systemImage: "pencil") { model.renamingFolderID = folder.id }
                Button("Changer l'icône", systemImage: "face.smiling", action: chooseIcon)
                let destinations = model.destinations(for: folder)
                if folder.parent != nil || !destinations.isEmpty {
                    Menu("Déplacer vers", systemImage: "folder") {
                        if folder.parent != nil {
                            Button("Aucun dossier", systemImage: "tray") { withAnimation(Theme.quick) { model.moveFolder(folder.id, to: nil) } }
                        }
                        ForEach(destinations, id: \.folder.id) { row in
                            Button(String(repeating: "    ", count: row.depth) + row.folder.name, systemImage: OutlineSymbol.name(row.folder.icon)) {
                                withAnimation(Theme.quick) { model.moveFolder(folder.id, to: row.folder.id) }
                            }
                            .disabled(row.folder.id == folder.parent)
                        }
                    }
                }
                if store.spaces.count > 1 {
                    Menu("Déplacer vers l'espace", systemImage: "arrow.right.square") {
                        ForEach(store.spaces.filter { $0.id != folder.space }) { space in
                            Button(space.name, systemImage: OutlineSymbol.name(space.icon)) { withAnimation(Theme.quick) { model.move(folder, toSpace: space.id) } }
                        }
                    }
                }
                Divider()
                Button("Supprimer le dossier…", systemImage: "trash", role: .destructive) { model.pendingFolderDeletion = folder }
            }
    }
}

/// One note of the list, `depth` folders deep: its title and, at the end of the line, the date
/// of its last change. A swipe archives it or puts it in the trash, one the other way pins it;
/// a long press files it.
private struct NoteRow: View {
    let note: Note
    let depth: Int
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { model.open(note.id) } label: {
            HStack(spacing: 8) {
                Text(note.isBlank ? String(localized: "Nouvelle note") : note.title)
                    .font(.callout)
                    .foregroundStyle(note.isBlank ? Theme.secondaryText : Theme.primaryText)
                    .lineLimit(1)
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.secondaryText).accessibilityLabel("Épinglée")
                }
                if note.locked {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.secondaryText).accessibilityLabel("Verrouillée")
                }
                Spacer(minLength: 0)
                Text(NoteDate.label(note.modified))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.leading, RowMetrics.indent(depth) + RowMetrics.textInset)
            .padding(.trailing, 6)
            .frame(height: RowMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if !note.isReadOnly {
                // In red: what is put away isn't what is filed.
                Button(role: .destructive) { withAnimation(Theme.quick) { model.delete(note) } } label: { Label("Corbeille", systemImage: "trash") }
                    .tint(Theme.dangerFill)
            }
            Button { withAnimation(Theme.quick) { toggleArchived() } } label: {
                Label(note.archived ? "Désarchiver" : "Archiver", systemImage: note.archived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(Theme.accentDeepFill)
        }
        .swipeActions(edge: .leading) {
            if !note.archived && !note.isBlank {
                Button { withAnimation(Theme.quick) { model.setPinned(!note.pinned, for: note.id) } } label: {
                    Label(note.pinned ? "Désépingler" : "Épingler", systemImage: note.pinned ? "pin.slash" : "pin")
                }
                .tint(Theme.accentDeepFill)
            }
        }
        .contextMenu { NoteMenu(note: note) }
    }

    private func toggleArchived() {
        if note.archived { model.unarchive(note.id) } else { model.archive(note.id) }
    }
}

/// What can be done with a note, from the list (a long press) or from the note itself.
struct NoteMenu: View {
    let note: Note
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model

    var body: some View {
        let folders = store.folderRows(in: note.space)
        if !folders.isEmpty {
            Menu("Déplacer vers", systemImage: "folder") {
                if note.folder != nil {
                    Button("Aucun dossier", systemImage: "tray") { withAnimation(Theme.quick) { model.move(note.id, to: nil) } }
                }
                ForEach(folders, id: \.folder.id) { row in
                    Button(String(repeating: "    ", count: row.depth) + row.folder.name, systemImage: OutlineSymbol.name(row.folder.icon)) {
                        withAnimation(Theme.quick) { model.move(note.id, to: row.folder.id) }
                    }
                    .disabled(row.folder.id == note.folder)
                }
            }
        }
        if store.spaces.count > 1 {
            Menu("Déplacer vers l'espace", systemImage: "arrow.right.square") {
                ForEach(store.spaces.filter { $0.id != note.space }) { space in
                    Button(space.name, systemImage: OutlineSymbol.name(space.icon)) { withAnimation(Theme.quick) { model.move(note.id, toSpace: space.id) } }
                }
            }
        }
        Divider()
        if !note.archived {
            Button(note.pinned ? "Désépingler" : "Épingler", systemImage: note.pinned ? "pin.slash" : "pin") {
                withAnimation(Theme.quick) { model.setPinned(!note.pinned, for: note.id) }
            }
        }
        if note.archived {
            Button("Désarchiver", systemImage: "tray.and.arrow.up") { withAnimation(Theme.quick) { model.unarchive(note.id) } }
        } else {
            Button("Archiver", systemImage: "archivebox") { withAnimation(Theme.quick) { model.archive(note.id) } }
        }
        if note.locked {
            Button("Retirer le verrou", systemImage: "lock.open") { model.removeLock(note.id) }
        } else {
            Button("Verrouiller", systemImage: "lock") { model.lock(note.id) }
        }
        if !note.isBlank && !model.isConcealed(note) {
            ShareLink(item: MarkdownFile(note: note), preview: SharePreview(note.title)) {
                Label("Exporter en Markdown", systemImage: "square.and.arrow.up")
            }
        }
        Divider()
        Button("Mettre à la corbeille", systemImage: "trash", role: .destructive) { withAnimation(Theme.quick) { model.delete(note) } }
            .tint(Theme.danger)
            .disabled(note.isReadOnly)
    }
}

/// A note as a `.md` file, to share or to save in Fichiers. Its images and files are named in
/// it, not sent with it.
struct MarkdownFile: Transferable {
    let note: Note

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { file in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(NoteMarkdown.fileName(for: file.note)).appendingPathExtension("md")
            try Data(NoteMarkdown.markdown(from: file.note.content, photos: file.note.photos).utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}

/// A deleted note, under "Corbeille": its title and the days it has left. A tap shows it, read
/// only; a swipe takes it back or deletes it for good.
private struct TrashedNoteRow: View {
    let note: Note
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button { model.select(note.id) } label: {
            HStack(spacing: 8) {
                Text(note.title)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(store.daysLeft(note)) j")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.leading, RowMetrics.indent(1) + RowMetrics.textInset)
            .padding(.trailing, 6)
            .frame(height: RowMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue("Dans la corbeille, encore \(store.daysLeft(note)) jours")
        .swipeActions(edge: .trailing) {
            Button { model.pendingDeletion = note } label: { Label("Supprimer", systemImage: "xmark.bin") }
                .tint(Theme.dangerFill)
            Button { withAnimation(Theme.quick) { restore() } } label: { Label("Restaurer", systemImage: "arrow.uturn.backward") }
                .tint(Theme.accentDeepFill)
        }
        .contextMenu {
            Button("Restaurer", systemImage: "arrow.uturn.backward") { withAnimation(Theme.quick) { restore() } }
            Divider()
            Button("Supprimer définitivement…", systemImage: "xmark.bin", role: .destructive) { model.pendingDeletion = note }
                .tint(Theme.danger)
        }
    }

    /// Back where it was, in the list: the note isn't opened.
    private func restore() {
        model.restore(note)
        model.select(nil)
    }
}

/// The name of a folder: asked when it is made, and to rename it.
private struct FolderNameAlert: ViewModifier {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Nom du dossier", isPresented: Binding(get: { model.renamingFolderID != nil }, set: { if !$0 { model.renamingFolderID = nil } })) {
                TextField(Folder.defaultName, text: $name)
                Button("OK") {
                    if let id = model.renamingFolderID { store.renameFolder(id, to: name) }
                    model.renamingFolderID = nil
                }
                Button("Annuler", role: .cancel) { model.renamingFolderID = nil }
            }
            .onChange(of: model.renamingFolderID) { _, id in
                let current = store.folder(id)?.name ?? ""
                // A folder just made is named from scratch.
                name = current == Folder.defaultName ? "" : current
            }
    }
}

/// Bottom of the list, as in Void: one icon per space — a tap shows the space, a long press
/// renames it, changes its icon or deletes it — then a small « + » for a new space.
private struct SpaceBar: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @State private var creating = false
    @State private var edited: Space?
    @State private var deleted: Space?

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(store.spaces) { space in
                        let selected = space.id == model.currentSpaceID
                        Button { withAnimation(Theme.quick) { model.switchSpace(to: space.id) } } label: {
                            Image(systemName: OutlineSymbol.name(space.icon))
                                .symbolVariant(selected ? .fill : .none)
                                .font(.body.weight(.medium))
                                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                                .frame(width: 44, height: 40)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(space.name)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .contextMenu {
                            Button("Renommer, changer l'icône…", systemImage: "pencil") { edited = space }
                            Divider()
                            Button("Supprimer l'espace…", systemImage: "trash", role: .destructive) { deleted = space }
                                .disabled(store.spaces.count < 2)
                        }
                    }
                    // A new space: with the spaces, small.
                    Button { creating = true } label: {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 36, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Nouvel espace")
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
        .sheet(isPresented: $creating) {
            SpaceForm(title: "Nouvel espace", name: "", icon: "circle", confirm: "Créer") { name, icon in
                withAnimation(Theme.quick) { model.newSpace(named: name, icon: icon) }
            }
        }
        .sheet(item: $edited) { space in
            SpaceForm(title: "Espace", name: space.name, icon: space.icon, confirm: "OK") { name, icon in
                store.renameSpace(space.id, to: name)
                store.setIcon(icon, forSpace: space.id)
            }
        }
        .confirmationDialog("Supprimer l'espace « \(deleted?.name ?? "") » ?", isPresented: Binding(get: { deleted != nil }, set: { if !$0 { deleted = nil } }), titleVisibility: .visible) {
            Button("Supprimer l'espace", role: .destructive) {
                if let deleted { withAnimation(Theme.quick) { model.delete(deleted) } }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Aucune note n'est supprimée : ses dossiers et ses notes vont dans l'espace « \(store.spaces.first { $0.id != deleted?.id }?.name ?? "") ».")
        }
    }
}

/// Name and icon of a space: to make one, or to change one.
private struct SpaceForm: View {
    let title: LocalizedStringKey
    @State var name: String
    @State var icon: String
    let confirm: LocalizedStringKey
    let done: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Nom de l'espace", text: $name)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover))
                    .focused($focused)
                IconGrid(icons: Space.icons.contains(icon) ? Space.icons : Space.icons + [icon], selected: $icon)
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.chrome)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
                        done(name, icon)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = name.isEmpty }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium])
    }
}

/// The icons offered for a folder or a space; the one chosen wears the accent color.
struct IconGrid: View {
    let icons: [String]
    @Binding var selected: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(icons, id: \.self) { icon in
                Button { selected = icon } label: {
                    Image(systemName: OutlineSymbol.name(icon))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(icon == selected ? Theme.accent : Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(icon == selected ? Theme.accentSoft : Theme.hover))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(icon)
                .accessibilityAddTraits(icon == selected ? .isSelected : [])
            }
        }
    }
}

/// The icon of a folder: a tap chooses it and closes the sheet.
private struct IconSheet: View {
    let title: String
    let icons: [String]
    @State var selected: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                IconGrid(icons: icons, selected: $selected).padding(20)
            }
            .background(Theme.chrome)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            .onChange(of: selected) { _, icon in
                choose(icon)
                dismiss()
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium])
    }
}
