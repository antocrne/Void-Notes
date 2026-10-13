import SwiftUI

/// Bottom of the list, as in Void: one icon per space — a click shows the space, the menu (right
/// click) renames it, changes its icon or deletes it. The name of the space shows a moment when
/// one goes to it, and while the pointer is on the bar; so does the button that makes a new one
/// (also in the bar's menu).
struct SpaceBar: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @State private var creating = false
    @State private var hovering = false
    /// Just went to another space: its name shows a moment.
    @State private var announcing = false
    @State private var announcement: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.spaces) { space in
                SpaceIconButton(space: space, selected: space.id == model.currentSpaceID)
            }
            Text(model.currentSpace.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .padding(.leading, 6)
                .opacity(hovering || announcing ? 1 : 0)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            ChromeButton(symbol: "plus", help: "Nouvel espace", size: 12) { creating = true }
                .opacity(hovering || creating ? 1 : 0)
                .popover(isPresented: $creating, arrowEdge: .top) {
                    SpaceForm(title: "Nouvel espace", name: "", icon: "circle", confirm: "Créer") { name, icon in
                        if let name { withAnimation(Theme.quick) { model.newSpace(named: name, icon: icon) } }
                        creating = false
                    }
                }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Theme.quick) { self.hovering = hovering } }
        .contextMenu { Button("Nouvel espace…") { creating = true } }
        .onChange(of: model.currentSpaceID) {
            announcement?.cancel()
            withAnimation(Theme.quick) { announcing = true }
            announcement = Task {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.4)) { announcing = false }
            }
        }
        #if DEBUG
        // `-showSpaces YES`: the new space form, for the snapshots.
        .onAppear {
            guard UserDefaults.standard.bool(forKey: "showSpaces") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { creating = true }
        }
        #endif
    }
}

private struct SpaceIconButton: View {
    let space: Space
    let selected: Bool
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @State private var editing = false
    @State private var confirmingDeletion = false

    var body: some View {
        ChromeButton(symbol: OutlineSymbol.name(space.icon), verbatimHelp: space.name, active: selected) {
            withAnimation(Theme.quick) { model.switchSpace(to: space.id) }
        }
        .symbolVariant(selected ? .fill : .none)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Renommer, changer l'icône…") { editing = true }
            Divider()
            Button("Supprimer l'espace…", role: .destructive) { confirmingDeletion = true }
                .disabled(store.spaces.count < 2)
        }
        .popover(isPresented: $editing, arrowEdge: .top) {
            SpaceForm(title: "Espace", name: space.name, icon: space.icon, confirm: "OK") { name, icon in
                if let name {
                    store.renameSpace(space.id, to: name)
                    store.setIcon(icon, forSpace: space.id)
                }
                editing = false
            }
        }
        .confirmationDialog("Supprimer l'espace « \(space.name) » ?", isPresented: $confirmingDeletion) {
            Button("Supprimer l'espace", role: .destructive) { withAnimation(Theme.quick) { model.delete(space) } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Aucune note n'est supprimée : ses dossiers et ses notes vont dans l'espace « \(store.spaces.first { $0.id != space.id }?.name ?? "") ».")
        }
    }
}

/// Name and icon of a space: to make one, or to change one. `done` gets the name typed, or nil
/// when the form is cancelled.
private struct SpaceForm: View {
    let title: LocalizedStringKey
    @State var name: String
    @State var icon: String
    let confirm: LocalizedStringKey
    let done: (String?, String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold))
            TextField("Nom (Travail, Maison…)", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .focusEffectDisabled()
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(focused ? Theme.accent : .clear, lineWidth: 1.5))
                .onSubmit { done(name, icon) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(Space.icons, id: \.self) { symbol in
                    Button { icon = symbol } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(icon == symbol ? Theme.accentSoft : .clear))
                            .foregroundStyle(icon == symbol ? Theme.accent : Theme.primaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                }
            }
            HStack {
                Spacer()
                Button("Annuler") { done(nil, icon) }
                    .keyboardShortcut(.cancelAction)
                Button(confirm) { done(name, icon) }
                    .keyboardShortcut(.defaultAction)
                    .primaryButton()
            }
        }
        .foregroundStyle(Theme.primaryText)
        .padding(16)
        .frame(width: 284)
        .onAppear { focused = true }
    }
}
