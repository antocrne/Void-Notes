import ImageIO
import SwiftUI

/// The images of a note, shown under its title as on the Mac: an album — one large picture and
/// smaller ones next to it — followed by a line that separates it from the text. A tap opens
/// the picture.
struct NotePhotoAlbumSection: View {
    let noteID: UUID
    let store: NoteStore
    @State private var viewed: ViewedPhoto?

    static let albumHeight: CGFloat = 190
    /// The album, the space under it and the line.
    static let height: CGFloat = albumHeight + 14 + 1

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }
    /// A note of the trash, or of a later version, keeps its images as they are.
    private var canEdit: Bool { note?.deleted == nil && note?.isReadOnly == false }

    var body: some View {
        let photos = note?.photos ?? []
        VStack(spacing: 14) {
            NotePhotoMosaic(photos: photos, directory: store.attachmentsDirectory(of: noteID), height: Self.albumHeight) { viewed = ViewedPhoto(name: $0) }
            Rectangle().fill(Color(platform: Theme.dividerNS)).frame(height: 1).accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(photos.isEmpty ? 0 : 1)
        .fullScreenCover(item: $viewed) { photo in
            NotePhotoViewer(noteID: noteID, store: store, canEdit: canEdit, start: photo.name)
        }
    }
}

private struct ViewedPhoto: Identifiable {
    let name: String
    var id: String { name }
}

/// The mosaic: up to five pictures, the first one large; the last tile says how many more.
private struct NotePhotoMosaic: View {
    let photos: [String]
    let directory: URL
    let height: CGFloat
    let open: (String) -> Void

    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let shown = Array(photos.prefix(5))
            let width = geometry.size.width
            HStack(spacing: spacing) {
                if let first = shown.first {
                    tile(first, width: shown.count == 1 ? width : shown.count == 2 ? (width - spacing) / 2 : (width - spacing) * 0.6, height: height)
                }
                if shown.count == 2 {
                    tile(shown[1], width: (width - spacing) / 2, height: height)
                } else if shown.count > 2 {
                    let rest = Array(shown.dropFirst())
                    let side = (width - spacing) * 0.4
                    let columns = rest.count > 2 ? 2 : 1
                    let cellWidth = (side - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                    let cellHeight = (height - spacing) / 2
                    VStack(spacing: spacing) {
                        ForEach(0..<2, id: \.self) { line in
                            HStack(spacing: spacing) {
                                ForEach(Array(rest.enumerated()).filter { $0.offset / columns == line && columns == 2 || columns == 1 && $0.offset == line }, id: \.element) { index, name in
                                    tile(name, width: cellWidth, height: cellHeight)
                                        .overlay {
                                            if index == rest.count - 1, photos.count > 5 {
                                                ZStack {
                                                    Color.black.opacity(0.5)
                                                    Text("+\(photos.count - 5)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                                }
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .allowsHitTesting(false)
                                            }
                                        }
                                }
                            }
                            .frame(width: side, height: cellHeight, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func tile(_ name: String, width: CGFloat, height: CGFloat) -> some View {
        Button { open(name) } label: {
            NotePhotoImage(url: directory.appendingPathComponent(name), maxPixels: 900, fills: true)
                .frame(width: max(width, 0), height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image \(name)")
    }
}

/// A picture of a note, read from its file no larger than the screen needs. A file that isn't
/// on this iPhone yet (iCloud Drive is still bringing it) shows as a cloud.
struct NotePhotoImage: View {
    let url: URL
    let maxPixels: Int
    let fills: Bool
    @State private var image: UIImage?
    @State private var missing = false

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fills ? .fill : .fit)
            } else {
                Theme.hover
                if missing { Image(systemName: "icloud.and.arrow.down").font(.system(size: 20)).foregroundStyle(Theme.secondaryText) }
            }
        }
        .task(id: url) {
            let key = "\(url.path)#\(maxPixels)" as NSString
            if let cached = Self.cache.object(forKey: key) {
                image = cached
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(url, maxPixels: maxPixels) }.value
            if let loaded { Self.cache.setObject(loaded, forKey: key) }
            image = loaded
            missing = loaded == nil
        }
    }

    nonisolated private static func load(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

/// The pictures of a note, one at a time, full screen: a swipe goes to the next one.
private struct NotePhotoViewer: View {
    let noteID: UUID
    let store: NoteStore
    let canEdit: Bool
    @State var start: String
    @Environment(\.dismiss) private var dismiss

    private var photos: [String] { (store.note(noteID) ?? store.trashed(noteID))?.photos ?? [] }

    var body: some View {
        let photos = photos
        NavigationStack {
            TabView(selection: $start) {
                ForEach(photos, id: \.self) { name in
                    NotePhotoImage(url: store.attachmentsDirectory(of: noteID).appendingPathComponent(name), maxPixels: 2400, fills: false)
                        .tag(name)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .navigationTitle(photos.firstIndex(of: start).map { String(localized: "\($0 + 1) sur \(photos.count)") } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                if canEdit {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Retirer l'image de la note")
                    }
                }
            }
        }
        .tint(.white)
    }

    /// Takes the picture out of the album and shows its neighbor; the last one closes the viewer.
    private func remove() {
        let photos = photos
        guard let index = photos.firstIndex(of: start) else { return }
        let next = index + 1 < photos.count ? photos[index + 1] : index > 0 ? photos[index - 1] : nil
        store.removePhoto(start, from: noteID)
        if let next { start = next } else { dismiss() }
    }
}
