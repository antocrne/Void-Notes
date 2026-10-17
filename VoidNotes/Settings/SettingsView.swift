import SwiftUI

/// Réglages (⌘,): language, theme, accent color, tint of the window, the listening, and where the
/// notes are — a tab per subject. Every change applies at once — but the language,
/// from the next launch.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NoteStore.self) private var store
    @Environment(SyncEngine.self) private var sync
    @State private var language = AppLanguage.current
    /// The tab shown: the one left last time.
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        // A tab per subject, as in the system's apps.
        TabView(selection: $tab) {
            page { languageSection; listSection; notesSection }
                .tabItem { Label("Général", systemImage: "gearshape") }
                .tag("general")
            page { appearanceSection }
                .tabItem { Label("Apparence", systemImage: "paintpalette") }
                .tag("appearance")
            page { writingSection }
                .tabItem { Label("Écriture", systemImage: "character.cursor.ibeam") }
                .tag("writing")
            page { ListenSettingsSection() }
                .tabItem { Label("Écoute", systemImage: "waveform") }
                .tag("listening")
            page { syncSection }
                .tabItem { Label("Synchronisation", systemImage: "arrow.triangle.2.circlepath") }
                .tag("sync")
        }
    }

    private func page(@ViewBuilder _ sections: () -> some View) -> some View {
        Form { sections() }
            .formStyle(.grouped)
            .tint(Theme.accent)
            .frame(width: 440)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var languageSection: some View {
        Section {
            Picker("Langue", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: language) { AppLanguage.choose(language) }
            if language.needsRelaunch {
                HStack {
                    Text("Void Notes doit redémarrer pour changer de langue.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Redémarrer Void Notes") { AppLanguage.relaunch() }
                }
            }
        }
    }

    @ViewBuilder private var appearanceSection: some View {
        Section("Apparence") {
            LabeledContent("Thème") { ThemePicker() }
            LabeledContent("Couleur") { AccentPicker() }
            LabeledContent("Teinte de la fenêtre") { ChromeTintPicker() }
            ChromeTintOptions()
        }
    }

    @ViewBuilder private var listSection: some View {
        Section("Liste") {
            @Bindable var settings = settings
            Toggle(isOn: $settings.showsAllNotesRow) {
                Text("Afficher « Toutes les notes »")
                Text("En tête de la liste : dépliée, elle montre toutes les notes de l'espace, quel que soit leur dossier.")
            }
            .toggleStyle(.switch)
            Toggle(isOn: $settings.showsQuickNote) {
                Text("Icône dans la barre des menus")
                Text("Pour écrire une note sans ouvrir la fenêtre. Void Notes reste alors ouvert quand la fenêtre est fermée.")
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder private var writingSection: some View {
        Section("Écriture") {
            @Bindable var settings = settings
            Toggle(isOn: $settings.checksSpelling) {
                Text("Vérifier l'orthographe")
                Text("Les mots inconnus sont soulignés en rouge ; clic droit pour les corrections.")
            }
            .toggleStyle(.switch)
            // Only when this version of macOS checks grammar.
            if ProofReader.grammarIsAvailable {
                Toggle(isOn: $settings.checksGrammar) {
                    Text("Vérifier la grammaire")
                    Text("Les fautes de grammaire sont soulignées en bleu.")
                }
                .toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder private var notesSection: some View {
        Section {
            LabeledContent {
                Button("Afficher dans le Finder") { showInFinder() }
                    .disabled(store.directory == nil)
            } label: {
                Text(store.notes.count == 1 ? "1 note" : "\(store.notes.count) notes")
                Text("Enregistrées automatiquement sur ce Mac")
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("Un fichier par note, dans le dossier de l'app. Aucun compte ; rien ne quitte le Mac sans dossier de synchronisation. Une note supprimée reste \(NoteStore.trashDays) jours dans la corbeille. Fichier → « Exporter toutes les notes… » les écrit en Markdown, lisibles partout.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var syncSection: some View {
        Section {
            LabeledContent {
                Button(sync.folderURL == nil ? "Choisir un dossier…" : "Changer…") { Task { await sync.chooseFolder() } }
            } label: {
                Text(sync.folderURL?.lastPathComponent ?? String(localized: "Aucun dossier"))
                Text(syncStatus)
            }
            if sync.conflictCount > 0 {
                Label(sync.conflictCount == 1 ? "1 copie en conflit attend dans le dossier" : "\(sync.conflictCount) copies en conflit attendent dans le dossier", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if let folder = sync.folderURL {
                HStack {
                    Button("Synchroniser maintenant") { sync.syncNow() }
                        .disabled(sync.status == .syncing)
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(SyncFile.fileName)]) }
                    Spacer()
                    Button("Arrêter", role: .destructive) { sync.stopSyncing() }
                }
            }
        } header: {
            Text("Synchronisation")
        } footer: {
            Text("Un dossier d'iCloud Drive, le même sur chaque appareil. Les notes restent aussi sur ce Mac ; arrêter ne supprime rien.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var syncStatus: String {
        switch sync.status {
        case .notConfigured: String(localized: "Les notes ne sont que sur ce Mac")
        case .folderUnavailable: String(localized: "Dossier introuvable : choisissez-le de nouveau")
        case .syncing: String(localized: "Synchronisation…")
        case .upToDate: sync.lastSyncAt.map { String(localized: "À jour — \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "En attente")
        case .waitingForDownload: String(localized: "iCloud Drive télécharge la dernière version…")
        case .outdated: String(localized: "Dossier écrit par une version plus récente : mettez Void Notes à jour sur ce Mac")
        case .laterNoteHere: String(localized: "Suspendue : une note de ce Mac vient d'une version plus récente de Void Notes ; mettez l'app à jour")
        case .failed(let reason): String(localized: "Échec : \(reason)")
        }
    }

    private func showInFinder() {
        guard let directory = store.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

/// Sombre · Clair · Système, drawn with the accent (the system segmented control follows the
/// macOS accent, not Void's).
struct ThemePicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ThemeChoice.allCases) { choice in
                let selected = settings.theme == choice
                Button { settings.theme = choice } label: {
                    Text(choice.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(selected ? Theme.accentSoft : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.hover))
    }
}

/// Five swatches; the choice applies at once everywhere the accent appears.
struct AccentPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentChoice.allCases) { choice in
                let selected = settings.accent == choice
                Button { withAnimation(Theme.quick) { settings.accent = choice } } label: {
                    Circle()
                        .fill(Theme.swatch(choice))
                        .frame(width: 18, height: 18)
                        .overlay {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onAccent)
                            }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Theme.swatch(choice) : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(choice.label)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Text(settings.accent.label).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
        }
    }
}
