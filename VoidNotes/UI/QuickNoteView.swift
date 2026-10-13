import SwiftUI

/// The menu bar icon's window: a note written in a few seconds, without looking for the window.
/// The first line is its title; Markdown marks work (`- [ ] `, `**gras**`…). ⌘↩ adds it to the
/// space shown, at the top of the list.
struct QuickNoteView: View {
    @Environment(NotesModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var added = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Nouvelle note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(model.currentSpace.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Titre, puis le texte… (# - [ ] **gras** acceptés)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                        .padding(.top, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onChange(of: text) { added = false }
            }
            .frame(height: 130)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
            HStack(spacing: 8) {
                Button("Ouvrir Void Notes") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                Spacer()
                if added {
                    Label("Ajoutée", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity)
                }
                Button(action: add) {
                    Text("Ajouter  ⌘↩")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(NoteSurface())
        .tint(Theme.accent)
        .onAppear { focused = true }
    }

    private func add() {
        guard model.addQuickNote(text) else { return }
        text = ""
        withAnimation(Theme.quick) { added = true }
    }
}
