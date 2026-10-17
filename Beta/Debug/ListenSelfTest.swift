#if DEBUG && os(macOS)
import AppKit
import AVFoundation
import SwiftUI

/// Debug builds of the beta only: the listening's part of `-selfTest YES`. Where the words go
/// (pure rules, then in a real text view, then in a note that isn't shown), and once from end to
/// end: a French voice, synthesised, played in place of the microphone, transcribed on the Mac.
@MainActor
enum ListenSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  (\(detail()))")")
        if !ok { failures += 1 }
    }

    static func run() async -> Int {
        // `VOID_SUMMARY_ONLY=1`: the real summary alone, to try the instructions.
        if ProcessInfo.processInfo.environment["VOID_SUMMARY_ONLY"] != nil {
            await summaryLive()
            return failures
        }
        rules()
        flow()
        echo()
        voices()
        await textView()
        await noteNotShown()
        await named()
        await recording()
        await player()
        await endToEnd()
        await separation()
        summaryText()
        await summaryLive()
        return failures
    }

    // MARK: Rules

    private static func rules() {
        let piece = { (text: String, at: Int, paragraph: Bool) in
            TranscriptText.piece("Phrase.", at: at, in: text as NSString, newParagraph: paragraph)
        }
        check("Écoute : note vide, la phrase seule", piece("", 0, true) == "Phrase.")
        check("Écoute : après un paragraphe, une ligne à elle", piece("Titre", 5, true) == "\nPhrase.")
        check("Écoute : à la suite, une espace", piece("Bonjour.", 8, false) == " Phrase.")
        check("Écoute : après une espace, rien de plus", piece("Bonjour ", 8, false) == "Phrase.")
        check("Écoute : sur une ligne vide, rien de plus", piece("Titre\n", 6, true) == "Phrase.")
        check("Écoute : la fin du paragraphe du curseur", TranscriptText.paragraphEnd(of: 2, in: "Un deux\nTrois") == 7)
        check("Écoute : jamais au milieu d'un paragraphe", TranscriptText.paragraphEnd(of: 9, in: "Un deux\nTrois") == 13)

        // The place of the words, as the text changes around it (anchor at 10).
        check("Écoute : ce qui est tapé avant décale", TranscriptText.anchor(10, afterEditing: NSRange(location: 2, length: 3), delta: 3) == 13)
        check("Écoute : ce qui est tapé à cet endroit passe devant", TranscriptText.anchor(10, afterEditing: NSRange(location: 10, length: 2), delta: 2) == 12)
        check("Écoute : ce qui est tapé après ne change rien", TranscriptText.anchor(10, afterEditing: NSRange(location: 12, length: 1), delta: 1) == 10)
        check("Écoute : effacé avant, recule", TranscriptText.anchor(10, afterEditing: NSRange(location: 3, length: 0), delta: -4) == 6)
        check("Écoute : effacé par-dessus, au bord de l'effacement", TranscriptText.anchor(10, afterEditing: NSRange(location: 8, length: 0), delta: -5) == 8)

        let moved = TranscriptText.moved
        check("Écoute : sélection après, décalée", moved(NSRange(location: 12, length: 2), 5, 10) == NSRange(location: 17, length: 2))
        check("Écoute : sélection avant, immobile", moved(NSRange(location: 2, length: 3), 5, 10) == NSRange(location: 2, length: 3))
        check("Écoute : sélection qui l'enjambe, agrandie", moved(NSRange(location: 8, length: 4), 5, 10) == NSRange(location: 8, length: 9))
    }

    private static func flow() {
        var flow = TranscriptFlow()
        check("Écoute : la première phrase ouvre un paragraphe", flow.startsParagraph("Un.", from: 0, to: 1))
        check("Écoute : une phrase qui suit de près continue", !flow.startsParagraph("Deux.", from: 1.5, to: 2))
        check("Écoute : après un silence, un paragraphe", flow.startsParagraph("Trois.", from: 2 + TranscriptText.pause, to: 6))
        let long = String(repeating: "mot ", count: 160)
        _ = flow.startsParagraph(long, from: 6.5, to: 20)
        check("Écoute : un paragraphe long s'arrête", flow.startsParagraph("Quatre.", from: 20.5, to: 21))
        flow.breaks = true
        check("Écoute : après une coupure du micro, un paragraphe", flow.startsParagraph("Cinq.", from: 21.2, to: 22))
        check("Écoute : l'autre source parle, un paragraphe", flow.startsParagraph("Six.", from: 22.2, to: 23, channel: .mac))
        check("Écoute : la même source enchaîne", !flow.startsParagraph("Sept.", from: 23.2, to: 24, channel: .mac))
    }

    // MARK: Two sources

    private static func echo() {
        let french = Locale(identifier: "fr-FR")
        let mac = HeardSentence(channel: .mac, text: "On se retrouve mardi pour valider les maquettes du site.", start: 10, end: 14)
        let heardAgain = HeardSentence(channel: .microphone, text: "On se retrouve mardi pour valider les maquettes du site", start: 10.3, end: 14.2)
        check("Écho : la phrase du Mac réentendue au micro est retirée", Echo.removed(from: heardAgain, heard: [mac], locale: french) == nil)
        let mixed = HeardSentence(channel: .microphone, text: "D'accord je note tout ça et on se retrouve mardi pour valider les maquettes", start: 11, end: 15)
        let kept = Echo.removed(from: mixed, heard: [mac], locale: french)
        check("Écho : ce qui est dit dans la pièce reste", kept == "D'accord je note tout ça et", kept ?? "nil")
        let mine = HeardSentence(channel: .microphone, text: "Je préfère jeudi pour ma part.", start: 16, end: 18)
        check("Écho : une phrase à soi est gardée telle quelle", Echo.removed(from: mine, heard: [mac], locale: french) == mine.text)
        let later = HeardSentence(channel: .microphone, text: "On se retrouve mardi pour valider les maquettes du site.", start: 60, end: 64)
        check("Écho : loin dans le temps, ce n'est plus un écho", Echo.removed(from: later, heard: [mac], locale: french) == later.text)

        var queue = SentenceQueue(holds: true, locale: french)
        queue.add(HeardSentence(channel: .mac, text: "Bonjour à tous.", start: 2, end: 3), at: 100)
        queue.add(HeardSentence(channel: .microphone, text: "Salut.", start: 0.5, end: 1), at: 101)
        check("File : rien avant l'attente", queue.release(at: 102).isEmpty)
        let out = queue.release(at: 105.5)
        check("File : dans l'ordre où c'était dit", out.map(\.text) == ["Salut.", "Bonjour à tous."], out.map(\.text).joined(separator: " | "))
        queue.add(mac, at: 110)
        queue.add(heardAgain, at: 111)
        check("File : à la fin, tout, sans l'écho", queue.release(at: 111, all: true).map(\.text) == [mac.text])
        var single = SentenceQueue(holds: false, locale: french)
        single.add(mine, at: 0)
        check("File : une seule source, rien n'attend", single.release(at: 0).count == 1)
    }

    // MARK: Voices

    private static func voices() {
        let turns = Voices.numbered([
            Voices.Turn(voice: "S7", start: 0, end: 5), Voices.Turn(voice: "S2", start: 5, end: 11),
            Voices.Turn(voice: "S9", start: 11, end: 12), Voices.Turn(voice: "S7", start: 12, end: 20),
        ])
        check("Voix : numérotées dans l'ordre où elles parlent", turns.map(\.voice) == [Voices.label(1), Voices.label(2), Voices.label(1)], turns.map(\.voice).joined(separator: ","))
        check("Voix : la plus entendue pendant la phrase", Voices.voice(from: 4, to: 9, in: turns) == Voices.label(2))
        check("Voix : hors des tours, la plus proche à moins d'une seconde", Voices.voice(from: 20.2, to: 20.8, in: turns) == Voices.label(1))
        check("Voix : trop loin, personne", Voices.voice(from: 30, to: 31, in: turns) == nil)

        let room = [HeardSentence(channel: .microphone, text: "A.", start: 1, end: 2), HeardSentence(channel: .microphone, text: "B.", start: 6, end: 9),
                    HeardSentence(channel: .microphone, text: "C.", start: 13, end: 15)]
        check("Voix : deux voix dans la pièce, nommées", Voices.speakers(of: room, microphone: turns, mac: nil) == [Voices.label(1), Voices.label(2), Voices.label(1)])
        check("Voix : une seule voix, aucun nom", Voices.speakers(of: room, microphone: [Voices.Turn(voice: Voices.label(1), start: 0, end: 20)], mac: nil) == [nil, nil, nil])
        check("Voix : sans séparation, aucun nom", Voices.speakers(of: room, microphone: nil, mac: nil) == [nil, nil, nil])
        let call = [HeardSentence(channel: .microphone, text: "Bonjour.", start: 0, end: 1), HeardSentence(channel: .mac, text: "Salut.", start: 2, end: 3)]
        check("Voix : micro et Mac, « Moi » et « Eux »", Voices.speakers(of: call, microphone: nil, mac: nil) == [Voices.me, Voices.them])
        let several = [Voices.Turn(voice: Voices.label(1), start: 0, end: 5), Voices.Turn(voice: Voices.label(2), start: 5, end: 10)]
        let call2 = call + [HeardSentence(channel: .mac, text: "Oui.", start: 6, end: 7)]
        check("Voix : plusieurs voix au bout du fil, chacune la sienne", Voices.speakers(of: call2, microphone: nil, mac: several) == [Voices.me, Voices.label(1), Voices.label(2)])

        let text = "Réunion\nBonjour à tous. On commence.\nJe note.\nTrès bien." as NSString
        let labels = TranscriptText.labels(for: ["Bonjour à tous.", "On commence.", "Je note.", "Très bien."], speakers: ["A", "B", "B", "A"], in: text)
        check("Noms : avant chaque changement de voix", labels.map(\.location) == [8, 23, 46], labels.map { "\($0.location)" }.joined(separator: ","))
        check("Noms : au milieu d'un paragraphe, il est coupé à l'espace", labels.map(\.newLine) == [false, true, false] && labels.map(\.spaceFollows) == [false, true, false])
        let edited = TranscriptText.labels(for: ["Bonjour à tous.", "Phrase changée.", "Je note."], speakers: ["A", "B", "B"], in: text)
        check("Noms : une phrase modifiée depuis passe son tour", edited.map(\.location) == [8, 37], edited.map { "\($0.location)" }.joined(separator: ","))
        let before = TranscriptText.labels(for: ["Je note.", "Très bien."], speakers: ["A", "B"], in: text, from: 40)
        check("Noms : cherchés là où la transcription commence", before.map(\.location) == [46], before.map { "\($0.location)" }.joined(separator: ","))
    }

    // MARK: In a real text view

    /// A note on screen: a text view in a window, saved like the window's.
    /// The note's text view as the window makes it, showing the tab `part`.
    private static func editor(for note: Note, part: NotePart = .notes, store: NoteStore) -> (NoteTextView, NSWindow) {
        let (scrollView, textView) = NoteTextView.makeScrollable()
        textView.part = part
        textView.load(note.composite(part))
        textView.onChange = { [weak textView] in if let textView { store.update(note.id, part: part, composite: textView.content) } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        // Owned here: closed, it isn't released a second time.
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        return (textView, window)
    }

    /// The text of a tab after its title: the part it shows.
    private static func partText(of view: NoteTextView) -> String {
        let string = view.string as NSString
        let start = TranscriptText.partStart(of: view.part, in: string)
        return string.substring(from: start)
    }

    private static func textView() async {
        let store = NoteStore(directory: nil)
        let listener = Listener(store: store)
        let note = store.create()
        let (notesView, notesWindow) = editor(for: note, store: store)
        listener.register(notesView, for: note.id)

        listener.pretend(in: note.id)
        let title = notesView.string
        check("Écoute : une note vide reçoit un titre daté", title.hasPrefix("Écoute du ") && !title.contains("\n"), title)
        check("Écoute : ce titre est un titre", notesView.textStorage.flatMap { NoteFormat.block(in: $0.attributes(at: 0, effectiveRange: nil)) } == .title)
        check("Écoute : la note n'est plus vide", store.note(note.id)?.isBlank == false)
        let marker = store.note(note.id)?.transcript?.text ?? ""
        check("Transcription : elle commence par la ligne datée de l'écoute", marker.hasPrefix("Écoute du ") && !marker.contains("\n"), marker)
        check("Transcription : cette ligne est un sous-titre", store.note(note.id)?.transcript?.runs.first?.block == .subheading)
        check("Onglets : celui de la transcription s'ouvre", store.note(note.id).map(NoteTabs.shared.part(of:)) == .transcript)
        notesWindow.close()

        // The transcript's tab, as the window shows it once it opens.
        let (view, window) = editor(for: store.note(note.id)!, part: .transcript, store: store)
        listener.register(view, for: note.id)
        let string = { view.string }
        listener.pretendHeard("Bonjour à tous.", from: 0, to: 1.2)
        listener.pretendHeard("On commence.", from: 1.6, to: 2.4)
        check("Onglets : le titre de la note, puis la transcription", string() == title + "\n" + marker + "\nBonjour à tous. On commence.", string())
        let bodyStart = (title as NSString).length + 1 + (marker as NSString).length + 1
        check("Écoute : en texte, pas en titre", view.textStorage.flatMap { NoteFormat.block(in: $0.attributes(at: bodyStart, effectiveRange: nil)) } == nil,
              view.content.runs.map { "\($0.start)+\($0.length) \($0.block?.rawValue ?? "-")" }.joined(separator: ", "))
        check("Écoute : le curseur suit les mots", view.selectedRange() == NSRange(location: (string() as NSString).length, length: 0))
        check("Transcription : à part du texte de la note", store.note(note.id)?.content.text == title && store.note(note.id)?.transcript?.text == partText(of: view),
              "\(store.note(note.id)?.content.text ?? "") | \(store.note(note.id)?.transcript?.text ?? "")")

        // The title changed from the tab: the words still go at their place, the cursor stays.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Note. ", replacementRange: view.selectedRange())
        let caret = view.selectedRange()
        listener.pretendHeard("Deuxième point.", from: 6, to: 7)
        check("Écoute : un silence, un nouveau paragraphe, à la fin", string().hasSuffix("On commence.\nDeuxième point."), string())
        check("Onglets : le titre changé dans un onglet est celui de la note", store.note(note.id)?.content.text == "Note. " + title, store.note(note.id)?.content.text ?? "")
        check("Écoute : le curseur reste où l'on écrit", view.selectedRange() == caret)

        // A sentence that looks like a mark of Markdown is written as it is said.
        listener.pretendHeard("- pas une liste", from: 12, to: 13)
        check("Écoute : aucune marque n'est lue dans ce qui est dit", string().hasSuffix("\n- pas une liste"), string())
        check("Écoute : enregistré dans la transcription", store.note(note.id)?.transcript?.text == partText(of: view))

        await listener.endPretending()
        check("Écoute : arrêtée, plus rien n'est écrit", { listener.pretendHeard("Trop tard.", from: 20, to: 21); return !string().contains("Trop tard") }())
        window.close()
    }

    /// The note not on screen, or on its own text: the words go to the transcript saved; its tab,
    /// when it comes back, takes them from there. A second listening follows the first.
    private static func noteNotShown() async {
        let store = NoteStore(directory: nil)
        let listener = Listener(store: store)
        let note = store.create()
        store.update(note.id, content: NoteContent(text: "Réunion\nOrdre du jour", runs: [StyleRun(start: 0, length: 7, block: .title)]))
        listener.pretend(in: note.id)
        listener.pretendHeard("Premier sujet.", from: 0, to: 1)
        listener.pretendHeard("Suite.", from: 1.2, to: 2)
        let transcript = { store.note(note.id)?.transcript?.text ?? "" }
        check("Écoute : note pas affichée, les mots dans sa transcription", transcript().hasPrefix("Écoute du ") && transcript().hasSuffix("\nPremier sujet. Suite."), transcript())
        check("Écoute : le texte de la note ne bouge pas", store.note(note.id)?.content == NoteContent(text: "Réunion\nOrdre du jour", runs: [StyleRun(start: 0, length: 7, block: .title)]))

        let (view, window) = editor(for: store.note(note.id)!, part: .transcript, store: store)
        listener.register(view, for: note.id)
        view.setSelectedRange(NSRange(location: 3, length: 0))
        listener.pretendHeard("De retour.", from: 2.5, to: 3)
        check("Écoute : l'onglet rouvert, les mots reprennent à la fin", view.string.hasSuffix("Suite.\nDe retour."), view.string)
        window.close()

        // Back on the note's own text: one writes there, the words go on in the transcript.
        let (notesView, notesWindow) = editor(for: store.note(note.id)!, store: store)
        listener.register(notesView, for: note.id)
        listener.pretendHeard("Encore.", from: 6, to: 7)
        check("Onglets : sur les notes, rien ne s'y mêle", notesView.string == "Réunion\nOrdre du jour" && transcript().hasSuffix("De retour.\nEncore."), "\(notesView.string) | \(transcript())")
        await listener.endPretending()

        listener.pretend(in: note.id)
        listener.pretendHeard("Deuxième écoute.", from: 0, to: 1)
        await listener.endPretending()
        let lines = transcript().components(separatedBy: "\n")
        check("Transcription : une deuxième écoute suit, sous sa propre ligne datée", lines.filter { $0.hasPrefix("Écoute du ") }.count == 2 && lines.last == "Deuxième écoute.", transcript())
        notesWindow.close()
    }

    /// The listening ends: the voices' names go before the sentences, the sound with the recordings.
    private static func named() async {
        let store = NoteStore(directory: nil)
        let listener = Listener(store: store)
        let note = store.create()
        store.update(note.id, content: NoteContent(text: "Réunion", runs: [StyleRun(start: 0, length: 7, block: .title)]))
        listener.pretend(in: note.id)
        let (view, window) = editor(for: store.note(note.id)!, part: .transcript, store: store)
        listener.register(view, for: note.id)
        let head = view.string
        listener.pretendHeard("Bonjour.", from: 0, to: 1)
        listener.pretendHeard("Salut, ça va ?", from: 1.3, to: 2)
        listener.pretendHeard("Très bien.", from: 2.3, to: 3)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: file) }
        if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
           let recorder = try? Recorder(url: file, format: format), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000) {
            buffer.frameLength = 32_000
            recorder.write(buffer)
            recorder.close()
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        await listener.endPretending(speakers: ["Voix 1", "Voix 2", "Voix 1"], files: [file])
        let expected = head + "\nVoix 1 : Bonjour.\nVoix 2 : Salut, ça va ?\nVoix 1 : Très bien."
        check("Noms : écrits avant les phrases", view.string == expected, view.string.replacingOccurrences(of: "\n", with: " ⏎ "))
        let nameStart = (head as NSString).length + 1
        check("Noms : en gras", view.textStorage?.attribute(NoteFormat.boldKey, at: nameStart, effectiveRange: nil) != nil)
        check("Noms : la phrase reste en texte", view.textStorage?.attribute(NoteFormat.boldKey, at: nameStart + 9, effectiveRange: nil) == nil)
        check("Noms : le curseur n'a pas bougé", view.selectedRange() == NSRange(location: 0, length: 0))
        let attached = store.note(note.id)?.recordings ?? []
        check("Audio : dans les enregistrements de la note, pas dans le texte", attached.count == 1 && attached.first?.hasSuffix(".m4a") == true
              && store.note(note.id)?.attachments.isEmpty == true, attached.joined(separator: ","))
        if let name = attached.first {
            let url = store.attachmentsDirectory(of: note.id).appendingPathComponent(name)
            check("Audio : le fichier se lit", (Recording.seconds(of: url) ?? 0) > 1.5, "\(Recording.seconds(of: url) ?? -1)")
        }
        check("Noms : enregistrés dans la transcription", store.note(note.id)?.transcript?.text == partText(of: view) && store.note(note.id)?.content.text == "Réunion",
              "\(store.note(note.id)?.content.text ?? "") | \(store.note(note.id)?.transcript?.text ?? "")")
        window.close()

        // A note not shown when the listening ends: the same, in the transcript saved.
        let other = store.create()
        store.update(other.id, content: NoteContent(text: "Point\nOui. Non.", runs: [StyleRun(start: 0, length: 5, block: .title)]))
        listener.pretend(in: other.id)
        let marker = store.note(other.id)?.transcript?.text ?? ""
        listener.pretendHeard("Oui.", from: 0, to: 1)
        listener.pretendHeard("Non.", from: 1.2, to: 2)
        await listener.endPretending(speakers: ["Moi", "Eux"])
        check("Noms : dans une note pas affichée, dans sa transcription", store.note(other.id)?.transcript?.text == marker + "\nMoi : Oui.\nEux : Non.",
              store.note(other.id)?.transcript?.text ?? "")
        check("Noms : le texte de la note n'en reçoit rien", store.note(other.id)?.content.text == "Point\nOui. Non.", store.note(other.id)?.content.text ?? "")
    }

    // MARK: Recording

    /// The sound as written while listening (AAC in ADTS), then as joined to the note: one source
    /// put into an `.m4a` as it is, two mixed.
    private static func recording() async {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-enregistrement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false) else { return }
        func tone(_ hertz: Double, seconds: Double, into recorder: Recorder) {
            let frames = AVAudioFrameCount(seconds * 16_000)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let samples = buffer.int16ChannelData?[0] else { return }
            buffer.frameLength = frames
            for index in 0..<Int(frames) { samples[index] = Int16(8000 * sin(2 * .pi * hertz * Double(index) / 16_000)) }
            recorder.write(buffer)
        }
        guard let micro = try? Recorder(url: folder.appendingPathComponent("microphone.aac"), format: format),
              let mac = try? Recorder(url: folder.appendingPathComponent("mac.aac"), format: format) else {
            return check("Enregistrement : fichiers ouverts", false)
        }
        tone(220, seconds: 60, into: micro)
        tone(440, seconds: 58, into: mac)
        micro.close()
        mac.close()
        check("Enregistrement : lisible pendant l'écoute (ADTS)", abs((Recording.seconds(of: micro.url) ?? 0) - 60) < 0.5, "\(Recording.seconds(of: micro.url) ?? -1)")

        let single = folder.appendingPathComponent("seul.m4a"), both = folder.appendingPathComponent("mix.m4a")
        let made = try? Recording.finish([micro.url], to: single)
        check("Enregistrement : une source, en .m4a", made != nil && abs((Recording.seconds(of: single) ?? 0) - 60) < 0.5, "\(Recording.seconds(of: single) ?? -1)")
        let size = (try? FileManager.default.attributesOfItem(atPath: single.path)[.size] as? Int) ?? 0
        print("      une minute : \(size / 1000) ko (\(size * 60 / 1_000_000) Mo l'heure)")
        check("Enregistrement : léger (moins de 15 Mo l'heure)", size > 0 && size * 60 < 15_000_000, "\(size)")
        let mixed = try? Recording.finish([micro.url, mac.url], to: both)
        check("Enregistrement : deux sources, mélangées en un fichier", mixed != nil && abs((Recording.seconds(of: both) ?? 0) - 60) < 0.5, "\(Recording.seconds(of: both) ?? -1)")
        let empty = folder.appendingPathComponent("vide.aac")
        if let recorder = try? Recorder(url: empty, format: format) { recorder.close() }
        check("Enregistrement : une source muette est laissée de côté", (try? Recording.finish([empty, micro.url], to: folder.appendingPathComponent("x.m4a"))) != nil)

        // The Mac's sound comes only while something plays: the silence before is put back.
        let start = mach_absolute_time()
        func ticks(_ seconds: Double) -> UInt64 { start + AVAudioTime.hostTime(forSeconds: seconds) }
        let clock = SoundClock(start: start, format: format)
        func second() -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            return buffer
        }
        let late = clock.aligned(second(), heardAt: ticks(2.5))
        let lateFrames = late.dropLast().reduce(0) { $0 + Int($1.frameLength) }
        check("Horloge : le silence avant un son tardif est remis", lateFrames == 40_000 && late.count == 4, "\(lateFrames) en \(late.count)")
        check("Horloge : le son qui suit n'en reçoit pas", clock.aligned(second(), heardAt: ticks(3.5)).count == 1)
        check("Horloge : un peu de retard n'est pas un silence", clock.aligned(second(), heardAt: ticks(4.6)).count == 1)
        check("Horloge : un trou de deux secondes, remis", clock.aligned(second(), heardAt: ticks(7.6)).dropLast().reduce(0) { $0 + Int($1.frameLength) } == 33_600)
    }

    // MARK: Summary

    /// The model's answers read back, and where the summary goes in the note.
    private static func summaryText() {
        let answer = """
        **EN BREF**
        Léa et Marc retiennent le devis Morel. Le plan de travail reste à choisir. Léa et Marc retiennent le devis Morel.
        POINTS CLÉS
        - le devis Morel livre avant l'été
        - Le devis Morel livre avant l'été.
        - (trois à cinq points courts)
        DÉCISIONS :
        - aucune
        ACTIONS
        - Marc : envoyer l'acompte
        """
        let parts = SummaryText.sections(answer, headings: ["EN BREF", "POINTS CLÉS", "DÉCISIONS", "ACTIONS"])
        check("Résumé : les parties sous leurs titres", parts.count == 4, "\(parts.keys.sorted())")
        check("Résumé : une phrase répétée, gardée une fois", SummaryText.paragraph(parts["EN BREF"], sentences: 3) == "Léa et Marc retiennent le devis Morel. Le plan de travail reste à choisir.", SummaryText.paragraph(parts["EN BREF"], sentences: 3))
        check("Résumé : points sans doublon ni modèle recopié", SummaryText.items(parts["POINTS CLÉS"]) == ["Le devis Morel livre avant l'été"], "\(SummaryText.items(parts["POINTS CLÉS"]))")
        check("Résumé : « aucune » n'est rien", SummaryText.items(parts["DÉCISIONS"]).isEmpty)
        check("Résumé : un titre mal écrit n'efface pas le paragraphe", SummaryText.body(of: "PARAGRAPHUE\nVoix 1 valide la maquette.", under: "PARAGRAPHE") == "Voix 1 valide la maquette.")
        check("Résumé : un titre oublié non plus", SummaryText.body(of: "Voix 1 valide la maquette.", under: "PARAGRAPHE") == "Voix 1 valide la maquette.")
        check("Résumé : un mot seul n'est rien", SummaryText.items("- Oui\n- Marc : oui\n- Utiliser Stripe").count == 1)
        check("Résumé : l'action avec son nom", SummaryText.items(parts["ACTIONS"]) == ["Marc : envoyer l'acompte"])

        let summary = NoteSummary(brief: "Marc enverra l'acompte. Le plan de travail reste à choisir.")
        let content = NoteMarkdown.content(fromMarkdown: summary.markdown)
        check("Résumé : un paragraphe, sans titre ni liste", content.text == summary.brief && content.runs.isEmpty, "\(content)")
        let long = NoteSummary(brief: "L'ensemble.", parts: ["La première partie.", "La seconde."])
        let paragraphs = NoteMarkdown.content(fromMarkdown: long.markdown)
        check("Résumé : long, l'ensemble puis un paragraphe par partie", paragraphs.text == "L'ensemble.\nLa première partie.\nLa seconde." && paragraphs.runs.isEmpty, paragraphs.text)
        check("Résumé : sa longueur suit celle de la transcription", SummaryText.sentences(for: 300) == 3 && SummaryText.sentences(for: 1_400) == 7 && SummaryText.sentences(for: 2_200) == 10)

        // A tab: the note's title, then its part; the title edited there is the note's.
        let store = NoteStore(directory: nil)
        let note = store.create()
        store.update(note.id, content: NoteContent(text: "Titre\nMes notes", runs: [StyleRun(start: 0, length: 5, block: .title)]))
        store.update(note.id, part: .summary, content: content)
        let shown = store.note(note.id)!.composite(.summary)
        check("Onglets : le titre puis le résumé", shown.text == "Titre\n" + content.text && shown.runs.first == StyleRun(start: 0, length: 5, block: .title), shown.text)
        var edited = shown
        edited.text = "Titre 2" + edited.text.dropFirst(5)
        edited.runs = [StyleRun(start: 0, length: 7, block: .title)] + shown.runs.dropFirst().map { var run = $0; run.start += 2; return run }
        store.update(note.id, part: .summary, composite: edited)
        check("Onglets : le titre changé va à la note, ses notes restent", store.note(note.id)?.content.text == "Titre 2\nMes notes", store.note(note.id)?.content.text ?? "")
        check("Onglets : le résumé reste le résumé", store.note(note.id)?.summary == content)
        let alone = store.create()
        store.update(alone.id, content: NoteContent(text: "Seul", runs: [StyleRun(start: 0, length: 4, block: .title)]))
        store.update(alone.id, part: .summary, content: content)
        store.update(alone.id, part: .summary, composite: store.note(alone.id)!.composite(.summary))
        check("Onglets : un titre seul ne reçoit pas de retour à la ligne", store.note(alone.id)?.content.text == "Seul", store.note(alone.id)?.content.text ?? "")
        check("Onglets : seulement ceux que la note a", NoteTabs.shared.part(of: { NoteTabs.shared.show(.transcript, in: alone.id); return store.note(alone.id)! }()) == .notes)
    }

    private static let longMeeting = """
    Voix 1 : Bon, on commence par le site de la boulangerie. La maquette de l'accueil est validée par la cliente, elle a juste demandé des photos plus chaudes.
    Voix 2 : J'ai regardé les solutions de paiement. Stripe prend 1,5 % par transaction, SumUp un peu plus mais sans abonnement. On part sur Stripe, c'est plus simple à brancher.
    Voix 1 : D'accord pour Stripe. La page des commandes n'est pas commencée, je m'en occupe cette semaine, je vise vendredi.
    Voix 2 : Il faudra aussi gérer les commandes la veille pour le lendemain matin, c'est ce que la cliente veut le plus.
    Voix 1 : Oui, avec une heure limite à dix-huit heures. Après, on ferme les commandes du lendemain.
    Voix 2 : Deuxième sujet, le budget. On a dépensé huit mille euros sur les douze prévus pour le trimestre.
    Voix 1 : Le gros poste, c'est la photo. Le photographe nous a facturé deux mille euros, c'était prévu.
    Voix 2 : Il reste quatre mille. Je propose d'en garder mille de côté pour les imprévus de fin d'année.
    Voix 1 : Ça me va. Par contre on ne prend pas la deuxième séance photo tant que le site n'est pas en ligne.
    Voix 2 : D'accord, on la repousse à janvier.
    Voix 1 : Dernier sujet, le recrutement. On cherche toujours un développeur pour deux jours par semaine.
    Voix 2 : J'ai eu deux candidatures, Julien qui vient d'une agence à Lyon, et Sarah qui est indépendante.
    Voix 1 : Sarah a déjà fait des sites de commerce, ça nous intéresse. Tu peux lui proposer un entretien ?
    Voix 2 : Oui, je l'appelle demain. Pour Julien, il demande un temps plein, ça ne colle pas.
    Voix 1 : Alors on garde Sarah en priorité. On refait le point dans quinze jours.
    """

    /// A real summary, when Apple Intelligence is on.
    private static func summaryLive() async {
        guard #available(macOS 26, *) else { return }
        if let reason = Summarizer.availability() { return print("      résumé réel passé : \(reason)") }
        // `VOID_SUMMARY_LONG=1`: a longer meeting, three subjects (with `VOID_PASSAGE_BUDGET`, read in passages).
        let long = ProcessInfo.processInfo.environment["VOID_SUMMARY_LONG"] != nil
        let transcript = long ? Self.longMeeting : """
        Voix 1 : Bon, on fait le point sur le site de la boulangerie. La maquette de l'accueil est prête, il reste la page des commandes.
        Voix 2 : J'ai regardé les deux solutions de paiement. Stripe est plus simple à brancher, on part là-dessus.
        Voix 1 : D'accord, Stripe. Moi je finis la page des commandes d'ici vendredi.
        Voix 2 : Et j'envoie les photos des viennoiseries à Claire demain matin pour qu'elle les retouche.
        """
        let started = Date()
        do {
            let summary = try await Summarizer().summarize(transcript, speakers: ["Voix 1", "Voix 2"]) { _ in }
            print("      résumé en \(String(format: "%.1f", Date().timeIntervalSince(started))) s :\n" + summary.markdown.split(separator: "\n").map { "        \($0)" }.joined(separator: "\n"))
            check("Résumé réel : un « en bref »", !summary.brief.isEmpty)
            check("Résumé réel : sans liste", !summary.brief.contains("\n") && !summary.brief.hasPrefix("-"), summary.brief)
        } catch {
            check("Résumé réel : écrit", false, error.localizedDescription)
        }
    }

    // MARK: Player

    /// The recordings of a note: in their section, played at the foot of the note, the voices
    /// renamed in one step of ⌘Z, deleted; and those an earlier beta wrote in the text, moved out.
    private static func player() async {
        check("Lecteur : un .m4a est un enregistrement", RecordingText.isAudio("Écoute 2026-10-14 15h02.m4a") && !RecordingText.isAudio("Billet.pdf"))
        check("Lecteur : le temps se lit", AudioPlayback.clock(42) == "0:42" && AudioPlayback.clock(3723) == "1:02:03")
        check("Lecteur : le nom sans l'extension", AudioPlayback.title("Écoute 2026-10-14 15h02.m4a") == "Écoute 2026-10-14 15h02")

        let body = NoteFormat.attributes(block: nil)
        var bold = body
        bold[NoteFormat.boldKey] = true
        let text = NSMutableAttributedString(string: "Titre\n", attributes: body)
        text.append(NoteAttachmentCell.character(name: "a.m4a", directory: nil))
        text.append(NSAttributedString(string: "\n", attributes: body))
        text.append(NSAttributedString(string: "Voix 1", attributes: bold))
        text.append(NSAttributedString(string: " : Bonjour.\n", attributes: body))
        text.append(NSAttributedString(string: "Voix 2", attributes: bold))
        text.append(NSAttributedString(string: " : Salut.\nNote : pas une voix.", attributes: body))
        check("Voix : les noms en gras suivis de deux-points", RecordingText.voices(in: text).map(\.name) == ["Voix 1", "Voix 2"])
        let renamed = RecordingText.renaming(["Voix 2": "Claire"], in: text)
        check("Voix : renommer change le nom, en gras", renamed.count == 1 && renamed.first?.1.string == "Claire" && renamed.first?.1.attribute(NoteFormat.boldKey, at: 0, effectiveRange: nil) != nil)
        check("Lecteur : un son du texte en part avec sa ligne", RecordingText.recordings(in: text).map(\.name) == ["a.m4a"] && RecordingText.removal(at: 6, in: text).length == 2)

        let store = NoteStore(directory: nil)
        let listener = Listener(store: store)
        let note = store.create()
        let (view, window) = editor(for: note, store: store)
        view.attachmentsDirectory = store.attachmentsDirectory(of: note.id)
        listener.register(view, for: note.id)
        listener.pretend(in: note.id)
        listener.pretendHeard("Bonjour.", from: 0, to: 1)
        listener.pretendHeard("Salut.", from: 4, to: 5)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-lecteur-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: file) }
        if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
           let recorder = try? Recorder(url: file, format: format), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 30) {
            buffer.frameLength = buffer.frameCapacity
            recorder.write(buffer)
            recorder.close()
        }
        await listener.endPretending(speakers: ["Voix 1", "Voix 2"], files: [file])
        guard let shown = store.note(note.id), let name = shown.recordings.first else {
            window.close()
            return check("Lecteur : l'enregistrement dans sa section", false)
        }
        check("Lecteur : la section et les onglets prennent leur place sous le titre",
              NoteSections.height(of: shown) == NoteRecordingsSection.height(ruled: false) + NoteSections.spacing + NoteTabBar.height)

        let url = store.attachmentsDirectory(of: note.id).appendingPathComponent(name)
        let playback = AudioPlayback.shared
        playback.open(url, of: note.id, at: 12)
        check("Lecteur : ouvert au bas de la note, à un moment", playback.isOpen && playback.noteID == note.id && abs(playback.time - 12) < 0.1 && !playback.isPlaying, "\(playback.time)")
        playback.skip(by: AudioPlayback.step)
        check("Lecteur : 10 secondes plus loin", abs(playback.time - 22) < 0.1, "\(playback.time)")
        playback.skip(by: -30)
        check("Lecteur : pas avant le début", playback.time == 0)
        playback.skip(by: 600)
        check("Lecteur : pas après la fin", playback.time > 0 && abs(playback.time - playback.duration) < 0.1, "\(playback.time)")
        playback.pretendVoices([
            Voices.Turn(voice: Voices.label(1), start: 0, end: 4), Voices.Turn(voice: Voices.label(2), start: 5, end: 9),
            Voices.Turn(voice: Voices.label(1), start: 9.5, end: 12), Voices.Turn(voice: Voices.label(2), start: 15, end: 20),
        ])
        check("Voix au lecteur : dans l'ordre où elles parlent", playback.voiceNames == [Voices.label(1), Voices.label(2)])
        check("Voix au lecteur : qui parle", playback.speaker(at: 6) == Voices.label(2) && playback.speaker(at: 13) == nil)
        check("Voix au lecteur : un souffle ne coupe pas", playback.spans(of: Voices.label(2)).count == 2 && playback.spans(of: Voices.label(1)).count == 2)
        playback.seek(to: 2)
        playback.listen(only: Voices.label(2))
        check("Voix au lecteur : une seule, à son prochain moment", abs(playback.time - 5) < 0.1, "\(playback.time)")
        playback.seek(to: 22)
        playback.listen(only: Voices.label(2))
        check("Voix au lecteur : après son dernier moment, son premier", abs(playback.time - 5) < 0.1, "\(playback.time)")
        playback.close()
        check("Lecteur : fermé", !playback.isOpen && playback.onlyVoice == nil)

        check("Voix : celles de la transcription", listener.voices(in: note.id) == ["Voix 1", "Voix 2"], listener.voices(in: note.id).joined(separator: ","))
        window.close()
        store.update(note.id, part: .summary, content: NoteContent(text: "Voix 2 : envoyer les photos. Voix 12 reste."))
        let (tab, transcriptWindow) = editor(for: store.note(note.id)!, part: .transcript, store: store)
        listener.register(tab, for: note.id)
        tab.setSelectedRange(NSRange(location: 2, length: 0))
        let before = tab.string
        // What was written before is one step of ⌘Z, the renaming another — as between two
        // clicks (the test has no events to close the steps).
        if let undo = tab.undoManager {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo.groupsByEvent = false
        }
        listener.renameVoices(["Voix 2": "Claire", "Voix 1": "Moi"], in: note.id)
        check("Voix : renommées partout", tab.string.contains("Moi : Bonjour.") && tab.string.contains("Claire : Salut.") && !tab.string.contains("Voix 1") && !tab.string.contains("Voix 2"), tab.string)
        check("Voix : le curseur reste", tab.selectedRange() == NSRange(location: 2, length: 0))
        check("Voix : enregistré dans la transcription", store.note(note.id)?.transcript?.text == partText(of: tab))
        check("Voix : renommées dans le résumé aussi, nom entier", store.note(note.id)?.summary?.text == "Claire : envoyer les photos. Voix 12 reste.", store.note(note.id)?.summary?.text ?? "")
        tab.undoManager?.undo()
        check("Voix : ⌘Z rend les anciens noms d'un coup", tab.string == before, tab.string)
        tab.undoManager?.groupsByEvent = true

        store.removeRecording(name, from: note.id)
        check("Lecteur : supprimé de la note", store.note(note.id)?.recordings.isEmpty == true && tab.string == before)
        transcriptWindow.close()

        // An earlier beta wrote the recording in the text: it goes to the section.
        let old = store.create()
        guard let kept = store.attach(file, to: old.id) else { return check("Lecteur : fichier joint", false) }
        let inText = NSMutableAttributedString(string: "Réunion\n", attributes: NoteFormat.attributes(block: .title))
        inText.append(NoteAttachmentCell.character(name: kept, directory: nil))
        inText.append(NSAttributedString(string: "\nVoix 1 : Bonjour.", attributes: body))
        store.update(old.id, content: NoteFormat.content(from: inText))
        listener.moveRecordingsOutOfText()
        check("Lecteur : l'ancien enregistrement quitte le texte, avec sa ligne", store.note(old.id)?.content.text == "Réunion\nVoix 1 : Bonjour.", store.note(old.id)?.content.text ?? "")
        check("Lecteur : il est dans la section", store.note(old.id)?.recordings == [kept])
    }

    // MARK: From end to end

    /// Said one after the other, with the silence of someone who stops talking between them.
    private static let spoken = ["Bonjour. Nous faisons le point sur le projet.", "Le rendez-vous est fixé à mardi prochain."]

    private static func endToEnd() async {
        guard Listener.isAvailable else { return print("SKIP  Écoute : transcription indisponible sur ce Mac (macOS 26 requis)") }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-ecoute-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let seconds = await synthesize(spoken, pause: 3.5, to: file) else { return check("Écoute : voix de synthèse française", false, "aucune voix fr-FR") }

        let store = NoteStore(directory: nil)
        let listener = Listener(store: store)
        let note = store.create()
        let (view, window) = editor(for: note, store: store)
        listener.register(view, for: note.id)
        Microphone.debugFile = file
        ListenLanguage.override = "fr-FR"
        let defaults = UserDefaults.standard
        let kept = defaults.object(forKey: ListenPreferences.keepsAudioKey), separated = defaults.object(forKey: ListenPreferences.separatesVoicesKey)
        let source = defaults.object(forKey: ListenSource.key)
        defaults.set(true, forKey: ListenPreferences.keepsAudioKey)
        defaults.set(false, forKey: ListenPreferences.separatesVoicesKey)
        defaults.set(ListenSource.microphone.rawValue, forKey: ListenSource.key)
        defer {
            Microphone.debugFile = nil
            ListenLanguage.override = nil
            defaults.set(kept, forKey: ListenPreferences.keepsAudioKey)
            defaults.set(separated, forKey: ListenPreferences.separatesVoicesKey)
            defaults.set(source, forKey: ListenSource.key)
            window.close()
        }

        await listener.start(in: note.id)
        if listener.languageToInstall != nil {
            return print("SKIP  Écoute : le modèle français n'est pas sur ce Mac (à télécharger depuis l'app)")
        }
        check("Écoute : elle commence", listener.phase == .listening, listener.errorMessage ?? "\(listener.phase)")
        guard listener.phase == .listening else { return }
        let title = view.string
        let transcript = { store.note(note.id)?.transcript?.text ?? "" }
        let marker = transcript()
        var loudest: Float = 0
        var heardWords = false
        var firstWritten: TimeInterval?
        let started = Date.now
        while Date.now.timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .milliseconds(100))
            loudest = max(loudest, listener.levels.max() ?? 0)
            if !listener.words.isEmpty { heardWords = true }
            if firstWritten == nil, transcript() != marker { firstWritten = Date.now.timeIntervalSince(started) }
        }
        check("Écoute : le compteur bouge avec la voix", loudest > 0.2, "\(loudest)")
        check("Écoute : les mots en cours s'affichent", heardWords)
        check("Écoute : une phrase finie est écrite pendant l'écoute", firstWritten != nil, transcript())
        print("      première phrase écrite après \(firstWritten.map { String(format: "%.1f s", $0) } ?? "—"), pour \(String(format: "%.1f s", seconds)) de son")
        await listener.stop()
        check("Écoute : arrêtée", listener.phase == .idle && !listener.isActive)
        let text = transcript().folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        print("      transcrit : \(transcript().replacingOccurrences(of: "\n", with: " ⏎ "))")
        check("Écoute : les mots dits sont dans la transcription", ["projet", "rendez-vous", "mardi"].filter { text.contains($0) }.count >= 2, transcript())
        check("Écoute : un silence, un paragraphe", transcript().components(separatedBy: "\n").count >= 3, transcript())
        check("Écoute : le texte de la note reste le sien", store.note(note.id)?.content.text == view.string && view.string == title)
        let attached = store.note(note.id)?.recordings ?? []
        check("Écoute : l'enregistrement est dans la note", attached.count == 1 && !view.string.contains("\u{FFFC}"), attached.joined(separator: ","))
        if let name = attached.first {
            let url = store.attachmentsDirectory(of: note.id).appendingPathComponent(name)
            let length = Recording.seconds(of: url) ?? 0
            check("Écoute : il dure ce qui a été entendu", abs(length - seconds) < 2, String(format: "%.1f s pour %.1f s", length, seconds))
        }
        check("Écoute : plus d'enregistrement en cours", ListeningLedger.item == nil)
    }

    /// Two voices, one after the other, told apart for real: the diarizer's models are downloaded
    /// the first time.
    private static func separation() async {
        guard Voices.isAvailable else { return }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "fr-FR" }
        guard let first = voices.first, let second = voices.first(where: { $0.gender != first.gender && $0.gender != .unspecified }) ?? voices.dropFirst().first else {
            return print("SKIP  Voix : il faut deux voix françaises de synthèse")
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest-voix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            (first, "Bonjour, je présente le budget de l'année et les priorités de l'équipe pour le trimestre."),
            (second, "Merci, j'aimerais revenir sur les embauches prévues et sur le calendrier des livraisons."),
            (first, "Bien sûr, nous en parlerons juste après avoir validé les chiffres du premier semestre."),
            (second, "Parfait, je prends des notes et je vous envoie le compte rendu demain matin."),
        ]
        guard await synthesize(lines.map(\.1), voices: lines.map(\.0), pause: 1, to: file) != nil else { return check("Voix : synthèse", false) }
        let started = Date.now
        do {
            let turns = try await Voices.find(in: file)
            let found = Set(turns.map(\.voice))
            print("      \(found.count) voix trouvées en \(String(format: "%.1f s", Date.now.timeIntervalSince(started))) : \(turns.map { "\($0.voice) \(String(format: "%.1f–%.1f", $0.start, $0.end))" }.joined(separator: ", "))")
            check("Voix : deux voix de synthèse séparées", found.count == 2, "\(found.count)")
        } catch {
            print("SKIP  Voix : modèles indisponibles (\(error.localizedDescription))")
        }
        await Voices.release()
    }

    /// Writes `sentences` said by a French voice to `url`, each followed by `pause` seconds of
    /// silence; the seconds it lasts, or nil without a voice.
    private static func synthesize(_ sentences: [String], voices: [AVSpeechSynthesisVoice]? = nil, pause: Double, to url: URL) async -> Double? {
        guard let voice = AVSpeechSynthesisVoice(language: "fr-FR") else { return nil }
        let writer = Writer(url: url)
        let synthesizer = AVSpeechSynthesizer()
        for (index, sentence) in sentences.enumerated() {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voices?[index] ?? voice
            writer.reset()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                writer.done = { done.resume() }
                synthesizer.write(utterance) { writer.take($0) }
                // A voice that never says it has finished doesn't hold the test.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { writer.finish() }
            }
            writer.silence(pause)
        }
        writer.close()
        return writer.seconds
    }

    /// What the voice says, into a file; `done` once at the end of each sentence.
    private final class Writer: @unchecked Sendable {
        let url: URL
        var done: (() -> Void)?
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var format: AVAudioFormat?
        private var frames: AVAudioFramePosition = 0
        private var finished = false

        init(url: URL) { self.url = url }

        var seconds: Double? { lock.withLock { frames > 0 ? Double(frames) / (format?.sampleRate ?? 1) : nil } }

        func reset() { lock.withLock { finished = false } }

        func take(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return finish() }
            lock.withLock {
                guard !finished else { return }
                if file == nil {
                    file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings, commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    format = pcm.format
                }
                try? file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            }
        }

        /// Seconds of nothing, as a microphone hears between two sentences.
        func silence(_ seconds: Double) {
            lock.withLock {
                guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * format.sampleRate)) else { return }
                buffer.frameLength = buffer.frameCapacity
                // A new buffer is all zeros: silence.
                try? file?.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
        }

        func finish() {
            let first: Bool = lock.withLock {
                defer { finished = true }
                return !finished
            }
            if first { done?() }
        }

        func close() { lock.withLock { file = nil } }
    }
}
#endif
