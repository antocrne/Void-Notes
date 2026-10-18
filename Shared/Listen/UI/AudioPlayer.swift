#if os(macOS)
import AVFoundation
import SwiftUI

/// The recordings of the notes, played one at a time for the whole app. Opened from a
/// recording's card, the player shows at the foot of the note, where the listening bar is.
@MainActor @Observable
final class AudioPlayback {
    static let shared = AudioPlayback()

    /// The file open in the player — playing, or paused where it was; nil: the player is closed.
    private(set) var url: URL?
    /// The note it belongs to.
    private(set) var noteID: UUID?
    private(set) var isPlaying = false
    /// Where it is, in seconds.
    private(set) var time: TimeInterval = 0
    /// How long each file lasts, once read.
    private(set) var durations: [URL: TimeInterval] = [:]
    /// The voices of each file, once told apart in the player (`separateVoices`).
    private(set) var voices: [URL: [Voices.Turn]] = [:]
    /// The file whose voices are being told apart.
    private(set) var separating: URL?
    /// Why they couldn't be.
    var voicesError: String?
    /// The one voice played — the others skipped; nil: all of them.
    private(set) var onlyVoice: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var clock: Task<Void, Never>?

    /// Seconds the ±10 buttons move by.
    static let step: TimeInterval = 10

    /// "Écoute 2026-10-14 15h02", for "Écoute 2026-10-14 15h02.m4a".
    nonisolated static func title(_ name: String) -> String { (name as NSString).deletingPathExtension }

    var isOpen: Bool { url != nil }
    var duration: TimeInterval { url.flatMap { durations[$0] } ?? 0 }
    func isPlaying(_ url: URL) -> Bool { self.url == url && isPlaying }

    /// The turns of the voices of the file open, once told apart.
    var turns: [Voices.Turn]? { url.flatMap { voices[$0] } }
    /// Its voices, in the order they first speak.
    var voiceNames: [String] {
        var seen: [String] = []
        for turn in turns ?? [] where !seen.contains(turn.voice) { seen.append(turn.voice) }
        return seen
    }
    /// Who speaks at `seconds`, if anyone known.
    func speaker(at seconds: TimeInterval) -> String? {
        turns?.first { $0.start <= seconds && seconds < $0.end }?.voice
    }

    /// Tells apart the voices of the file open, on the device (the diarizer of the listenings).
    func separateVoices() {
        guard let url, voices[url] == nil, separating == nil, Voices.isAvailable else { return }
        separating = url
        voicesError = nil
        Task {
            do {
                voices[url] = try await Voices.find(in: url)
            } catch {
                voicesError = String(localized: "Les voix n'ont pas pu être séparées : \(error.localizedDescription)")
            }
            await Voices.release()
            separating = nil
        }
    }

    /// Plays only `voice` — skipping from one of its moments to the next —, or all (nil).
    func listen(only voice: String?) {
        onlyVoice = voice
        guard voice != nil, let player else { return }
        if spans(of: voice).last.map({ player.currentTime >= $0.end }) == true { seek(to: spans(of: voice)[0].start) }
        followVoice()
    }

    /// A voice's moments, those apart by less than `joined` taken as one (a breath isn't skipped).
    func spans(of voice: String?) -> [(start: TimeInterval, end: TimeInterval)] {
        var out: [(start: TimeInterval, end: TimeInterval)] = []
        for turn in turns ?? [] where turn.voice == voice {
            if let last = out.last, turn.start - last.end < Self.joined {
                out[out.count - 1].end = max(last.end, turn.end)
            } else {
                out.append((turn.start, turn.end))
            }
        }
        return out
    }

    static let joined: TimeInterval = 0.8

    #if DEBUG
    /// The self-test: voices as if told apart, without the diarizer.
    func pretendVoices(_ turns: [Voices.Turn]) {
        if let url { voices[url] = turns }
    }
    #endif

    /// With one voice played: out of its moments, on to the next — or, after its last, the end.
    private func followVoice() {
        guard let voice = onlyVoice, let player else { return }
        let spans = spans(of: voice)
        guard let first = spans.first else { return }
        let now = player.currentTime
        if spans.contains(where: { $0.start - 0.05 <= now && now < $0.end }) { return }
        if let next = spans.first(where: { $0.start > now }) {
            player.currentTime = next.start
            time = next.start
        } else {
            pause()
            player.currentTime = first.start
            time = first.start
        }
    }

    /// Reads how long the file lasts (without playing it).
    func loadDuration(of url: URL) async {
        guard durations[url] == nil else { return }
        let seconds = await Task.detached { () -> TimeInterval? in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }.value
        if let seconds { durations[url] = seconds }
    }

    /// The play button of a recording's card: opens the player on it and plays — or pauses, or
    /// plays on, when it is the one open.
    func toggle(_ url: URL, of note: UUID) {
        if self.url == url, player != nil {
            playPause()
        } else {
            open(url, of: note, playing: true)
        }
    }

    func playPause() {
        guard let player else { return }
        if player.isPlaying { pause() } else { resume() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        clock?.cancel()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: time + seconds)
    }

    /// To that moment of the file open — playing on if it was.
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        // Set right at the end, the player goes back to the start: it stops just before.
        let place = min(max(0, seconds), max(0, player.duration - 0.05))
        player.currentTime = place
        time = place
    }

    /// Opens the player on a file, paused at `seconds` (or playing).
    func open(_ url: URL, of note: UUID, at seconds: TimeInterval = 0, playing: Bool = false) {
        pause()
        if url != self.url { onlyVoice = nil }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        self.url = url
        noteID = note
        durations[url] = player.duration
        player.prepareToPlay()
        time = 0
        seek(to: seconds)
        if playing { resume() }
    }

    /// Closes the player.
    func close() {
        pause()
        player = nil
        url = nil
        noteID = nil
        onlyVoice = nil
        time = 0
    }

    /// The file is gone from its note: the player closes if it was open on it.
    func stop(_ url: URL) {
        if self.url == url { close() }
    }

    private func resume() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        // Its voice's last moment past: from its first.
        if onlyVoice != nil, let last = spans(of: onlyVoice).last, player.currentTime >= last.end {
            player.currentTime = spans(of: onlyVoice)[0].start
        }
        followVoice()
        guard player.play() else { return }
        isPlaying = true
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player = self.player else { return }
                self.followVoice()
                guard self.isPlaying else { return }
                self.time = player.currentTime
                if !player.isPlaying {
                    // The end: back to the start, ready to play again.
                    self.isPlaying = false
                    self.time = 0
                    player.currentTime = 0
                    return
                }
            }
        }
    }

    /// "1:05", "1:02:03".
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - The section of the note

/// Under the title, out of the text: the note's album of images, its recordings, then its tabs
/// once it has a transcript — each with the line that ends it (the recordings' is the tabs').
/// Shown in the place the text view keeps for the album.
struct NoteSections: View {
    let noteID: UUID
    let store: NoteStore

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }

    /// The room the sections take in the note.
    static func height(of note: Note) -> CGFloat {
        let tabs = NoteTabs.hasTabs(note)
        var parts: [CGFloat] = []
        if !note.photos.isEmpty { parts.append(NotePhotoAlbumSection.height) }
        if !note.recordings.isEmpty { parts.append(NoteRecordingsSection.height(ruled: !tabs)) }
        if tabs { parts.append(NoteTabBar.height) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * spacing
    }

    static let spacing: CGFloat = 14

    var body: some View {
        let tabs = note.map(NoteTabs.hasTabs) ?? false
        VStack(spacing: Self.spacing) {
            if note?.photos.isEmpty == false {
                NotePhotoAlbumSection(noteID: noteID, store: store)
                    .frame(height: NotePhotoAlbumSection.height)
            }
            if note?.recordings.isEmpty == false {
                NoteRecordingsSection(noteID: noteID, store: store, ruled: !tabs)
                    .frame(height: NoteRecordingsSection.height(ruled: !tabs))
            }
            if tabs {
                NoteTabBar(noteID: noteID, store: store)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The recordings of a note: a card for each, side by side, then a line. The card's play button
/// opens the player at the foot of the note.
struct NoteRecordingsSection: View {
    let noteID: UUID
    let store: NoteStore
    /// Ended by a line of its own — not when the tabs follow, theirs ends it.
    var ruled = true

    static let cardHeight: CGFloat = 34
    /// The cards, and the space under them and the line.
    static func height(ruled: Bool) -> CGFloat { cardHeight + (ruled ? 14 + 1 : 0) }

    private var note: Note? { store.note(noteID) ?? store.trashed(noteID) }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(note?.recordings ?? [], id: \.self) { name in
                        RecordingCard(noteID: noteID, store: store, name: name, canEdit: note?.deleted == nil && note?.isReadOnly == false)
                    }
                }
            }
            .frame(height: Self.cardHeight)
            if ruled {
                Rectangle()
                    .fill(Color(nsColor: Theme.dividerNS))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Enregistrements de la note")
    }
}

/// A recording, small: a play button and how long it lasts — its name shows on hover, so that
/// several sit side by side. Its menu (⋯, or a right click) names the voices of the note, shows
/// the file, or deletes it.
struct RecordingCard: View {
    let noteID: UUID
    let store: NoteStore
    let name: String
    let canEdit: Bool
    private let playback = AudioPlayback.shared
    @State private var hovering = false

    private var url: URL { store.attachmentsDirectory(of: noteID).appendingPathComponent(name) }
    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        let playing = playback.isPlaying(url)
        let open = playback.url == url
        HStack(spacing: 6) {
            Button { playback.toggle(url, of: noteID) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.accentFill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!exists)
            .help(playing ? "Pause" : "Lire")
            .accessibilityLabel(playing ? "Pause" : "Lire")
            Text(verbatim: detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(exists ? Theme.primaryText : Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
            Menu { menu } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Plus")
        }
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .frame(height: NoteRecordingsSection.cardHeight)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            Capsule()
                .fill(Color.gray.opacity(hovering ? 0.2 : 0.14))
                .overlay(Ring().fill(open ? Theme.accent.opacity(0.6) : .clear, style: FillStyle(eoFill: true)))
        }
        .contentShape(Capsule())
        // Its name, out of the way: the cards stay small, side by side.
        .help(Text(verbatim: AudioPlayback.title(name)))
        .contextMenu { menu }
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .task(id: url) { await playback.loadDuration(of: url) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: AudioPlayback.title(name)))
    }

    /// "3:00" — or, before the file has come from another device, "…".
    private var detail: String {
        guard exists else { return "…" }
        return playback.durations[url].map(AudioPlayback.clock) ?? "–:––"
    }

    @ViewBuilder private var menu: some View {
        Button(playback.isPlaying(url) ? "Pause" : "Lire", systemImage: playback.isPlaying(url) ? "pause" : "play") { playback.toggle(url, of: noteID) }
            .disabled(!exists)
        Button("Nommer les voix…", systemImage: "person.2") {
            let voices = Listener.shared.voices(in: noteID)
            guard !voices.isEmpty else { return }
            RecordingRequests.shared.naming = .init(voices: voices) { [noteID] names in Listener.shared.renameVoices(names, in: noteID) }
        }
        .disabled(!canEdit || Listener.shared.voices(in: noteID).isEmpty)
        Button("Afficher dans le Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .disabled(!exists)
        Divider()
        Button("Supprimer l'enregistrement…", systemImage: "trash", role: .destructive) {
            RecordingRequests.shared.deleting = .init { [url, name, noteID, store] in
                AudioPlayback.shared.stop(url)
                withAnimation(Theme.quick) { store.removeRecording(name, from: noteID) }
            }
        }
        .disabled(!canEdit)
    }
}

/// A capsule's outline one point wide, as a shape to fill: a stroked capsule drew stray lines
/// at its ends in the note.
private struct Ring: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        let inner = rect.insetBy(dx: 1, dy: 1)
        path.addRoundedRect(in: inner, cornerSize: CGSize(width: inner.height / 2, height: inner.height / 2))
        return path
    }
}

// MARK: - The player

/// At the foot of the note, where the listening bar is: the recording open — play and pause, ten
/// seconds back and forward, a line to go to any moment of it (drag the knob, or click on the
/// line), where it is and how long it lasts, and × to close it. Its name opens its note. On
/// demand, its voices told apart: who speaks now, where each speaks along the line, and one voice
/// played alone.
struct PlayerBar: View {
    let store: NoteStore
    let model: NotesModel
    private let playback = AudioPlayback.shared
    /// Where the knob is being dragged (0...1), before the sound goes there.
    @State private var dragging: Double?

    private var shown: TimeInterval { dragging.map { $0 * playback.duration } ?? playback.time }

    var body: some View {
        HStack(spacing: 6) {
            Button { playback.playPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accentFill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Pause" : "Lire")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Lire")
            plain("gobackward.10", help: "Reculer de 10 secondes") { playback.skip(by: -AudioPlayback.step) }
            plain("goforward.10", help: "Avancer de 10 secondes") { playback.skip(by: AudioPlayback.step) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    title
                    if let voice = playback.speaker(at: shown) {
                        VoiceTag(name: voice, color: VoiceColors.color(of: voice, in: playback.voiceNames))
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: "\(AudioPlayback.clock(shown)) / \(AudioPlayback.clock(playback.duration))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                }
                Timeline(fraction: playback.duration > 0 ? shown / playback.duration : 0, dragging: $dragging, voices: strip) { fraction in
                    playback.seek(to: fraction * playback.duration)
                }
                .frame(height: playback.turns == nil ? 12 : 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Position")
                .accessibilityValue(Text(verbatim: "\(AudioPlayback.clock(shown)) / \(AudioPlayback.clock(playback.duration))"))
                .accessibilityAdjustableAction { direction in
                    playback.skip(by: direction == .increment ? AudioPlayback.step : -AudioPlayback.step)
                }
            }
            .padding(.horizontal, 6)
            if Voices.isAvailable { voicesButton }
            plain("xmark", help: "Fermer le lecteur") { withAnimation(Theme.quick) { playback.close() } }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .frame(maxWidth: 520)
        // The floating look of the listening bar.
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                .shadow(color: Theme.shadow.opacity(0.14), radius: 8, y: 2)
        }
        .tint(Theme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lecteur")
    }

    /// Before the voices are told apart, a button that does it; then the menu that picks the
    /// voice heard — all, or one alone.
    @ViewBuilder private var voicesButton: some View {
        if playback.separating != nil, playback.separating == playback.url {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .help(Voices.hasModels ? "Séparation des voix…" : "Téléchargement du modèle des voix…")
                .accessibilityLabel(Voices.hasModels ? "Séparation des voix…" : "Téléchargement du modèle des voix…")
        } else if playback.turns == nil {
            plain("person.2", help: "Séparer les voix") { playback.separateVoices() }
                .popover(isPresented: Binding(get: { playback.voicesError != nil }, set: { if !$0 { playback.voicesError = nil } })) {
                    Text(verbatim: playback.voicesError ?? "")
                        .font(.callout)
                        .padding(12)
                        .frame(width: 260)
                        .fixedSize(horizontal: false, vertical: true)
                }
        } else {
            let names = playback.voiceNames
            Menu {
                if names.count < 2 {
                    Text("Une seule voix entendue")
                } else {
                    Toggle("Toutes les voix", isOn: Binding(get: { playback.onlyVoice == nil }, set: { if $0 { playback.listen(only: nil) } }))
                    Divider()
                    ForEach(names, id: \.self) { name in
                        Toggle(isOn: Binding(get: { playback.onlyVoice == name }, set: { playback.listen(only: $0 ? name : nil) })) {
                            Text("Seulement \(name)")
                        }
                    }
                }
            } label: {
                Image(systemName: playback.onlyVoice == nil ? "person.2.fill" : "person.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(playback.onlyVoice.map { VoiceColors.color(of: $0, in: names) } ?? Theme.accent)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Voix")
            .accessibilityLabel("Voix")
            .accessibilityValue(Text(verbatim: playback.onlyVoice ?? String(localized: "Toutes les voix")))
        }
    }

    /// The voices along the line: where each speaks, those not played dimmed.
    private var strip: [Timeline.Voice] {
        guard let turns = playback.turns, playback.duration > 0 else { return [] }
        let names = playback.voiceNames
        return turns.map { turn in
            Timeline.Voice(start: turn.start / playback.duration, end: turn.end / playback.duration,
                           color: VoiceColors.color(of: turn.voice, in: names),
                           played: playback.onlyVoice == nil || playback.onlyVoice == turn.voice)
        }
    }

    /// The recording's name — and, when it isn't of the note shown, a click goes to its note.
    @ViewBuilder private var title: some View {
        let name = Text(verbatim: playback.url.map { AudioPlayback.title($0.lastPathComponent) } ?? "")
            .font(.system(size: 12, weight: .semibold))
        if let id = playback.noteID, id != model.selectedID, store.note(id) != nil {
            Button { model.open(id) } label: { name.foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.middle) }
                .buttonStyle(.plain)
                .help("Ouvrir la note")
        } else {
            name.foregroundStyle(Theme.primaryText).lineLimit(1).truncationMode(.middle)
        }
    }

    private func plain(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The line of a recording: what is played in the accent, a knob where it is. A click goes there;
/// the knob follows a drag, and the sound goes where it is let go.
private struct Timeline: View {
    /// Where a voice speaks, from 0 to 1 along the line.
    struct Voice {
        var start: Double
        var end: Double
        var color: Color
        var played: Bool
    }

    let fraction: Double
    @Binding var dragging: Double?
    var voices: [Voice] = []
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let at = min(max(dragging ?? fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.secondaryText.opacity(0.25)).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: max(4, width * at), height: 4)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: dragging == nil ? 10 : 13, height: dragging == nil ? 10 : 13)
                    .offset(x: width * at - (dragging == nil ? 5 : 6.5))
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) {
                if !voices.isEmpty {
                    ZStack(alignment: .leading) {
                        ForEach(voices.indices, id: \.self) { index in
                            let voice = voices[index]
                            Capsule()
                                .fill(voice.color.opacity(voice.played ? 0.9 : 0.25))
                                .frame(width: max(2, width * (voice.end - voice.start)), height: 3)
                                .offset(x: width * voice.start)
                        }
                    }
                    .frame(width: width, height: 3, alignment: .leading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(max($0.location.x / width, 0), 1) }
                    .onEnded {
                        seek(min(max($0.location.x / width, 0), 1))
                        dragging = nil
                    }
            )
            .animation(Theme.quick, value: dragging == nil)
        }
    }
}

/// Each voice its colour, in the order they first speak.
enum VoiceColors {
    @MainActor static func color(of voice: String, in names: [String]) -> Color {
        let palette: [Color] = [Theme.accent, .orange, .teal, .pink, .green, .yellow, .cyan, .brown]
        return palette[(names.firstIndex(of: voice) ?? 0) % palette.count]
    }
}

/// The voice speaking now, beside the recording's name.
private struct VoiceTag: View {
    let name: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - What a recording asks

/// What a recording's card asks, shown by the window (`ListeningAlerts`).
@MainActor @Observable
final class RecordingRequests {
    static let shared = RecordingRequests()

    struct Naming: Identifiable {
        let id = UUID()
        var voices: [String]
        var apply: ([String: String]) -> Void
    }

    struct Deleting: Identifiable {
        let id = UUID()
        var confirm: () -> Void
    }

    var naming: Naming?
    var deleting: Deleting?
}

/// « Nommer les voix » : a field per voice of the note, its name as it is now.
struct VoiceNamesSheet: View {
    let naming: RecordingRequests.Naming
    let done: () -> Void
    @State private var names: [String]

    init(naming: RecordingRequests.Naming, done: @escaping () -> Void) {
        self.naming = naming
        self.done = done
        _names = State(initialValue: naming.voices)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nommer les voix").font(.headline)
            Text("Chaque nom change partout dans la note.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(naming.voices.indices, id: \.self) { index in
                    GridRow {
                        Text(verbatim: naming.voices[index]).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        TextField(text: $names[index], prompt: Text(verbatim: naming.voices[index])) { Text(verbatim: naming.voices[index]) }
                            .labelsHidden()
                            .frame(width: 220)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { done() }
                    .keyboardShortcut(.cancelAction)
                Button("Renommer") { apply() }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .tint(Theme.accent)
    }

    private func apply() {
        var renamed: [String: String] = [:]
        for (old, new) in zip(naming.voices, names) {
            let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if !new.isEmpty, new != old { renamed[old] = new }
        }
        if !renamed.isEmpty { naming.apply(renamed) }
        done()
    }
}
#endif
