import SwiftUI

/// While listening: a small bar at the foot of the note — that the microphone hears (a meter of
/// five bars in the accent), for how long, the words being said, and « Arrêter ». Always in
/// sight, even while one types: the microphone is never on without it showing. Not tied to a
/// note: listening in another one, it says which, and opens it.
struct ListeningBar: View {
    let listener: Listener
    let store: NoteStore
    let model: NotesModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(macOS)
    private static let titleFont = Font.system(size: 12, weight: .semibold)
    private static let detailFont = Font.system(size: 11)
    private static let stopSize: CGFloat = 26
    #else
    private static let titleFont = Font.subheadline.weight(.semibold)
    private static let detailFont = Font.footnote
    private static let stopSize: CGFloat = 44
    #endif

    var body: some View {
        HStack(spacing: 10) {
            LevelMeter(levels: listener.levels, hearing: listener.phase == .listening && !listener.isInterrupted, animated: !reduceMotion)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Self.titleFont)
                        .foregroundStyle(Theme.primaryText)
                    if let start = listener.startedAt, listener.phase == .listening {
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(Self.detailFont.monospacedDigit())
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if listener.isInterrupted {
                Button("Reprendre") { listener.resume() }
                    .buttonStyle(.plain)
                    .font(Self.detailFont.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: Self.stopSize)
            }
            if case .saving = listener.phase {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Self.stopSize, height: Self.stopSize)
            } else if listener.phase == .listening || listener.phase == .finishing {
                Button { Task { await listener.stop() } } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.accentFill))
                        .frame(width: Self.stopSize, height: Self.stopSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(listener.phase != .listening)
                #if os(macOS)
                .help("Arrêter l'écoute (⇧⌘D)")
                #endif
                .accessibilityLabel("Arrêter l'écoute")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 460)
        // The floating look of the note's own buttons (`NoteActions`), a little rounder.
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                .shadow(color: Theme.shadow.opacity(0.14), radius: 8, y: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Écoute")
    }

    private var title: String {
        switch listener.phase {
        case .idle, .preparing: String(localized: "Préparation de l'écoute…")
        case .downloading(let done): String(localized: "Téléchargement du modèle… \(done.formatted(.percent.precision(.fractionLength(0))))")
        case .listening: listener.isInterrupted ? String(localized: "Écoute interrompue") : String(localized: "À l'écoute")
        case .finishing: String(localized: "Fin de l'écoute…")
        case .saving(.voicesModel): String(localized: "Téléchargement du modèle des voix…")
        case .saving(.voices): String(localized: "Séparation des voix…")
        case .saving(.audio): String(localized: "Enregistrement de l'audio…")
        }
    }

    @ViewBuilder private var detail: some View {
        if listener.phase == .listening || listener.phase == .saving(.voices) || listener.phase == .saving(.audio),
           let id = listener.noteID, id != model.selectedID, let note = store.note(id) {
            // Listening in a note that isn't the one shown: a tap goes back to it.
            Button { model.open(id) } label: {
                Text("Dans « \(note.title.isEmpty ? String(localized: "Nouvelle note") : note.title) »")
                    .font(Self.detailFont)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Ouvre la note")
        } else if listener.isInterrupted {
            Text("Le micro est pris par un appel ou par une autre app.")
                .font(Self.detailFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
        } else if !listener.words.isEmpty {
            // The words being said, their end in view.
            Text(listener.words)
                .font(Self.detailFont)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

/// Five bars, the latest on the right: whether the microphone hears, not how well.
private struct LevelMeter: View {
    let levels: [Float]
    let hearing: Bool
    let animated: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(hearing ? Theme.accent : Theme.secondaryText.opacity(0.5))
                    .frame(width: 3, height: 4 + 14 * CGFloat(hearing ? levels[index] : 0))
            }
        }
        .frame(width: 24, height: 18)
        .animation(animated ? .easeOut(duration: 0.12) : nil, value: levels)
        .accessibilityHidden(true)
    }
}

/// The microphone of the note. Listening in it: stops. Else it offers the language and what to
/// hear — the Mac's sound too, on the Mac — then starts (⇧⌘D starts at once, as last time).
struct ListenButton: View {
    let listener: Listener
    let note: Note?
    #if os(macOS)
    @State private var choosing = false
    #endif

    private var disabled: Bool { !listener.isListening(to: note?.id) && (!listener.canListen(in: note) || listener.isActive) }

    var body: some View {
        let listening = listener.isListening(to: note?.id)
        #if os(macOS)
        ChromeButton(symbol: listening ? "waveform.circle.fill" : "waveform", help: listening ? "Arrêter l'écoute (⇧⌘D)" : "Écouter et transcrire…",
                     active: listening || choosing, disabled: disabled) {
            if listening { listener.toggle(in: note?.id) } else { choosing = true }
        }
        .accessibilityValue(listening ? Text("En cours") : Text(""))
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            ListenOptions(listener: listener, note: note) { choosing = false }
        }
        #else
        if listening {
            Button { listener.toggle(in: note?.id) } label: { Image(systemName: "waveform.circle.fill") }
                .accessibilityLabel("Arrêter l'écoute")
                .accessibilityValue(Text("En cours"))
        } else {
            // A language picked starts the listening in it.
            Menu {
                Section("Écouter en") {
                    ForEach(ListenLanguage.choices) { choice in
                        Button {
                            if let id = note?.id { Task { await listener.start(in: id, language: choice.id) } }
                        } label: {
                            if choice.id == ListenLanguage.current { Label(choice.name, systemImage: "checkmark") } else { Text(verbatim: choice.name) }
                        }
                    }
                }
            } label: {
                Image(systemName: "waveform")
            }
            .disabled(disabled)
            .accessibilityLabel("Écouter et transcrire")
        }
        #endif
    }
}

#if os(macOS)
/// What the note's microphone offers before it starts: the language, what to hear, and
/// « Écouter » (⏎). The choices stay for next time.
struct ListenOptions: View {
    let listener: Listener
    let note: Note?
    let done: () -> Void
    @State private var language = ListenLanguage.current
    @State private var source = ListenSource.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Écouter et transcrire")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Langue").foregroundStyle(Theme.secondaryText).fixedSize().gridColumnAlignment(.trailing)
                    Picker("Langue", selection: $language) {
                        ForEach(ListenLanguage.choices) { Text(verbatim: $0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Entendre").foregroundStyle(Theme.secondaryText).fixedSize()
                    Picker("Entendre", selection: $source) {
                        ForEach(ListenSource.choices) { Text($0.shortLabel).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .font(.system(size: 12))
            if source != .microphone {
                Text("Un appel, une vidéo : tout ce que joue le Mac. macOS demande l'autorisation la première fois.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Écouter") {
                    done()
                    if let id = note?.id { Task { await listener.start(in: id, language: language, source: source) } }
                }
                .primaryButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
        .tint(Theme.accent)
    }
}
#endif

/// What the listening asks or says: whether to download a language's model, why it couldn't
/// start, why a summary couldn't be written — and what a recording's card asks (its voices'
/// names, whether to delete it).
struct ListeningAlerts: ViewModifier {
    let listener: Listener

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .modifier(RecordingAlerts())
            #endif
            .alert("Télécharger le modèle de transcription ?",
                   isPresented: Binding(get: { listener.languageToInstall != nil }, set: { if !$0, listener.phase == .idle { listener.cancelInstall() } })) {
                Button("Télécharger") { Task { await listener.installModel() } }
                Button("Annuler", role: .cancel) { listener.cancelInstall() }
            } message: {
                Text("Le modèle en \(ListenLanguage.name(listener.languageToInstall ?? ListenLanguage.current)) n'est pas encore sur cet appareil. Le système le télécharge une fois et le partage avec les autres apps ; la transcription se fait ensuite entièrement sur l'appareil.")
            }
            .alert("Écoute impossible", isPresented: Binding(get: { listener.errorMessage != nil }, set: { if !$0 { listener.errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(listener.errorMessage ?? "")
            }
            .alert("Écoute", isPresented: Binding(get: { listener.notice != nil && listener.errorMessage == nil }, set: { if !$0 { listener.notice = nil } })) {
                Button("OK") {}
            } message: {
                Text(listener.notice ?? "")
            }
            .alert("Résumé impossible", isPresented: Binding(get: { NoteSummaries.shared.errorMessage != nil }, set: { if !$0 { NoteSummaries.shared.errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(NoteSummaries.shared.errorMessage ?? "")
            }
    }
}

/// Réglages → Écoute: the language, what is heard, and what is kept once it ends.
struct ListenSettingsSection: View {
    @AppStorage(ListenLanguage.key) private var language = ListenLanguage.systemDefault
    @AppStorage(ListenSource.key) private var source = ListenSource.microphone
    @AppStorage(ListenPreferences.keepsAudioKey) private var keepsAudio = true
    @AppStorage(ListenPreferences.separatesVoicesKey) private var separatesVoices = true

    var body: some View {
        Section {
            Picker("Langue de la transcription", selection: $language) {
                ForEach(ListenLanguage.choices) { Text(verbatim: $0.name).tag($0.id) }
            }
            if ListenSource.choices.count > 1 {
                Picker("Entendre", selection: $source) {
                    ForEach(ListenSource.choices) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Text("Écoute")
        } footer: {
            Group {
                if Listener.isAvailable {
                    #if os(macOS)
                    Text("Ce qui est dit est écrit dans la note, sur l'appareil. Le son du Mac fait entendre un appel ou une vidéo ; l'écho des haut-parleurs dans le micro est retiré. Le bouton ondes de la note propose la langue et la source à chaque écoute.")
                    #else
                    Text("Ce qui est dit est écrit dans la note, sur l'appareil. Le bouton ondes de la note propose la langue à chaque écoute.")
                    #endif
                } else if Listener.systemIsRecent {
                    // The system is recent enough, the device has no transcriber (a simulator).
                    Text("Cet appareil ne propose pas la transcription d'Apple sur l'appareil.")
                } else {
                    #if os(macOS)
                    Text("L'écoute demande macOS 26 ou plus récent.")
                    #else
                    Text("L'écoute demande iOS 26 ou plus récent.")
                    #endif
                }
            }
            #if os(macOS)
            .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .disabled(!Listener.isAvailable)
        Section {
            Toggle(isOn: $keepsAudio) {
                Text("Garder l'enregistrement")
                #if os(macOS)
                Text("Joint à la note, au-dessus de la transcription : un fichier AAC léger, environ 12 Mo par heure.")
                #endif
            }
            if Voices.isAvailable {
                Toggle(isOn: $separatesVoices) {
                    Text("Séparer les voix")
                    #if os(macOS)
                    Text("À la fin de l'écoute, chaque voix est nommée dans la note : « Voix 1 », « Voix 2 »… ou « Moi » et « Eux » avec le son du Mac.")
                    #endif
                }
            }
        } header: {
            Text("Après l'écoute")
        } footer: {
            Group {
                #if os(macOS)
                Text("La séparation des voix se fait sur le Mac ; ses modèles (environ 20 Mo) sont téléchargés une fois, à la première écoute.")
                #else
                Text("Un fichier AAC léger, environ 12 Mo par heure, joint à la note et synchronisé : il s'écoute sur le Mac.")
                #endif
            }
            #if os(macOS)
            .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .disabled(!Listener.isAvailable)
        #if os(macOS)
        .toggleStyle(.switch)
        #endif
    }
}

#if os(macOS)
/// What a recording's card asks: its voices' names, whether to delete it.
private struct RecordingAlerts: ViewModifier {
    private let requests = RecordingRequests.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { requests.naming }, set: { requests.naming = $0 })) { naming in
                VoiceNamesSheet(naming: naming) { requests.naming = nil }
            }
            .alert("Supprimer l'enregistrement ?", isPresented: Binding(get: { requests.deleting != nil }, set: { if !$0 { requests.deleting = nil } })) {
                Button("Supprimer", role: .destructive) { requests.deleting?.confirm() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Le son quitte la note ; la transcription reste. Le fichier est effacé au prochain lancement.")
            }
    }
}
#endif
