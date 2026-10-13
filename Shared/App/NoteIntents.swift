import AppIntents

/// « Nouvelle note » in Raccourcis, Siri, Spotlight — and, on iPhone, the Action button or a
/// shortcut of the share sheet: a note written without opening the app. The text is read as
/// Markdown; its first line is the title.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Nouvelle note"
    static let description = IntentDescription("Ajoute une note à Void Notes, sans l'ouvrir. La première ligne est le titre ; « - [ ] », « **gras** » et les autres marques Markdown sont lues.")
    static let openAppWhenRun = false

    @Parameter(title: "Texte", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ajouter \(\.$text) à Void Notes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard NotesModel.shared.addQuickNote(text) else {
            throw $text.needsValueError("Que faut-il écrire dans la note ?")
        }
        return .result(dialog: "Note ajoutée à Void Notes.")
    }
}

struct NoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewNoteIntent(), phrases: ["Nouvelle note dans \(.applicationName)", "Ajouter une note à \(.applicationName)"],
                    shortTitle: "Nouvelle note", systemImageName: "square.and.pencil")
    }
}
