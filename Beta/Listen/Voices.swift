import Foundation
#if canImport(VoidVoices)
import VoidVoices
#endif

/// Telling voices apart, once the listening ends (Cairn's, 2026-09-22, made lighter). The
/// recording of a source is read again on the device: the diarizer says when each voice speaks,
/// the transcriber said when each sentence was, and each sentence goes to the voice heard most
/// while it was said — by sentence, not by word. The names are written into the note, before each
/// sentence whose voice isn't the one before: "Voix 1", "Voix 2", in the order they first speak.
/// With the microphone and the Mac's sound, the microphone is "Moi" and the Mac "Eux" — or its
/// voices, when it carries several. A listening with a single voice gets no names.
enum Voices {
    /// Who spoke from when to when, the voice already numbered.
    struct Turn: Equatable {
        var voice: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// This build can tell voices apart (the Mac: the iPhone doesn't carry the models).
    static var isAvailable: Bool {
        #if canImport(VoidVoices)
        true
        #else
        false
        #endif
    }

    /// The models are on the device already (else the first separation downloads them).
    static var hasModels: Bool {
        #if canImport(VoidVoices)
        VoiceFinder.hasModels
        #else
        false
        #endif
    }

    static func label(_ number: Int) -> String { String(localized: "Voix \(number)") }
    static var me: String { String(localized: "Moi") }
    static var them: String { String(localized: "Eux") }

    /// A voice heard for less than this in all is a cough, or two voices at once counted as a
    /// third: its moments go to nobody.
    static let shortestVoice: TimeInterval = 3
    /// A sentence outside every turn goes to a turn this close; farther, to nobody.
    static let reach: TimeInterval = 1

    /// The turns of each voice in the recording at `url`, numbered.
    static func find(in url: URL) async throws -> [Turn] {
        #if canImport(VoidVoices)
        let turns = try await VoiceFinder.shared.turns(in: url)
        return numbered(turns.map { Turn(voice: $0.voice, start: $0.start, end: $0.end) })
        #else
        return []
        #endif
    }

    /// Lets the models go, once the voices of a listening are found.
    static func release() async {
        #if canImport(VoidVoices)
        await VoiceFinder.shared.release()
        #endif
    }

    /// The turns renamed "Voix 1", "Voix 2" by first appearance, the voices heard too little left
    /// out.
    static func numbered(_ turns: [Turn]) -> [Turn] {
        var talk: [String: TimeInterval] = [:]
        for turn in turns { talk[turn.voice, default: 0] += turn.end - turn.start }
        var names: [String: String] = [:]
        return turns.sorted { $0.start < $1.start }.compactMap { turn in
            guard talk[turn.voice, default: 0] >= shortestVoice else { return nil }
            if names[turn.voice] == nil { names[turn.voice] = label(names.count + 1) }
            var named = turn
            named.voice = names[turn.voice]!
            return named
        }
    }

    /// The voice heard most from `start` to `end`; else the nearest within `reach`.
    static func voice(from start: TimeInterval, to end: TimeInterval, in turns: [Turn]) -> String? {
        var heard: [String: TimeInterval] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            heard[turn.voice, default: 0] += min(turn.end, end) - max(turn.start, start)
        }
        if let most = heard.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) { return most.key }
        let middle = (start + end) / 2
        func distance(_ turn: Turn) -> TimeInterval { middle < turn.start ? turn.start - middle : max(0, middle - turn.end) }
        guard let nearest = turns.min(by: { distance($0) < distance($1) }), distance(nearest) <= reach else { return nil }
        return nearest.voice
    }

    /// Who said each sentence; all nil when fewer than two voices are heard. `microphone` and
    /// `mac`: the turns found in each source's recording, nil when they weren't looked for.
    static func speakers(of sentences: [HeardSentence], microphone: [Turn]?, mac: [Turn]?) -> [String?] {
        let both = Set(sentences.map(\.channel)).count > 1
        let macVoices = Set(mac?.map(\.voice) ?? []).count
        let micVoices = Set(microphone?.map(\.voice) ?? []).count
        let speakers: [String?] = sentences.map { sentence in
            switch sentence.channel {
            case .microphone:
                if both { return me }
                return micVoices > 1 ? voice(from: sentence.start, to: sentence.end, in: microphone ?? []) : nil
            case .mac:
                if macVoices > 1 { return voice(from: sentence.start, to: sentence.end, in: mac ?? []) }
                return both ? them : nil
            }
        }
        return Set(speakers.compactMap { $0 }).count > 1 ? speakers : sentences.map { _ in nil }
    }
}

extension TranscriptText {
    /// A voice's name to write: before the sentence at `location`, on a line of its own when the
    /// sentence is in the middle of a paragraph (`newLine`) — in place of the space before it
    /// (`spaceFollows`: the name is written before that space, which then follows it).
    struct Label: Equatable {
        var location: Int
        var speaker: String
        var newLine: Bool
        var spaceFollows: Bool
    }

    /// Where the voices' names go in `string`: before each sentence whose speaker isn't the one
    /// named before. The sentences are looked for in order from `from` (where the transcript
    /// began), each after the one before; one edited since it was written isn't found, and gets
    /// no name.
    static func labels(for sentences: [String], speakers: [String?], in string: NSString, from start: Int = 0) -> [Label] {
        var out: [Label] = []
        var from = min(max(start, 0), string.length)
        var named: String?
        for (sentence, speaker) in zip(sentences, speakers) {
            let found = string.range(of: sentence, range: NSRange(location: from, length: string.length - from))
            guard found.location != NSNotFound else { continue }
            from = found.upperBound
            guard let speaker, speaker != named else { continue }
            named = speaker
            let before = found.location > 0 ? string.character(at: found.location - 1) : 10
            if before == 10 {
                out.append(Label(location: found.location, speaker: speaker, newLine: false, spaceFollows: false))
            } else if before == 32 {
                out.append(Label(location: found.location - 1, speaker: speaker, newLine: true, spaceFollows: true))
            } else {
                out.append(Label(location: found.location, speaker: speaker, newLine: true, spaceFollows: false))
            }
        }
        return out
    }
}
