import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A note sent by another app as `voidnotes://new?title=…&text=…&url=…&image=…` (Void: a
/// selection, a page or an image). The title becomes the note's title line, the image and the
/// text follow, the address of the source ends the note as a "Source : …" line. Anything can
/// open such a URL: the text is taken as plain text only, the image only if ImageIO reads it.
/// `voidnotes://append?note=<id>&…` adds the same at the end of that note (one of those
/// `NoteDirectory` lists), its title a subheading.
enum NoteImport {
    static let scheme = "voidnotes"
    /// What the URL asks: a new note, or an addition to the note `note=`.
    static let commands: Set<String> = ["new", "append"]
    /// More than a URL should ever carry; the rest is dropped.
    static let maxLength = 100_000
    /// What the address of the page is written after.
    static let sourceLabel = String(localized: "Source : ")
    /// Where the sender leaves the image (`image=` gives its name): a URL can't carry it. Read
    /// once, then cleared. Named pasteboards are read without the system's paste alert.
    static let imagePasteboard = "app.void.notes.incoming"
    /// Larger is left on the pasteboard.
    static let maxImageBytes = 30_000_000

    /// nil: not a note (another scheme or command, or nothing in it). `image`: the name of the
    /// image in the note's attachments folder, shown under the title. `appended`: what goes at
    /// the end of a note already written — the title is a subheading there.
    static func content(from url: URL, image: String? = nil, appended: Bool = false) -> NoteContent? {
        guard isNote(url), let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String {
            let raw = items.first { $0.name == name }?.value ?? ""
            // An attachment character without its file would show as a broken attachment.
            return String(raw.prefix(maxLength)).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .filter { $0 != Note.attachmentCharacter }
        }
        // The title is one line.
        let title = value("title").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let body = value("text").trimmingCharacters(in: .whitespacesAndNewlines)
        // Only a web address is kept as the source.
        let link = value("url").trimmingCharacters(in: .whitespacesAndNewlines)
        let address = URL(string: link).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? link : nil } ?? ""
        let source = address.isEmpty ? "" : sourceLabel + address

        var rest = [body, source].filter { !$0.isEmpty }.joined(separator: "\n\n")
        // The image on its own line, the text right under it, as the editor puts a file.
        if let image, !image.isEmpty { rest = String(Note.attachmentCharacter) + (rest.isEmpty ? "" : "\n" + rest) }
        guard !title.isEmpty || !rest.isEmpty else { return nil }
        let text = title.isEmpty ? rest : rest.isEmpty ? title : title + "\n" + rest
        var runs: [StyleRun] = []
        // The run of a paragraph includes its line break, as the editor writes it.
        if !title.isEmpty { runs.append(StyleRun(start: 0, length: (title as NSString).length + (rest.isEmpty ? 0 : 1), block: appended ? .subheading : .title)) }
        if let image, !image.isEmpty {
            runs.append(StyleRun(start: title.isEmpty ? 0 : (title as NSString).length + 1, length: 1, attachment: image))
        }
        if !source.isEmpty {
            let length = (source as NSString).length
            runs.append(StyleRun(start: (text as NSString).length - length, length: length, block: .source))
        }
        return NoteContent(text: text, runs: runs)
    }

    static func isNote(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && commands.contains(url.host()?.lowercased() ?? "")
    }

    /// The note `voidnotes://append?note=…` adds to; nil for a new note.
    static func target(of url: URL) -> UUID? {
        guard isNote(url), url.host()?.lowercased() == "append" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "note" }?.value.flatMap(UUID.init(uuidString:))
    }

    /// `clip` at the end of `content`, after an empty line. A paragraph style that ran to the
    /// end of the note takes in the line break that now ends its paragraph, as the editor writes it.
    static func appending(_ clip: NoteContent, to content: NoteContent) -> NoteContent {
        let text = content.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return clip }
        let separator = text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        let length = (text as NSString).length, offset = length + (separator as NSString).length
        var runs = content.runs.map { run in
            var run = run
            if run.block != nil, run.start + run.length == length, !text.hasSuffix("\n") { run.length += 1 }
            return run
        }
        runs += clip.runs.map { run in
            var run = run
            run.start += offset
            return run
        }
        return NoteContent(text: text + separator + clip.text, runs: runs)
    }

    /// The image a note sent with `image=…` comes with: taken off the pasteboard, with the name
    /// it gets in the note (the one asked for, the extension of its real format). nil: no image
    /// asked for, or none that reads on the pasteboard.
    static func image(for url: URL) -> (data: Data, name: String)? {
        guard isNote(url), let asked = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "image" })?.value,
              !asked.isEmpty, let (data, type) = takeImage() else { return nil }
        return (data, imageName(asked, type: type))
    }

    static func imageName(_ asked: String, type: UTType) -> String {
        let base = (asked as NSString).deletingPathExtension
            .filter { $0 != Note.attachmentCharacter && !$0.isNewline }
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? String(localized: "Image") : String(base.prefix(80))) + "." + (type.preferredFilenameExtension ?? "png")
    }

    /// Reads the image left on the pasteboard, and clears it.
    private static func takeImage() -> (Data, UTType)? {
        let isImage = { (identifier: String) in UTType(identifier)?.conforms(to: .image) == true }
        #if os(macOS)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(imagePasteboard))
        defer { pasteboard.clearContents() }
        let item = pasteboard.pasteboardItems?.first
        guard let type = item?.types.first(where: { isImage($0.rawValue) }), let data = item?.data(forType: type) else { return nil }
        #else
        guard let pasteboard = UIPasteboard(name: UIPasteboard.Name(imagePasteboard), create: false) else { return nil }
        defer { UIPasteboard.remove(withName: UIPasteboard.Name(imagePasteboard)) }
        guard let type = pasteboard.types.first(where: isImage), let data = pasteboard.data(forPasteboardType: type) else { return nil }
        #endif
        // What the data really is, whatever the pasteboard says.
        guard data.count <= maxImageBytes, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let read = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), read.conforms(to: .image) else { return nil }
        return (data, read)
    }
}
