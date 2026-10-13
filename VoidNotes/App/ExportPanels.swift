import AppKit
import UniformTypeIdentifiers

/// Fichier → « Exporter en Markdown… » and « Exporter toutes les notes… »: where to write, asked
/// in a panel (the app writes nowhere else), then shown in the Finder.
@MainActor
enum ExportPanels {
    /// The note being shown, as a `.md` file — or as a folder, when it has images or files.
    static func export(_ note: Note, store: NoteStore) {
        let folder = NoteExport.needsFolder(note, store: store)
        let panel = NSSavePanel()
        panel.title = String(localized: "Exporter en Markdown")
        panel.prompt = String(localized: "Exporter")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = NoteMarkdown.fileName(for: note)
        if folder {
            panel.message = String(localized: "La note a des images ou des fichiers : un dossier est créé, avec le fichier Markdown et une copie de ses fichiers.")
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        }
        run(panel) { url in
            try NoteExport.write(note, to: url, store: store)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Every note, as Markdown files filed in folders like the list, in a new folder of the
    /// folder chosen.
    static func exportAll(store: NoteStore) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Exporter toutes les notes")
        panel.prompt = String(localized: "Exporter ici")
        panel.message = String(localized: "Un dossier « Void Notes » y est créé : une note par fichier Markdown, rangées comme dans la liste. La corbeille et les notes verrouillées n'en font pas partie.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        run(panel) { url in
            let (folder, locked) = try NoteExport.writeAll(store: store, in: url)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            guard locked > 0 else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Export terminé")
            alert.informativeText = locked == 1 ? String(localized: "Une note verrouillée n'a pas été exportée : ouvrez-la, puis Fichier → « Exporter en Markdown… ».")
                : String(localized: "\(locked) notes verrouillées n'ont pas été exportées : ouvrez-les une à une, puis Fichier → « Exporter en Markdown… ».")
            alert.runModal()
        }
    }

    private static func run(_ panel: NSSavePanel, write: @escaping (URL) throws -> Void) {
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(url)
            } catch {
                NoteStore.shared.errorMessage = String(localized: "L'export n'a pas pu être écrit : \(error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
}
