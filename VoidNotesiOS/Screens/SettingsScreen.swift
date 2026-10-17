import SwiftUI

/// Réglages: theme, accent color, tint of the window, language, the list, and the folder the
/// notes are synchronised with.
/// Every change applies at once — but the language, from the next launch.
struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NoteStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var language = AppLanguage.current

    var body: some View {
        NavigationStack {
            #if BETA
            // The beta's settings outgrew one page: a page per subject, as in the system's apps.
            Form {
                Section {
                    link("Général", symbol: "gearshape") { languageSection; listSection; notesSection }
                    link("Apparence", symbol: "paintpalette") { appearanceSection }
                    link("Écriture", symbol: "character.cursor.ibeam") { writingSection }
                    link("Écoute", symbol: "waveform") { ListenSettingsSection() }
                    link("Synchronisation", symbol: "arrow.triangle.2.circlepath") { syncSection }
                }
            }
            .modifier(SettingsPage(title: "Réglages"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            #else
            Form {
                appearanceSection
                languageSection
                listSection
                writingSection
                syncSection
                notesSection
            }
            .modifier(SettingsPage(title: "Réglages"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
            #endif
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await sync.useFolder(url) }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(settings.colorScheme)
    }

    /// A row that opens a page of its own.
    private func link(_ title: LocalizedStringKey, symbol: String, @ViewBuilder sections: @escaping () -> some View) -> some View {
        NavigationLink {
            Form { sections() }
                .modifier(SettingsPage(title: title))
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        @Bindable var settings = settings
        Section("Apparence") {
            Picker("Thème", selection: $settings.theme) {
                ForEach(ThemeChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 14) {
                Text("Couleur")
                Spacer(minLength: 0)
                ForEach(AccentChoice.allCases) { choice in
                    let selected = settings.accent == choice
                    Button { withAnimation(Theme.quick) { settings.accent = choice } } label: {
                        Circle()
                            .fill(Theme.swatch(choice))
                            .frame(width: 24, height: 24)
                            .overlay {
                                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.onAccent) }
                            }
                            .padding(3)
                            .overlay(Circle().strokeBorder(selected ? Theme.swatch(choice) : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Teinte de la fenêtre")
                ChromeTintPicker()
            }
            ChromeTintOptions()
        }
    }

    @ViewBuilder private var languageSection: some View {
        Section {
            Picker("Langue", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: language) { AppLanguage.choose(language) }
        } footer: {
            if language.needsRelaunch { Text("La nouvelle langue s'appliquera au prochain lancement de Void Notes.") }
        }
    }

    @ViewBuilder private var listSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Afficher « Toutes les notes »", isOn: $settings.showsAllNotesRow)
        } header: {
            Text("Liste")
        } footer: {
            Text("En tête de la liste : dépliée, elle montre toutes les notes de l'espace, quel que soit leur dossier.")
        }
    }

    @ViewBuilder private var writingSection: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Vérifier l'orthographe", isOn: $settings.checksSpelling)
        } header: {
            Text("Écriture")
        } footer: {
            Text("Les mots inconnus sont soulignés en rouge ; touchez-les pour les corrections.")
        }
    }

    @ViewBuilder private var syncSection: some View {
        Section {
            LabeledContent {
                Button(sync.folderURL == nil ? "Choisir…" : "Changer…") { choosingFolder = true }
            } label: {
                Text(sync.folderURL?.lastPathComponent ?? String(localized: "Aucun dossier"))
                Text(syncStatus)
            }
            if sync.conflictCount > 0 {
                Label(sync.conflictCount == 1 ? "1 copie en conflit attend dans le dossier" : "\(sync.conflictCount) copies en conflit attendent dans le dossier", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if sync.folderURL != nil {
                Button("Synchroniser maintenant") { sync.syncNow() }
                    .disabled(sync.status == .syncing)
                Button("Arrêter la synchronisation", role: .destructive) { sync.stopSyncing() }
            }
        } header: {
            Text("Synchronisation")
        } footer: {
            #if BETA
            Text("Un dossier d'iCloud Drive propre à la bêta, autre que celui de Void Notes, le même que sur le Mac. Les notes restent aussi sur cet iPhone ; arrêter ne supprime rien.")
            #else
            Text("Le dossier « Void Notes » d'iCloud Drive, le même que sur le Mac. Les notes restent aussi sur cet iPhone ; arrêter ne supprime rien.")
            #endif
        }
    }

    @ViewBuilder private var notesSection: some View {
        Section {
            LabeledContent(store.notes.count == 1 ? "1 note" : "\(store.notes.count) notes", value: String(localized: "Enregistrées automatiquement"))
        } footer: {
            Text("Une note supprimée reste \(NoteStore.trashDays) jours dans la corbeille.")
        }
    }

    private var syncStatus: String {
        switch sync.status {
        case .notConfigured: String(localized: "Les notes ne sont que sur cet iPhone")
        case .folderUnavailable: String(localized: "Dossier introuvable : choisissez-le de nouveau")
        case .syncing: String(localized: "Synchronisation…")
        case .upToDate: sync.lastSyncAt.map { String(localized: "À jour — \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "En attente")
        case .waitingForDownload: String(localized: "iCloud Drive télécharge la dernière version…")
        case .outdated: String(localized: "Dossier écrit par une version plus récente : mettez Void Notes à jour sur cet iPhone")
        case .laterNoteHere: String(localized: "Suspendue : une note de cet iPhone vient d'une version plus récente de Void Notes ; mettez l'app à jour")
        case .failed(let reason): String(localized: "Échec : \(reason)")
        }
    }
}

/// The look of a page of the settings: on the app's chrome, its title small.
private struct SettingsPage: ViewModifier {
    let title: LocalizedStringKey

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.chrome)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
