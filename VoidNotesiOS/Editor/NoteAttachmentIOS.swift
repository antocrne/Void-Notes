import ImageIO
import UIKit
import UniformTypeIdentifiers

/// How a file joined to a note shows in its text on iPhone: an image as itself, as wide as the
/// column at most; any other file (a PDF, an archive…) as a small card with its name and its
/// size. The file itself is in the note's attachments folder; the text only holds its name.
final class NoteFileAttachment: NSTextAttachment {
    let name: String
    /// nil: the note has no folder to look in.
    let url: URL?
    private let isPicture: Bool

    static let cardSize = CGSize(width: 280, height: 52)
    static let maxImageHeight: CGFloat = 420
    /// Longest side, in pixels, of the picture kept in memory.
    private static let maxPixels = 1600

    init(name: String, url: URL?) {
        self.name = name
        self.url = url
        let picture = url.flatMap(Self.picture(at:))
        isPicture = picture != nil
        super.init(data: nil, ofType: nil)
        image = picture ?? Self.card(name: name, url: url)
    }

    required init?(coder: NSCoder) {
        fatalError("NoteFileAttachment is never archived")
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let size = image?.size ?? Self.cardSize
        let room = max(80, lineFrag.width - position.x - 2 * (textContainer?.lineFragmentPadding ?? 0))
        let scale = min(1, room / size.width, isPicture ? Self.maxImageHeight / size.height : 1)
        return CGRect(x: 0, y: isPicture ? 0 : -6, width: floor(size.width * scale), height: floor(size.height * scale))
    }

    private static func picture(at url: URL) -> UIImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Shown at half its pixels at most: sharp on the screen, never wider than the column.
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }

    /// The card of a file that isn't an image: an icon, its name, "PDF · 1,2 Mo".
    private static func card(name: String, url: URL?) -> UIImage {
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } == true
        var detail = "Fichier introuvable"
        if exists, let url {
            let kind = (name as NSString).pathExtension.uppercased()
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            detail = kind.isEmpty ? size : "\(kind)  ·  \(size)"
        }
        return UIGraphicsImageRenderer(size: cardSize).image { _ in
            let card = CGRect(origin: .zero, size: cardSize).insetBy(dx: 0, dy: 1)
            UIColor.gray.withAlphaComponent(0.16).setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 10).fill()
            let icon = UIImage(systemName: "doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))?
                .withTintColor(Theme.secondaryTextNS, renderingMode: .alwaysOriginal)
            icon?.draw(at: CGPoint(x: card.minX + 14, y: card.midY - (icon?.size.height ?? 0) / 2))
            let truncating = NSMutableParagraphStyle()
            truncating.lineBreakMode = .byTruncatingMiddle
            let text = CGRect(x: card.minX + 48, y: card.minY + 7, width: card.width - 60, height: 19)
            (name as NSString).draw(in: text, withAttributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: Theme.primaryTextNS, .paragraphStyle: truncating,
            ])
            (detail as NSString).draw(in: text.offsetBy(dx: 0, dy: 20), withAttributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: Theme.secondaryTextNS, .paragraphStyle: truncating,
            ])
        }
    }
}

/// What `NoteFormat` asks for to show a joined file — the name it has on the Mac, where a cell
/// draws it.
enum NoteAttachmentCell {
    /// The character that shows `name`, a file of `directory`, with the attributes of body text.
    static func character(name: String, directory: URL?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: String(Note.attachmentCharacter), attributes: NoteFormat.attributes(block: nil))
        text.addAttributes(attributes(name: name, directory: directory), range: NSRange(location: 0, length: text.length))
        return text
    }

    static func attributes(name: String, directory: URL?) -> [NSAttributedString.Key: Any] {
        [NoteFormat.attachmentKey: name, .attachment: NoteFileAttachment(name: name, url: directory?.appendingPathComponent(name))]
    }
}
