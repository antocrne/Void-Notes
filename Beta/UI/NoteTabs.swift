import SwiftUI

/// The tab each note shows (the beta): its own text, its transcript, its summary — so that what
/// the listening heard, its summary and what one writes never get mixed. Remembered while the app
/// runs; a note opens on its own text.
@MainActor @Observable
final class NoteTabs {
    static let shared = NoteTabs()

    private var shown: [UUID: NotePart] = [:]

    /// The tab `note` shows — one it has.
    func part(of note: Note) -> NotePart {
        let part = shown[note.id] ?? .notes
        return note.content(of: part) == nil ? .notes : part
    }

    func show(_ part: NotePart, in id: UUID) {
        if shown[id] != part { shown[id] = part }
    }

    /// A note has tabs once it has a transcript or a summary.
    static func hasTabs(_ note: Note) -> Bool { note.transcript != nil || note.summary != nil }
}

#if os(macOS)
/// Under the title and the recordings: « Notes », « Transcription », « Résumé » — and, at the
/// end, the button that writes the summary (or what it is doing).
struct NoteTabBar: View {
    let noteID: UUID
    let store: NoteStore
    private let tabs = NoteTabs.shared
    private let summaries = NoteSummaries.shared

    /// The bar, its line included.
    static let height: CGFloat = 30

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }

    var body: some View {
        let shown = note.map(tabs.part(of:)) ?? .notes
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Theme.dividerNS))
                .frame(height: 1)
                .accessibilityHidden(true)
            HStack(alignment: .bottom, spacing: 18) {
                tab(.notes, "Notes", shown: shown)
                if note?.transcript != nil { tab(.transcript, "Transcription", shown: shown) }
                if note?.summary != nil { tab(.summary, "Résumé", shown: shown) }
                Spacer(minLength: 8)
                summarize
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onglets de la note")
    }

    private func tab(_ part: NotePart, _ label: LocalizedStringKey, shown: NotePart) -> some View {
        let selected = part == shown
        return Button { tabs.show(part, in: noteID) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(label)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
                    if part == .transcript, Listener.shared.isListening(to: noteID) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                            .accessibilityLabel("À l'écoute")
                    }
                }
                .frame(maxHeight: .infinity)
                Capsule()
                    .fill(selected ? Theme.accent : .clear)
                    .frame(height: 2)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var summarize: some View {
        if summaries.working == noteID {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(verbatim: summaries.step)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else if NoteSummaries.isAvailable, let note, note.transcript != nil, note.deleted == nil, !note.isReadOnly {
            Button { summaries.summarize(noteID) } label: {
                Label(note.summary == nil ? "Résumer" : "Résumer à nouveau", systemImage: "sparkles")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(summaries.working != nil || Listener.shared.isListening(to: noteID))
            .help("Résumer la transcription sur le Mac, avec Apple Intelligence")
        }
    }
}
#endif
