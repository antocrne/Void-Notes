import ImageIO
import PhotosUI
import SwiftUI

/// The images of a note, shown under its title as in Irum: an album — one large picture and
/// smaller ones next to it — followed by a line that separates it from the text. A click opens
/// the picture. The line belongs to the album: it isn't in the text.
struct NotePhotoAlbumSection: View {
    let noteID: UUID
    let store: NoteStore
    @State private var viewed: ViewedPhoto?

    static let albumHeight: CGFloat = 200
    /// The album, the space under it and the line.
    static let height: CGFloat = albumHeight + 14 + 1

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }
    /// A note of the trash, or of a later version, keeps its images as they are.
    private var canEdit: Bool { note?.deleted == nil && note?.isReadOnly == false }

    var body: some View {
        let photos = note?.photos ?? []
        VStack(spacing: 14) {
            NotePhotoAlbum(photos: photos, directory: store.attachmentsDirectory(of: noteID), height: Self.albumHeight,
                           onOpen: { viewed = ViewedPhoto(name: $0) },
                           onDelete: canEdit ? { name in withAnimation(Theme.quick) { store.removePhoto(name, from: noteID) } } : nil)
            Rectangle()
                .fill(Color(nsColor: Theme.dividerNS))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(photos.isEmpty ? 0 : 1)
        .sheet(item: $viewed) { photo in
            NotePhotoViewer(noteID: noteID, store: store, canEdit: canEdit, start: photo.name)
        }
    }
}

/// The picture the viewer opens on.
private struct ViewedPhoto: Identifiable {
    let name: String
    var id: String { name }
}

/// The mosaic: up to five pictures, the first one large; the last tile says how many more.
struct NotePhotoAlbum: View {
    let photos: [String]
    let directory: URL
    var height: CGFloat
    var onOpen: (String) -> Void
    /// nil: the images can't be removed.
    var onDelete: ((String) -> Void)?

    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            mosaic(width: geometry.size.width, height: height)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Images de la note")
    }

    @ViewBuilder
    private func mosaic(width: CGFloat, height: CGFloat) -> some View {
        let half = (width - spacing) / 2
        let halfHeight = (height - spacing) / 2
        switch photos.count {
        case 0:
            EmptyView()
        case 1:
            tile(photos[0], width: width, height: height)
        case 2:
            HStack(spacing: spacing) {
                tile(photos[0], width: half, height: height)
                tile(photos[1], width: half, height: height)
            }
        case 3:
            let large = (width - spacing) * 0.6
            HStack(spacing: spacing) {
                tile(photos[0], width: large, height: height)
                VStack(spacing: spacing) {
                    tile(photos[1], width: width - spacing - large, height: halfHeight)
                    tile(photos[2], width: width - spacing - large, height: halfHeight)
                }
            }
        case 4:
            let quarter = (half - spacing) / 2
            HStack(spacing: spacing) {
                tile(photos[0], width: half, height: height)
                VStack(spacing: spacing) {
                    tile(photos[1], width: half, height: halfHeight)
                    HStack(spacing: spacing) {
                        tile(photos[2], width: quarter, height: halfHeight)
                        tile(photos[3], width: quarter, height: halfHeight)
                    }
                }
            }
        default:
            let quarter = (half - spacing) / 2
            HStack(spacing: spacing) {
                tile(photos[0], width: half, height: height)
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        tile(photos[1], width: quarter, height: halfHeight)
                        tile(photos[2], width: quarter, height: halfHeight)
                    }
                    HStack(spacing: spacing) {
                        tile(photos[3], width: quarter, height: halfHeight)
                        tile(photos[4], width: quarter, height: halfHeight, hiddenCount: photos.count - 5)
                    }
                }
            }
        }
    }

    private func tile(_ name: String, width: CGFloat, height: CGFloat, hiddenCount: Int = 0) -> some View {
        Button { onOpen(name) } label: {
            NotePhotoImage(url: directory.appendingPathComponent(name), full: false)
                .frame(width: max(width, 1), height: max(height, 1))
                .clipped()
                .overlay {
                    if hiddenCount > 0 {
                        ZStack {
                            Color.black.opacity(0.4)
                            Text("+\(hiddenCount)")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voir l'image")
        .contextMenu {
            Button("Voir l'image", systemImage: "photo") { onOpen(name) }
            Button("Afficher dans le Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([directory.appendingPathComponent(name)])
            }
            if let onDelete {
                Divider()
                Button("Supprimer l'image", systemImage: "trash", role: .destructive) { onDelete(name) }
            }
        }
    }
}

/// A picture filling its frame (or fitting in it); a quiet background when its file is missing.
struct NotePhotoImage: View {
    let url: URL
    var full: Bool
    var fits = false

    var body: some View {
        if let image = NotePhotoCache.image(at: url, full: full) {
            if fits {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }
            }
        } else {
            Rectangle()
                .fill(Theme.hover)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.secondaryText)
                        .opacity(0.6)
                }
                .help("Image introuvable")
        }
    }
}

/// The pictures as they are drawn, no larger than the screen needs, kept while memory allows.
@MainActor
enum NotePhotoCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL, full: Bool) -> NSImage? {
        let key = "\(full ? "full" : "small"):\(url.path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // A photo taken sideways shows upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: full ? 4000 : 1400,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// One picture, large; the arrows (on screen or on the keyboard) go to the others.
struct NotePhotoViewer: View {
    let noteID: UUID
    let store: NoteStore
    let canEdit: Bool
    @State private var current: String
    @Environment(\.dismiss) private var dismiss

    init(noteID: UUID, store: NoteStore, canEdit: Bool, start: String) {
        self.noteID = noteID
        self.store = store
        self.canEdit = canEdit
        _current = State(initialValue: start)
    }

    private var photos: [String] { (store.note(noteID) ?? store.trashed(noteID))?.photos ?? [] }
    private var index: Int? { photos.firstIndex(of: current) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(index.map { "\($0 + 1) sur \(photos.count)" } ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if canEdit {
                    ChromeButton(symbol: "trash", help: "Supprimer l'image", action: deleteCurrent)
                }
                Button("Terminé") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            ZStack {
                Color.black
                if index != nil {
                    NotePhotoImage(url: store.attachmentsDirectory(of: noteID).appendingPathComponent(current), full: true, fits: true)
                        .padding(12)
                }
                HStack {
                    arrow("chevron.left", offset: -1)
                    Spacer()
                    arrow("chevron.right", offset: 1)
                }
                .padding(12)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 680)
        .background(Theme.surface)
        .onChange(of: photos) { _, photos in
            if photos.isEmpty { dismiss() }
        }
    }

    private func arrow(_ symbol: String, offset: Int) -> some View {
        let isEnabled = index.map { photos.indices.contains($0 + offset) } ?? false
        return Button { step(offset) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0)
        .disabled(!isEnabled)
        .accessibilityLabel(offset < 0 ? "Image précédente" : "Image suivante")
    }

    private func step(_ offset: Int) {
        guard let index, photos.indices.contains(index + offset) else { return }
        current = photos[index + offset]
    }

    /// Removes the picture shown and goes to the next one (the one before at the end of the album).
    private func deleteCurrent() {
        guard let index else { return }
        let photos = photos
        let next = photos.indices.contains(index + 1) ? photos[index + 1] : index > 0 ? photos[index - 1] : nil
        let removed = current
        if let next { current = next }
        store.removePhoto(removed, from: noteID)
    }
}

/// Button that adds images to the note's album, from Photos or from files — Irum's.
struct PhotoButton: View {
    let model: NotesModel
    let store: NoteStore
    @State private var showsPicker = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var hovering = false

    var body: some View {
        let disabled = model.selected == nil || model.selected?.isReadOnly == true
        Menu {
            Button("Depuis la photothèque", systemImage: "photo.on.rectangle") { showsPicker = true }
            Button("Depuis un fichier…", systemImage: "folder") { model.editor?.choosePhotos() }
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !disabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help("Ajouter des images")
        .accessibilityLabel("Ajouter des images")
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .photosPicker(isPresented: $showsPicker, selection: $picked, maxSelectionCount: 30, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty, let id = model.selected?.id else { return }
            picked = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
                    store.addPhoto(data, named: "Photo.\(type?.preferredFilenameExtension ?? "jpg")", to: id)
                }
            }
        }
    }
}
