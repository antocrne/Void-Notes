import SwiftUI

/// The tags of a note, after its title in the list: a dot of each color.
struct TagDots: View {
    let tags: [NoteTag]
    var size: CGFloat = 7

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 2) {
                ForEach(tags) { tag in
                    Circle().fill(Theme.tag(tag)).frame(width: size, height: size)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.label(tags) ?? "")
        }
    }

    /// What VoiceOver says of them: "Rouge, Bleu"; nil without any.
    static func label(_ tags: [NoteTag]) -> String? {
        tags.isEmpty ? nil : tags.map(\.label).joined(separator: ", ")
    }
}

/// The row of colors of a note's menu (right click on the Mac, long press on iPhone), as the
/// Finder's: a click puts the color on the notes, or takes it off when they all have it; the colors
/// they all have are checked.
struct TagPalette: View {
    let notes: [Note]
    @Environment(NotesModel.self) private var model

    var body: some View {
        let notes = notes.filter { !$0.isBlank && !$0.isReadOnly }
        ControlGroup {
            ForEach(NoteTag.allCases) { tag in
                let on = !notes.isEmpty && notes.allSatisfy { $0.tags.contains(tag) }
                Button { withAnimation(Theme.quick) { model.toggleTag(tag, for: notes.map(\.id)) } } label: {
                    Label(tag.label, systemImage: on ? "checkmark.circle.fill" : "circle.fill")
                }
                .tint(Theme.tag(tag))
            }
        }
        .controlGroupStyle(.palette)
        .disabled(notes.isEmpty)
    }
}
