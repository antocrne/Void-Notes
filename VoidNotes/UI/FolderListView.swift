import SwiftUI
import UniformTypeIdentifiers

/// One folder of the list. A click unfolds it in place: its subfolders, then its notes, show
/// under it, one step to the right. A note or a folder dragged from the list is dropped on the
/// folder it goes to — the folder itself can be dragged into another one; the menu (right click)
/// renames the folder, changes its icon, adds a note or a subfolder, moves it, or deletes it.
struct FolderRow: View {
    let folder: Folder
    let depth: Int
    let expanded: Bool
    /// Picked with other lines (⌘-click, ⇧-click).
    var selected = false
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @Environment(\.showsChevrons) private var showsChevrons
    @State private var hovering = false
    /// A dragged note or folder is over the row.
    @State private var targeted = false
    @State private var pickingIcon = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    static let rowHeight: CGFloat = 28

    /// Left margin of what is `depth` folders deep.
    static func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 14 }
    /// From the left of a row to its icon's glyph, past the chevron: where a note's title starts.
    static let textInset: CGFloat = 23

    private var renaming: Bool { model.renamingFolderID == folder.id }
    /// What is dragged over the row can go in it (a folder never goes into itself).
    private var accepting: Bool { targeted && model.canDrop(on: folder.id) }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
                .opacity(showsChevrons ? 1 : 0)
            icon
            if renaming {
                TextField("Nom du dossier", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .focusEffectDisabled()
                    .onSubmit { commit() }
                    .onExitCommand { model.renamingFolderID = nil }
            } else {
                Text(folder.name).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // A folder holds the notes: it steps back, they lead.
        .font(.system(size: 13))
        .foregroundStyle(hovering || renaming ? Theme.primaryText : Theme.secondaryText)
        .padding(.leading, Self.indent(depth) + 6)
        .padding(.trailing, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accepting || selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(accepting ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !renaming else { return }
            switch SelectionClick.current {
            case .toggle: model.toggleSelection(folder.id, row: folder.id.uuidString)
            case .extend: model.extendSelection(to: folder.id.uuidString)
            case nil: withAnimation(Theme.quick) { model.toggle(folder.id) }
            }
        }
        .onDrop(of: [.voidNote], isTargeted: $targeted) { _ in model.drop(on: folder.id) }
        // Dragged onto another folder, the folder is filed there; under the list, at the top.
        .onDrag {
            let id = folder.id
            DispatchQueue.main.async { model.beginDrag(folder: id) }
            return UTType.voidNoteProvider(id)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if model.isInMultipleSelection(folder.id) { SelectionMenu() } else { menu }
        }
        .onChange(of: renaming, initial: true) { _, renaming in
            guard renaming else { return }
            name = folder.name
            nameFocused = true
        }
        // A click elsewhere keeps what was typed.
        .onChange(of: nameFocused) { _, focused in
            if !focused, renaming { commit() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(folder.name)
        .accessibilityValue(expanded ? "Déplié" : "Replié")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        #if DEBUG
        // `-showIcons YES`: the icon picker of the first folder, for the snapshots.
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "showIcons"), folder.id == store.folderRows(in: model.currentSpaceID).first?.folder.id else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pickingIcon = true }
        }
        #endif
    }

    /// The folder's icon. While the name is being typed it is a button: the icon is chosen along
    /// with the name.
    private var icon: some View {
        Button { pickingIcon = true } label: {
            Image(systemName: OutlineSymbol.name(folder.icon))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(renaming ? Theme.accentSoft : .clear))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(renaming)
        .help("Changer l'icône")
        .popover(isPresented: $pickingIcon, arrowEdge: .trailing) {
            IconPicker(selected: folder.icon) { icon in
                store.setIcon(icon, for: folder.id)
                pickingIcon = false
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Nouvelle note") { model.newNote(in: folder.id) }
        Button("Nouveau sous-dossier") { model.newFolder(in: folder.id) }
        Divider()
        Button("Renommer") { model.renamingFolderID = folder.id }
        Button("Changer l'icône…") { pickingIcon = true }
        Menu("Déplacer vers") {
            Button("Aucun dossier") { withAnimation(Theme.quick) { model.moveFolder(folder.id, to: nil) } }
                .disabled(folder.parent == nil)
            Divider()
            ForEach(model.destinations(for: folder), id: \.folder.id) { row in
                Button(String(repeating: "    ", count: row.depth) + row.folder.name) { withAnimation(Theme.quick) { model.moveFolder(folder.id, to: row.folder.id) } }
                    .disabled(row.folder.id == folder.parent)
            }
        }
        if store.spaces.count > 1 {
            Menu("Déplacer vers l'espace") {
                ForEach(store.spaces.filter { $0.id != folder.space }) { space in
                    Button { withAnimation(Theme.quick) { model.move(folder, toSpace: space.id) } } label: { Label(space.name, systemImage: OutlineSymbol.name(space.icon)) }
                }
            }
        }
        Button(selected ? "Désélectionner" : "Sélectionner") { model.toggleSelection(folder.id, row: folder.id.uuidString) }
        Divider()
        Button("Supprimer…", role: .destructive) { model.pendingFolderDeletion = folder }
    }

    private func commit() {
        store.renameFolder(folder.id, to: name)
        model.renamingFolderID = nil
    }
}

/// The icons a folder can wear, in a grid; the current one in the accent color.
struct IconPicker: View {
    let selected: String
    let choose: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 6), spacing: 4) {
            ForEach(Folder.icons, id: \.self) { icon in
                IconCell(icon: icon, selected: icon == selected) { choose(icon) }
            }
        }
        .padding(10)
    }
}

private struct IconCell: View {
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.primaryText)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(icon)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
