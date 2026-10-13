import SwiftUI

/// "Archives" and "Corbeille" sit at the bottom of the list: unfolding one moves it up, folding
/// it moves it down. Its notes would cross the lines that move; they show only once those are in
/// place, and are gone before they move.
enum FoldMotion {
    /// Unfolds (`open`) or folds "Archives" or "Corbeille" (`id`, the row's id). `veiled` is the
    /// one whose notes are hidden meanwhile.
    @MainActor static func fold(_ id: String, open: Bool, veiled: Binding<String?>, toggle: @escaping () -> Void) {
        if open {
            withTransaction(Transaction(animation: nil)) { veiled.wrappedValue = id }
            withAnimation(Theme.quick) { toggle() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.quickDuration) {
                guard veiled.wrappedValue == id else { return }
                withAnimation(.easeOut(duration: Theme.quickDuration * 1.1)) { veiled.wrappedValue = nil }
            }
        } else {
            withAnimation(.easeOut(duration: Theme.quickDuration * 0.6)) { veiled.wrappedValue = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.quickDuration * 0.6) {
                withAnimation(Theme.quick) { toggle() }
                if veiled.wrappedValue == id { veiled.wrappedValue = nil }
            }
        }
    }

    /// "archive" or "trash": under which of them `row` shows, among the rows set apart; nil for
    /// those two lines themselves.
    static func group(of row: NotesModel.Row, in rows: ArraySlice<NotesModel.Row>) -> String? {
        var group: String?
        for candidate in rows {
            if candidate.id == "archive" || candidate.id == "trash" { group = candidate.id }
            if candidate.id == row.id { return candidate.id == group ? nil : group }
        }
        return nil
    }
}
