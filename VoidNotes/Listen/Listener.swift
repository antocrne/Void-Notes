import Foundation
import Observation
import Speech
import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

/// Listening to what is said and writing it in a note, as it is said.
///
/// The words go to the note's transcript — apart from what is written in it, in a tab of its own
/// (`NotePart`) —, after a line that says when the listening began: one can go on writing in the
/// note meanwhile, nothing gets mixed. Each sentence is written once it is final: saved, searched
/// and synchronised like the rest. What is heard: the microphone, the Mac's sound (a call, a
/// video), or both — each with its own transcriber, the microphone's echo of the speakers taken
/// out.
///
/// Once it ends, the voices are told apart and named in the transcript, and the sound —
/// compressed, one file — is joined to the note, under its title. Everything happens on the
/// device.
@MainActor @Observable
final class Listener {
    static let shared = Listener(store: .shared)

    enum Phase: Equatable {
        case idle
        case preparing
        /// The language's model is being downloaded (fraction done), before the listening starts.
        case downloading(Double)
        case listening
        case finishing
        /// The listening is over; its voices are told apart, its sound joined to the note.
        case saving(Saving)
    }

    enum Saving: Equatable {
        /// The voices' models are downloaded, the first time.
        case voicesModel
        case voices
        case audio
    }

    private(set) var phase: Phase = .idle
    /// The note the words go to.
    private(set) var noteID: UUID?
    private(set) var startedAt: Date?
    /// What is heard, and in which language (the session's own, whatever the settings say since).
    private(set) var source: ListenSource = .microphone
    private(set) var language = ListenLanguage.systemDefault
    /// The last loudness levels heard, oldest first: the meter.
    private(set) var levels: [Float] = Array(repeating: 0, count: Listener.meterCount)
    /// The words being said, not final yet.
    private(set) var words = ""
    /// iPhone: a call or another app took the microphone; the listening goes on once it is back.
    private(set) var isInterrupted = false
    /// Why the listening couldn't start or go on.
    var errorMessage: String?
    /// Something that went wrong without stopping the listening (the Mac's sound unheard, the
    /// voices not told apart).
    var notice: String?
    /// The language whose model is missing: whether to download it is asked.
    var languageToInstall: String?

    static let meterCount = 5

    @ObservationIgnored private let store: NoteStore
    /// `ListeningSession`, on systems that have it.
    @ObservationIgnored private var session: AnyObject?
    @ObservationIgnored private var flow = TranscriptFlow()
    @ObservationIgnored private var queue = SentenceQueue(holds: false, locale: Locale(identifier: "fr-FR"))
    /// The sentences written, in order: whose voice each is, once the listening ends.
    @ObservationIgnored private var written: [HeardSentence] = []
    @ObservationIgnored private var volatile: [ListenChannel: String] = [:]
    /// The text view of the note on screen, and the place the words go in it when it shows the
    /// transcript.
    @ObservationIgnored private weak var host: TranscriptHost?
    @ObservationIgnored private var hostNote: UUID?
    @ObservationIgnored private var anchor = 0
    /// Where this listening's words began in the transcript: its sentences are looked for from
    /// there once it ends.
    @ObservationIgnored private var startPlace = 0
    @ObservationIgnored private var editObserver: NSObjectProtocol?
    @ObservationIgnored private var isWriting = false
    /// Sentences waiting while characters are being composed in the note.
    @ObservationIgnored private var waiting: [(text: String, newParagraph: Bool)] = []
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var meter: Task<Void, Never>?
    /// The note to listen in once the model is downloaded.
    @ObservationIgnored private var noteAfterInstall: UUID?

    init(store: NoteStore) {
        self.store = store
    }

    /// This device can listen: macOS 26 or iOS 26, with Apple's on-device transcription.
    static var isAvailable: Bool {
        if #available(macOS 26, iOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    var isActive: Bool { phase != .idle }

    /// Listening, or about to: what the note's button stops.
    var isListening: Bool {
        switch phase {
        case .preparing, .downloading, .listening, .finishing: true
        case .idle, .saving: false
        }
    }

    func isListening(to id: UUID?) -> Bool { id != nil && noteID == id && isListening }

    /// Whether a note can be listened in: written here, not in the trash.
    func canListen(in note: Note?) -> Bool {
        guard Self.isAvailable, let note else { return false }
        return !note.isReadOnly && note.deleted == nil
    }

    /// Starts listening in that note, as last time — or stops, if listening already.
    func toggle(in id: UUID?) {
        if isListening {
            Task { await stop() }
        } else if phase == .idle, let id {
            Task { await start(in: id) }
        }
    }

    // MARK: Start and stop

    /// Starts listening in the note, in `language` and to `source` — chosen from now on — or as
    /// the settings say.
    func start(in id: UUID, language chosen: String? = nil, source picked: ListenSource? = nil) async {
        guard #available(macOS 26, iOS 26, *), phase == .idle, canListen(in: store.note(id)) else { return }
        if let chosen { UserDefaults.standard.set(chosen, forKey: ListenLanguage.key) }
        if let picked { UserDefaults.standard.set(picked.rawValue, forKey: ListenSource.key) }
        phase = .preparing
        errorMessage = nil
        notice = nil
        let language = ListenLanguage.current
        let source = ListenSource.current
        // The sound is written if it is kept, or if its voices are to be told apart.
        let records = ListenPreferences.keepsAudio || (ListenPreferences.separatesVoices && Voices.isAvailable)
        let folder = Recording.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let locale = try await SpeechModel.ready(language)
            if source != .mac {
                guard await Microphone.requestAccess() else { throw ListenError.microphoneDenied }
            }
            let session = try await ListeningSession.start(
                locale: locale, source: source, recordings: records ? folder : nil,
                onFinal: { [weak self] channel, text, start, end in self?.heard(HeardSentence(channel: channel, text: text, start: start, end: end)) },
                onVolatile: { [weak self] channel, text in self?.saying(text, on: channel) },
                warning: { [weak self] error in
                    self?.notice = error.localizedDescription + (source == .mac ? "" : " " + String(localized: "L'écoute continue avec le micro."))
                }
            )
            // The note went meanwhile (deleted on another device).
            guard store.note(id) != nil else {
                await session.cancel()
                try? FileManager.default.removeItem(at: folder)
                phase = .idle
                return
            }
            self.session = session
            self.language = language
            self.source = source
            noteID = id
            startedAt = .now
            flow = TranscriptFlow()
            queue = SentenceQueue(holds: session.channels.count > 1, locale: locale)
            written = []
            volatile = [:]
            words = ""
            phase = .listening
            ListeningLedger.item = ListeningLedger.Item(note: id, files: session.recordings.values.map(\.path), started: .now)
            begin(in: id)
            startMeter()
            watchSession()
            if ListenPreferences.separatesVoices, Voices.isAvailable, !Voices.hasModels { Task { await Voices.fetchModels() } }
            announce(String(localized: "Écoute commencée"))
        } catch ListenError.notInstalled(let language) {
            phase = .idle
            noteAfterInstall = id
            languageToInstall = language
        } catch {
            try? FileManager.default.removeItem(at: folder)
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    /// Stops listening: the last words are written, the microphone let go; then the voices are
    /// told apart and the sound joined to the note. `quitting`: the app is about to go — the
    /// sound is joined at the next launch, without the voices.
    func stop(quitting: Bool = false) async {
        guard #available(macOS 26, iOS 26, *), phase == .listening, let session = session as? ListeningSession, let id = noteID else { return }
        phase = .finishing
        meter?.cancel()
        unwatchSession()
        resuming?.cancel()
        await session.stop()
        release(all: true)
        flushWaiting(force: true)
        announce(String(localized: "Écoute terminée"))
        if !session.macWasHeard, let start = startedAt, Date.now.timeIntervalSince(start) > 20 {
            notice = ListenError.macSilent.localizedDescription
        }
        let recordings = session.recordings
        let sentences = written, from = startPlace
        end()
        if quitting { return store.flush() }
        await save(id, sentences: sentences, from: from, recordings: recordings)
    }

    /// What is left of the listening of `id` after the last sentence: the voices' names, then
    /// the sound, in the note. The recordings go afterwards, joined or not.
    private func save(_ id: UUID, sentences: [HeardSentence], from: Int, recordings: [ListenChannel: URL]) async {
        noteID = id
        defer {
            for url in recordings.values { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            ListeningLedger.item = nil
            noteID = nil
            phase = .idle
            store.flush()
        }
        var microphone: [Voices.Turn]?, mac: [Voices.Turn]?
        if ListenPreferences.separatesVoices, Voices.isAvailable, sentences.count > 1 {
            phase = .saving(Voices.hasModels ? .voices : .voicesModel)
            do {
                if let url = recordings[.microphone], recordings[.mac] == nil { microphone = try await Voices.find(in: url) }
                if let url = recordings[.mac] { mac = try await Voices.find(in: url) }
            } catch {
                notice = String(localized: "Les voix n'ont pas pu être séparées : \(error.localizedDescription)")
            }
            await Voices.release()
        }
        let speakers = Voices.speakers(of: sentences, microphone: microphone, mac: mac)
        if store.note(id) != nil, speakers.contains(where: { $0 != nil }) { name(sentences.map(\.text), speakers, in: id, from: from) }

        guard ListenPreferences.keepsAudio, !recordings.isEmpty else { return }
        phase = .saving(.audio)
        await join(Array(recordings.values), to: id)
    }

    /// The sound of a listening, made one `.m4a`, added to the note's recordings — out of the
    /// text, in their section under the title.
    private func join(_ files: [URL], to id: UUID) async {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.audioName()).m4a")
        defer { try? FileManager.default.removeItem(at: target) }
        // Microphone first: its file is the one kept as it is when it is alone.
        let sources = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let made = await Task.detached { try? Recording.finish(sources, to: target) }.value
        guard let made, store.note(id) != nil else { return }
        store.addRecordings([made], to: id)
    }

    /// "Écoute 2026-10-14 15h02".
    private static func audioName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH'h'mm"
        return String(localized: "Écoute \(formatter.string(from: .now))")
    }

    /// The voices' names before the sentences that change voice.
    private func name(_ sentences: [String], _ speakers: [String?], in id: UUID, from: Int) {
        edit(id, part: .transcript) { text in
            TranscriptText.labels(for: sentences, speakers: speakers, in: text.string as NSString, from: from)
                .map { (NSRange(location: $0.location, length: 0), Self.piece(for: $0)) }
        }
    }

    /// "Voix 1 : ", the name in bold.
    static func piece(for label: TranscriptText.Label) -> NSAttributedString {
        let body = NoteFormat.attributes(block: nil)
        let piece = NSMutableAttributedString(string: label.newLine ? "\n" : "", attributes: body)
        var bold = body
        bold[NoteFormat.boldKey] = true
        bold[.font] = NoteFormat.font(block: nil, weight: .bold, italic: false)
        piece.append(NSAttributedString(string: label.speaker, attributes: bold))
        // French puts a space before the colon; the space after is the one already there, if any.
        piece.append(NSAttributedString(string: String(localized: " :") + (label.spaceFollows ? "" : " "), attributes: body))
        return piece
    }

    /// Puts `content` in place of a part of the note: in its text view if it shows it, in one step
    /// of ⌘Z; else in the note saved.
    func replace(_ id: UUID, part: NotePart, with content: NoteContent) {
        if shownHost(for: id, part: part) != nil {
            let piece = NoteFormat.attributedString(from: content, attachments: store.attachmentsDirectory(of: id))
            edit(id, part: part) { [(NSRange(location: 0, length: $0.length), piece)] }
        } else {
            store.update(id, part: part, content: content)
        }
    }

    /// The voices named in the note's transcript (« Voix 1 », « Moi »…), in order — or in its own
    /// text, where an earlier beta wrote them.
    func voices(in id: UUID) -> [String] {
        RecordingText.voices(in: text(of: id, part: store.note(id)?.transcript != nil ? .transcript : .notes)).map(\.name)
    }

    /// Renames voices everywhere in the note — its transcript, its own text, its summary (where
    /// the names aren't in bold): old name → new one.
    func renameVoices(_ names: [String: String], in id: UUID) {
        edit(id, part: .transcript) { RecordingText.renaming(names, in: $0) }
        edit(id, part: .notes) { RecordingText.renaming(names, in: $0) }
        edit(id, part: .summary) { RecordingText.renamingWords(names, in: $0) }
    }

    /// A part of the note as it is: in its text view if it shows it.
    func text(of id: UUID, part: NotePart = .notes) -> NSAttributedString {
        if let host = shownHost(for: id, part: part), let storage = host.transcriptStorage {
            let start = TranscriptText.partStart(of: part, in: storage.string as NSString)
            return storage.attributedSubstring(from: NSRange(location: start, length: storage.length - start))
        }
        guard let note = store.note(id) else { return NSAttributedString() }
        return NoteFormat.attributedString(from: note.content(of: part) ?? NoteContent(), attachments: store.attachmentsDirectory(of: id))
    }

    /// Replaces ranges of the note: in its text view if it is on screen (one step of undo, the
    /// cursor left where it is), else in the note saved.
    func edit(_ id: UUID, part: NotePart = .notes, _ edits: (NSAttributedString) -> [(NSRange, NSAttributedString)]) {
        if let host = shownHost(for: id, part: part), let storage = host.transcriptStorage {
            let start = TranscriptText.partStart(of: part, in: storage.string as NSString)
            let text = storage.attributedSubstring(from: NSRange(location: start, length: storage.length - start))
            let changes = edits(text).filter { $0.0.upperBound <= text.length }
                .map { (NSRange(location: $0.0.location + start, length: $0.0.length), $0.1) }
            guard !changes.isEmpty else { return }
            isWriting = true
            host.editRecording(changes)
            isWriting = false
        } else if let note = store.note(id), !note.isReadOnly, let content = note.content(of: part) {
            let text = NoteFormat.attributedString(from: content, attachments: store.attachmentsDirectory(of: id))
            let changes = edits(text).filter { $0.0.upperBound <= text.length }
            guard !changes.isEmpty else { return }
            for (range, piece) in changes.sorted(by: { $0.0.location > $1.0.location }) { text.replaceCharacters(in: range, with: piece) }
            store.update(id, part: part, content: NoteFormat.content(from: text))
        }
    }

    /// At launch: the recordings an earlier beta wrote in the text of the notes go to their
    /// section, their lines out of the text.
    func moveRecordingsOutOfText() {
        for note in store.notes where !note.isReadOnly && note.attachments.contains(where: RecordingText.isAudio) {
            let text = text(of: note.id)
            let found = RecordingText.recordings(in: text)
            guard !found.isEmpty else { continue }
            edit(note.id) { text in
                RecordingText.recordings(in: text).map { (RecordingText.removal(at: $0.location, in: text), NSAttributedString()) }
            }
            store.adoptRecordings(found.map(\.name), in: note.id)
        }
    }

    private func end() {
        session = nil
        startedAt = nil
        words = ""
        volatile = [:]
        written = []
        levels = Array(repeating: 0, count: Self.meterCount)
        isInterrupted = false
        retry?.cancel()
        waiting = []
        detach()
        noteID = nil
        phase = .idle
        store.flush()
    }

    /// At launch: a listening cut short (the app killed, a crash) gives its note its sound, at its
    /// end — without the voices.
    func recoverInterrupted() async {
        guard let item = ListeningLedger.item, phase == .idle else { return }
        ListeningLedger.item = nil
        let files = item.files.map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        if ListenPreferences.keepsAudio, !files.isEmpty, store.note(item.note) != nil {
            await join(files, to: item.note)
        }
        for folder in Set(files.map { $0.deletingLastPathComponent() }) { try? FileManager.default.removeItem(at: folder) }
    }

    #if DEBUG
    /// Debug builds only: a listening with no sound behind it, to check where the words go
    /// (the self-test).
    func pretend(in id: UUID, words: String = "", levels: [Float]? = nil, startedAt: Date = .now, holds: Bool = false) {
        noteID = id
        self.startedAt = startedAt
        flow = TranscriptFlow()
        queue = SentenceQueue(holds: holds, locale: Locale(identifier: "fr-FR"))
        written = []
        phase = .listening
        begin(in: id)
        self.words = words
        if let levels { self.levels = levels }
    }

    func pretendHeard(_ text: String, from start: TimeInterval, to end: TimeInterval, on channel: ListenChannel = .microphone) {
        heard(HeardSentence(channel: channel, text: text, start: start, end: end))
    }

    /// Ends a pretended listening as `stop` would: the voices named after `speakers` (one per
    /// sentence written), the sound in `files` joined.
    func endPretending(speakers: [String?]? = nil, files: [URL] = []) async {
        guard let id = noteID else { return }
        release(all: true)
        flushWaiting(force: true)
        let sentences = written, from = startPlace
        end()
        noteID = id
        if let speakers { name(sentences.map(\.text), speakers, in: id, from: from) }
        if !files.isEmpty { await join(files, to: id) }
        noteID = nil
    }

    var pretendedWritten: [HeardSentence] { written }
    #endif

    // MARK: Model download

    /// Downloads the missing model, then starts listening in the note it was asked for.
    func installModel() async {
        guard #available(macOS 26, iOS 26, *), let language = languageToInstall, phase == .idle else { return }
        languageToInstall = nil
        phase = .downloading(0)
        var watcher: Task<Void, Never>?
        do {
            try await SpeechModel.install(language) { [weak self] progress in
                watcher = Task { @MainActor [weak self] in
                    while !Task.isCancelled, case .downloading = self?.phase {
                        self?.phase = .downloading(progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            watcher?.cancel()
            phase = .idle
            if let id = noteAfterInstall { await start(in: id) }
        } catch {
            watcher?.cancel()
            phase = .idle
            errorMessage = error.localizedDescription
        }
        noteAfterInstall = nil
    }

    func cancelInstall() {
        languageToInstall = nil
        noteAfterInstall = nil
    }

    // MARK: Writing

    /// A note's text view was made (the note was opened, or shown anew): if it is the note
    /// listened to, the words go on in it — at its end, when it comes back.
    func register(_ host: TranscriptHost, for id: UUID) {
        self.host = host
        hostNote = id
        detachObserver()
        guard isListening(to: id), host.shownPart == .transcript, let storage = host.transcriptStorage else { return }
        anchor = storage.length
        flow.breaks = true
        observe(storage)
    }

    /// The listening begins: in a note that is empty, a title says when; in the transcript, a
    /// line says it too, and the words go after it. The transcript's tab opens.
    private func begin(in id: UUID) {
        if store.note(id)?.isBlank == true {
            let title = NSAttributedString(string: Self.title(), attributes: NoteFormat.attributes(block: .title))
            if let host = shownHost(for: id, part: .notes), host.transcriptStorage?.length == 0 {
                isWriting = true
                host.insertTranscript(title, at: 0)
                isWriting = false
            } else {
                store.update(id, content: NoteFormat.content(from: title))
            }
        }
        let line = NSMutableAttributedString(string: "", attributes: NoteFormat.attributes(block: nil))
        let marker = NSAttributedString(string: Self.title(), attributes: NoteFormat.attributes(block: .subheading))
        if let host = shownHost(for: id), let storage = host.transcriptStorage {
            observe(storage)
            let start = TranscriptText.partStart(of: .transcript, in: storage.string as NSString)
            if storage.length > start, !storage.string.hasSuffix("\n") { line.append(NSAttributedString(string: "\n", attributes: NoteFormat.attributes(block: nil))) }
            line.append(marker)
            anchor = storage.length
            write(line, in: host)
            startPlace = storage.length - start
        } else if let note = store.note(id) {
            var transcript = note.transcript ?? NoteContent()
            if !transcript.text.isEmpty, !transcript.text.hasSuffix("\n") { line.append(NSAttributedString(string: "\n", attributes: NoteFormat.attributes(block: nil))) }
            line.append(marker)
            transcript = transcript + NoteFormat.content(from: line)
            store.update(id, part: .transcript, content: transcript)
            startPlace = (transcript.text as NSString).length
        }
        NoteTabs.shared.show(.transcript, in: id)
    }

    /// "Écoute du 14 oct. 2026 à 15:02".
    private static func title() -> String {
        String(localized: "Écoute du \(Date.now.formatted(date: .abbreviated, time: .omitted)) à \(Date.now.formatted(date: .omitted, time: .shortened))")
    }

    /// Words in flight on a source: the bar shows the latest.
    private func saying(_ text: String, on channel: ListenChannel) {
        volatile[channel] = text
        words = text.isEmpty ? volatile.values.first { !$0.isEmpty } ?? "" : text
    }

    /// A sentence is final: it waits its turn, with two sources.
    private func heard(_ sentence: HeardSentence) {
        guard noteID != nil, phase == .listening || phase == .finishing else { return }
        queue.add(sentence, at: ProcessInfo.processInfo.systemUptime)
        release()
    }

    /// The sentences whose turn has come go to the note.
    private func release(all: Bool = false) {
        let ready = queue.release(at: ProcessInfo.processInfo.systemUptime, all: all)
        guard !ready.isEmpty else { return }
        for sentence in ready {
            waiting.append((sentence.text, flow.startsParagraph(sentence.text, from: sentence.start, to: sentence.end, channel: sentence.channel)))
            written.append(sentence)
        }
        flushWaiting(force: all)
    }

    /// Writes the sentences waiting: in the text view of the note if it shows the transcript, else
    /// at the end of the transcript saved. While characters are composed in the text view, they wait a moment.
    private func flushWaiting(force: Bool = false) {
        guard let id = noteID, !waiting.isEmpty else { return }
        guard store.note(id) != nil else {
            // Deleted, or put in the trash: there is nowhere to write.
            waiting = []
            if phase == .listening { Task { await stop() } }
            return
        }
        if let host = shownHost(for: id), let storage = host.transcriptStorage {
            if host.isComposing, !force {
                retry?.cancel()
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    if !Task.isCancelled { self?.flushWaiting() }
                }
                return
            }
            for sentence in waiting {
                anchor = min(anchor, storage.length)
                let piece = TranscriptText.piece(sentence.text, at: anchor, in: storage.string as NSString, newParagraph: sentence.newParagraph)
                write(NSAttributedString(string: piece, attributes: NoteFormat.attributes(block: nil)), in: host)
            }
        } else if let note = store.note(id) {
            var content = note.transcript ?? NoteContent()
            for sentence in waiting {
                // Plain text at the end needs no formatting run.
                content.text += TranscriptText.piece(sentence.text, at: (content.text as NSString).length, in: content.text as NSString, newParagraph: sentence.newParagraph)
            }
            store.update(id, part: .transcript, content: content)
        }
        waiting = []
    }

    private func write(_ text: NSAttributedString, in host: TranscriptHost) {
        isWriting = true
        host.insertTranscript(text, at: anchor)
        isWriting = false
        anchor += text.length
    }

    /// The text view of the note, if it is on screen and shows `part`.
    private func shownHost(for id: UUID, part: NotePart = .transcript) -> TranscriptHost? {
        guard let host, hostNote == id, host.isShown, host.shownPart == part else { return nil }
        return host
    }

    /// What is typed or deleted in the note moves the place the words go.
    private func observe(_ storage: NSTextStorage) {
        detachObserver()
        editObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let edited = storage.editedRange, delta = storage.changeInLength
            MainActor.assumeIsolated {
                guard let self, !self.isWriting else { return }
                self.anchor = min(TranscriptText.anchor(self.anchor, afterEditing: edited, delta: delta), storage.length)
                // `startPlace` is in the transcript, after the title the tab shows: the title's
                // edits don't move it.
                let start = TranscriptText.partStart(of: .transcript, in: storage.string as NSString)
                guard edited.location >= start else { return }
                self.startPlace = max(0, min(TranscriptText.anchor(self.startPlace + start, afterEditing: edited, delta: delta), storage.length) - start)
            }
        }
    }

    private func detachObserver() {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        editObserver = nil
    }

    private func detach() {
        detachObserver()
        anchor = 0
    }

    // MARK: Meter

    /// About eight times a second, the loudness joins the meter — and the sentences held for the
    /// other source go to the note when their turn comes. Silence that goes on doesn't redraw
    /// anything.
    private func startMeter() {
        meter?.cancel()
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(125))
                guard let self, self.phase == .listening else { return }
                if !self.queue.isEmpty { self.release() }
                let level: Float
                if #available(macOS 26, iOS 26, *), !self.isInterrupted, let session = self.session as? ListeningSession {
                    level = session.level
                } else {
                    level = 0
                }
                if level < 0.02, self.levels.allSatisfy({ $0 < 0.02 }) { continue }
                self.levels = Array(self.levels.dropFirst()) + [level]
            }
        }
    }

    // MARK: Accessibility

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Interruptions

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var resuming: Task<Void, Never>?

    /// The input can change under the listening (a headset, the Mac waking up): the engine stops
    /// by itself and says so, and is started again on the new input. On the iPhone a call, Siri
    /// or another app can also take the microphone, and iOS stops it without a word: without
    /// these, the bar would say « À l'écoute » while nothing more is heard.
    private func watchSession() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
        #if os(iOS)
        observers += [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    switch type {
                    case .began: self?.interrupted()
                    case .ended: self?.resume()
                    default: break
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
        ]
        #endif
    }

    private func unwatchSession() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    #if os(iOS)
    private func interrupted() {
        guard #available(iOS 26, *), phase == .listening, !isInterrupted else { return }
        isInterrupted = true
        resuming?.cancel()
        words = ""
        if let session = session as? ListeningSession { Task { await session.settle() } }
        announce(String(localized: "Écoute interrompue"))
    }
    #endif

    /// Seconds between tries: iOS often refuses the microphone for a few seconds after a call.
    private static let retryDelays: [Double] = [1, 2, 3, 5, 10]

    /// Takes the microphone back — when the system says it is free, when the input changed, or
    /// when « Reprendre » is pressed. Does nothing while sound comes in.
    func resume() {
        guard #available(macOS 26, iOS 26, *), phase == .listening, let session = session as? ListeningSession,
              isInterrupted || !session.isHearing else { return }
        resuming?.cancel()
        if takeBack(session) { return }
        resuming = Task { [weak self] in
            #if os(iOS)
            // Once nothing records, iOS suspends the app within seconds, and the tries with it.
            let application = UIApplication.shared
            var time = UIBackgroundTaskIdentifier.invalid
            time = application.beginBackgroundTask(withName: "Reprise de l'écoute") {
                application.endBackgroundTask(time)
                time = .invalid
            }
            defer { if time != .invalid { application.endBackgroundTask(time) } }
            #endif
            for delay in Self.retryDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.phase == .listening else { return }
                if self.takeBack(session) { return }
            }
        }
    }

    @available(macOS 26, iOS 26, *)
    private func takeBack(_ session: ListeningSession) -> Bool {
        do {
            try session.resume()
        } catch {
            if !isInterrupted {
                isInterrupted = true
                announce(String(localized: "Écoute interrompue"))
            }
            return false
        }
        if isInterrupted {
            isInterrupted = false
            announce(String(localized: "Écoute reprise"))
        }
        flow.breaks = true
        return true
    }
}
