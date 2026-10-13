#if DEBUG
import AppKit

/// Debug builds only, on the Mac: what the launch arguments of `DebugLaunch` do to the window —
/// `-snapshot name` writes a picture of it (and of Réglages with `-showSettings YES`) in the
/// app's temporary folder and quits, `-selfTest YES` runs the checks.
extension DebugLaunch {
    @MainActor
    static func start(openSettings: @escaping () -> Void) {
        if isSelfTest { Task { await SelfTest.run() } }
        guard let name = snapshotName else { return }
        if UserDefaults.standard.bool(forKey: "showSettings") { openSettings() }
        // `-keys "Courses"`: a new note, typed on the keyboard ("" leaves it empty; "\n" is Return).
        if let keys = UserDefaults.standard.string(forKey: "keys") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotesModel.shared.newNote()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let window = NSApp.windows.first(where: { $0.frameAutosaveName == MainWindowView.autosaveName }) {
                        SelfTest.press(keys.replacingOccurrences(of: "\\n", with: "\n"), in: window)
                    }
                }
            }
        }
        // `-attach YES`: a picture (in the album) and a PDF joined at the end of the note shown.
        if UserDefaults.standard.bool(forKey: "attach") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let editor = NotesModel.shared.editor else { return }
                editor.attach(files: demoFiles(), at: NSRange(location: (editor.string as NSString).length, length: 0))
                editor.scrollToEndOfDocument(nil)
            }
        }
        // `-photos 5`: that many pictures in the album of the note shown.
        let photos = UserDefaults.standard.integer(forKey: "photos")
        if photos > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotesModel.shared.editor?.attach(files: (0..<photos).map { demoPicture(hue: CGFloat($0) / CGFloat(photos), name: "Photo \($0 + 1).png") })
            }
        }
        // `-scrolled YES`: the note shown scrolled down, past its title.
        if UserDefaults.standard.bool(forKey: "scrolled") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let editor = NotesModel.shared.editor else { return }
                editor.scroll(NSPoint(x: 0, y: 260))
            }
        }
        // `-showTrash YES`: the trash unfolded, its note shown.
        if UserDefaults.standard.bool(forKey: "showTrash") {
            NotesModel.shared.toggleTrash()
            NotesModel.shared.select(NoteStore.shared.trash.first?.id)
        }
        // `-showArchive YES`: "Archives" unfolded.
        if UserDefaults.standard.bool(forKey: "showArchive") { NotesModel.shared.toggleArchive() }
        // `-lock YES`: the note shown is locked, and hidden.
        if UserDefaults.standard.bool(forKey: "lock"), let id = NotesModel.shared.selectedID {
            NotesModel.shared.canAuthenticate = { true }
            NotesModel.shared.lock(id)
        }
        // `-showSelection YES`: the first folder and the first two notes of the list, picked together.
        if UserDefaults.standard.bool(forKey: "showSelection") {
            let model = NotesModel.shared
            var folders = 0, notes = 0
            for row in model.rows {
                guard let item = row.item else { continue }
                if case .folder = row, folders < 1 { folders += 1 } else if case .note = row, notes < 2 { notes += 1 } else { continue }
                if !model.selection.contains(item) { model.toggleSelection(item, row: row.id) }
            }
        }
        // `-switchTheme light -switchAccent green`: changed once the window is shown, to check
        // that everything on screen follows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let value = UserDefaults.standard.string(forKey: "switchTheme").flatMap(ThemeChoice.init) { AppSettings.shared.theme = value }
            if let value = UserDefaults.standard.string(forKey: "switchAccent").flatMap(AccentChoice.init) { AppSettings.shared.accent = value }
        }
        // `-link YES`: the last word of the note becomes a link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard let editor = NotesModel.shared.editor else { return }
            if UserDefaults.standard.bool(forKey: "link") {
                let string = editor.string as NSString
                let word = string.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)
                editor.setSelectedRange(NSRange(location: word.upperBound, length: string.length - word.upperBound))
                editor.setLink(URL(string: "https://void.app"))
                editor.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        // Time for what was typed to be read by the spelling checker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (index, window) in NSApp.windows.filter({ $0.isVisible && $0.contentView != nil }).enumerated() {
                // The frame view: toolbar included.
                guard let view = window.contentView?.superview, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: image)
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)-\(index).png")
                try? image.representation(using: .png, properties: [:])?.write(to: url)
                print("Snapshot: \(url.path)")
            }
            exit(0)
        }
    }

    /// A picture drawn here and a one-page PDF, written in the temporary folder.
    @MainActor
    private static func demoFiles() -> [URL] {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        let size = NSSize(width: 520, height: 260)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(hex: 0x4B3FD0), NSColor(hex: 0xF29E6B), NSColor(hex: 0xFFE3B0)])?.draw(in: rect, angle: 90)
            NSColor(hex: 0x1B1640).setFill()
            NSBezierPath(ovalIn: NSRect(x: -60, y: -150, width: 400, height: 240)).fill()
            NSBezierPath(ovalIn: NSRect(x: 240, y: -170, width: 420, height: 250)).fill()
            NSColor(hex: 0xFFF3D6).setFill()
            NSBezierPath(ovalIn: NSRect(x: 360, y: 150, width: 56, height: 56)).fill()
            return true
        }
        let picture = folder.appendingPathComponent("Miradouro.png")
        if let tiff = image.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: picture) }
        let pdf = folder.appendingPathComponent("Billets de train.pdf")
        let page = NSTextField(labelWithString: "Lisbonne — Sintra")
        page.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        try? page.dataWithPDF(inside: page.bounds).write(to: pdf)
        return [picture, pdf]
    }

    /// A picture of one color, taller than wide every other time.
    @MainActor
    private static func demoPicture(hue: CGFloat, name: String) -> URL {
        let size = Int(hue * 100) % 2 == 0 ? NSSize(width: 480, height: 320) : NSSize(width: 300, height: 420)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(hue: hue, saturation: 0.55, brightness: 0.5, alpha: 1), NSColor(hue: hue + 0.08, saturation: 0.4, brightness: 0.95, alpha: 1)])?.draw(in: rect, angle: 60)
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 30, y: rect.midY - 30, width: 60, height: 60)).fill()
            return true
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        if let tiff = image.tiffRepresentation { try? NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?.write(to: url) }
        return url
    }
}
#endif
