#if DEBUG
import AVFoundation
import UIKit

/// Debug builds only, on iPhone: `-photos 5` opens the first note of the list with that many
/// pictures in its album; with `-blank YES`, a new empty note instead; with `-later YES`, the
/// pictures come once the note is on screen, as when they're picked in Photos; `-note Livres`
/// picks the note. `-listening YES`: the first note opened, listening in it — two sentences
/// heard, words in flight, its transcript shown. `-recording YES`: a new note, a listening of two
/// voices ended in it — its recording in the note's section and open in the player, 42 s in
/// (`-tab transcript`: that tab shown; `-nameVoices YES`: naming the voices).
extension DebugLaunch {
    @MainActor
    static func startIOS() {
        if isDemo, UserDefaults.standard.bool(forKey: "recording") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { recordedNote() }
        }
        if isDemo, UserDefaults.standard.bool(forKey: "listening") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let note = NoteStore.shared.notes.first(where: { $0.deleted == nil && !$0.archived && !$0.isReadOnly }) else { return }
                NotesModel.shared.select(note.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let listener = Listener.shared
                    listener.pretend(in: note.id, words: "et pour la suite nous verrons avec l'équipe", levels: [0.2, 0.55, 0.8, 0.45, 0.65],
                                     startedAt: .now.addingTimeInterval(-134))
                    listener.pretendHeard("Le budget de l'année est validé.", from: 0, to: 2)
                    listener.pretendHeard("On se revoit mardi avec les maquettes.", from: 2.4, to: 4)
                }
            }
        }
        let photos = UserDefaults.standard.integer(forKey: "photos")
        guard isDemo, photos > 0 else { return }
        if UserDefaults.standard.bool(forKey: "blank") { NotesModel.shared.newNote(in: nil) }
        // `-note Livres`: the note whose title starts so.
        let title = UserDefaults.standard.string(forKey: "note") ?? ""
        guard let note = NoteStore.shared.note(NotesModel.shared.selectedID)
            ?? NoteStore.shared.notes.first(where: { $0.deleted == nil && !$0.archived && $0.title.hasPrefix(title) }) else { return }
        NotesModel.shared.select(note.id)
        let later = UserDefaults.standard.bool(forKey: "later")
        DispatchQueue.main.asyncAfter(deadline: .now() + (later ? 1.5 : 0)) { addPictures(photos, to: note.id) }
    }

    @MainActor
    private static func recordedNote() {
        NotesModel.shared.newNote(in: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let id = NotesModel.shared.selectedID else { return }
            let listener = Listener.shared
            listener.pretend(in: id)
            listener.pretendHeard("Le budget de l'année est validé.", from: 0, to: 2)
            listener.pretendHeard("Et pour les embauches ?", from: 2.4, to: 4)
            listener.pretendHeard("Deux personnes au printemps, une à l'automne.", from: 7, to: 10)
            // Three minutes of a soft tone: the player is heard.
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("demo-\(UUID().uuidString).aac")
            if let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
               let recorder = try? Recorder(url: file, format: format),
               let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 60), let samples = buffer.int16ChannelData?[0] {
                buffer.frameLength = buffer.frameCapacity
                for index in 0..<Int(buffer.frameLength) { samples[index] = Int16(1_500 * sin(Double(index) * 2 * .pi * 440 / 16_000)) }
                for _ in 0..<3 { recorder.write(buffer) }
                recorder.close()
            }
            Task { @MainActor in
                await listener.endPretending(speakers: ["Voix 1", "Voix 2", "Voix 1"], files: [file])
                if let note = NoteStore.shared.note(id), let name = note.recordings.first {
                    AudioPlayback.shared.open(NoteStore.shared.attachmentsDirectory(of: id).appendingPathComponent(name), of: id, at: 42)
                }
                if let tab = UserDefaults.standard.string(forKey: "tab").flatMap(NotePart.init) { NoteTabs.shared.show(tab, in: id) }
                if UserDefaults.standard.bool(forKey: "nameVoices") {
                    RecordingRequests.shared.naming = .init(voices: ["Voix 1", "Voix 2"]) { _ in }
                }
            }
        }
    }

    @MainActor
    private static func addPictures(_ photos: Int, to id: UUID) {
        for index in 0..<photos {
            let hue = CGFloat(index) / CGFloat(photos)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
                UIColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
            if let data = image.pngData() { NoteStore.shared.addPhoto(data, named: "Photo \(index + 1).png", to: id) }
        }
    }
}
#endif
