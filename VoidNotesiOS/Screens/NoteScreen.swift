import PhotosUI
import QuickLook
import SwiftUI

/// A note, pushed over the list: its text, and in the bar images and files, then the rest —
/// the lock among it — in a menu. The bar's buttons are in the text's color, not the accent, and
/// step aside while one types. A locked note shows nothing but that it is locked.
struct NoteScreen: View {
    @Environment(NoteStore.self) private var store
    @Environment(NotesModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var controller = NoteEditorController()
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    /// The joined file being shown.
    @State private var preview: URL?

    var body: some View {
        Group {
            if let note = model.selected, model.isConcealed(note) {
                LockedNote(note: note)
            } else if let note = model.selected {
                NoteTextEditor(note: note, accent: settings.accent, checksSpelling: settings.checksSpelling, searchQuery: model.query,
                               controller: controller, store: store, onOpenFile: { preview = $0 },
                               onWriting: { writing in if model.writing != writing { model.writing = writing } }) { content in
                    store.update(note.id, content: content)
                }
                // A new editor for each note — and for a note that leaves the trash, which can
                // be written again, or that another device changed; and when the frame goes from
                // neutral to tinted or back (its grey changes).
                .id("\(note.id)\(note.deleted == nil)\(store.revisions[note.id] ?? 0)\(settings.chromeTint == .none)")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The page goes on under the keyboard (and its rounded corners): no black shows between.
        .background(NoteSurface().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ChromeNavigationBar(flat: Theme.surface))
        .toolbar {
            if let note = model.selected {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if note.deleted != nil {
                        Button("Restaurer") { withAnimation(Theme.quick) { model.restore(note) } }
                        Button(role: .destructive) { model.pendingDeletion = note } label: { Image(systemName: "xmark.bin") }
                            .tint(Theme.danger)
                            .accessibilityLabel("Supprimer définitivement")
                    } else if model.isConcealed(note) {
                        EmptyView()
                    } else {
                        Group {
                            #if BETA
                            if Listener.isAvailable, !note.isReadOnly {
                                ListenButton(listener: .shared, note: note)
                            }
                            #endif
                            if !note.isReadOnly {
                                Menu {
                                    Button("Photothèque", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                                    Button("Joindre un fichier", systemImage: "paperclip") { choosingFiles = true }
                                } label: { Image(systemName: "photo.on.rectangle.angled") }
                                    .accessibilityLabel("Ajouter des images ou un fichier")
                            }
                            // The lock is in this menu, with what else is done to the note.
                            Menu { NoteMenu(note: note) } label: { Image(systemName: "ellipsis.circle") }
                                .accessibilityLabel("Autres actions")
                                .disabled(note.isBlank)
                        }
                        .tint(Theme.primaryText)
                        .opacity(model.writing ? 0 : 1)
                        .animation(.easeInOut(duration: model.writing ? 0.6 : 0.2), value: model.writing)
                    }
                }
                .glassHidden(model.writing && note.deleted == nil)
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $pickedPhotos, matching: .images)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty, let id = model.selectedID else { return }
            pickedPhotos = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
                    store.addPhoto(data, named: "Photo.\(type?.preferredFilenameExtension ?? "jpg")", to: id)
                }
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, let id = model.selectedID else { return }
            var names: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // Images go to the album, the other files where the cursor is.
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    store.addPhotos([url], to: id)
                } else if let name = store.attach(url, to: id) {
                    names.append(name)
                }
            }
            controller.textView?.insertAttachments(names)
        }
        .quickLookPreview($preview)
        // Back to the list, or to another note: nothing is being typed any more.
        .onDisappear { model.writing = false }
        .alert(controller.textView?.currentLink == nil ? "Ajouter un lien" : "Modifier le lien", isPresented: $controller.askingLink) {
            TextField("Adresse du lien", text: $controller.linkDraft, prompt: Text(verbatim: "void.app, nom@exemple.fr…"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("OK") { controller.applyLink() }
            if controller.textView?.currentLink != nil {
                Button("Retirer le lien", role: .destructive) { controller.removeLink() }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(controller.textView?.selectedRange.length ?? 0 > 0 || controller.textView?.currentLink != nil
                 ? "Le texte choisi ouvrira cette adresse." : "L'adresse sera écrite à l'endroit du curseur.")
        }
    }
}

/// A locked note, before Face ID: nothing of it but that it is locked, and the way in.
private struct LockedNote: View {
    let note: Note
    @Environment(NotesModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text("Note verrouillée")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Button("Déverrouiller") { model.unlock(note.id) }
                .buttonStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Capsule().fill(Theme.accentSoft))
                .accessibilityHint("Avec \(NoteLock.method)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.unlock(note.id) }
    }
}

extension ToolbarContent {
    /// While one types, the glass behind the bar's buttons goes with them (iOS 26 and later).
    @ToolbarContentBuilder
    func glassHidden(_ hidden: Bool) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }
}
