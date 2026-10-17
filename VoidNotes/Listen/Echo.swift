import Foundation

/// A sentence heard, final: from which source, and when it was said (seconds since the listening
/// started, on that source's timeline — both start together).
struct HeardSentence: Equatable {
    var channel: ListenChannel
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// The sentences of two sources, held a moment before they are written: long enough for the
/// other source's sentence of the same moment to come, so that they are written in the order they
/// were said, and the microphone's echo of the Mac's sound is taken out. With one source nothing
/// is held.
struct SentenceQueue {
    /// Seconds a sentence waits, from when it came: a sentence is final about 3 s after it ends,
    /// on either side.
    static let hold: TimeInterval = 4

    var holds: Bool
    var locale: Locale
    private var held: [(sentence: HeardSentence, came: TimeInterval)] = []
    /// The Mac's sentences of late, written or not: what the microphone may have heard again.
    private var macHeard: [HeardSentence] = []

    init(holds: Bool, locale: Locale) {
        self.holds = holds
        self.locale = locale
    }

    var isEmpty: Bool { held.isEmpty }

    mutating func add(_ sentence: HeardSentence, at now: TimeInterval) {
        held.append((sentence, now))
        if sentence.channel == .mac {
            macHeard.append(sentence)
            // A minute back is far more than an echo's delay.
            macHeard.removeAll { $0.end < sentence.start - 60 }
        }
    }

    /// The sentences whose wait is over (all of them, at the end), in the order they were said,
    /// the microphone's without what echoes the Mac.
    mutating func release(at now: TimeInterval, all: Bool = false) -> [HeardSentence] {
        held.sort { $0.sentence.start < $1.sentence.start }
        var out: [HeardSentence] = []
        while let first = held.first, all || !holds || now - first.came >= Self.hold {
            held.removeFirst()
            var sentence = first.sentence
            if sentence.channel == .microphone, !macHeard.isEmpty {
                guard let kept = Echo.removed(from: sentence, heard: macHeard, locale: locale) else { continue }
                sentence.text = kept
            }
            out.append(sentence)
        }
        return out
    }
}

/// The Mac's sound heard a second time through the microphone (Cairn's, 2026-09-15). Without
/// headphones the speakers play the call and the microphone picks it up, a second later, in
/// slightly different words. What the microphone shares with the Mac in the same moments — any
/// run of three words or more said within a few seconds — is taken out of its sentence; what is
/// left is what was said in the room, and a sentence left with almost nothing goes.
enum Echo {
    /// Seconds either side of a sentence in which the Mac's words count.
    static let window: TimeInterval = 8
    /// Shortest run of shared words taken as echo rather than coincidence.
    static let run = 3
    /// A piece left between two runs of echo is kept only if it is at least this long; shorter, it
    /// is the transcriber garbling the same words.
    static let keptPiece = 4

    /// The sentence without its echo; nil when nothing worth keeping is left. Unchanged when it
    /// echoes nothing.
    static func removed(from sentence: HeardSentence, heard: [HeardSentence], locale: Locale) -> String? {
        let nearby = heard.filter { $0.start <= sentence.end + window && $0.end >= sentence.start - window }
        guard !nearby.isEmpty else { return sentence.text }
        let mine = words(sentence.text, locale: locale)
        guard mine.count >= run else {
            // Too short to tell by runs: gone if the Mac said those very words.
            let folded = mine.map(\.folded)
            let theirs = Set(nearby.flatMap { words($0.text, locale: locale).map(\.folded) })
            return !folded.isEmpty && folded.allSatisfy(theirs.contains) ? nil : sentence.text
        }
        let said = Set(grams(nearby.flatMap { words($0.text, locale: locale).map(\.folded) }))

        var echoed = Array(repeating: false, count: mine.count)
        for index in 0...(mine.count - run) {
            let gram = mine[index..<(index + run)].map(\.folded).joined(separator: " ")
            if said.contains(gram) { for covered in index..<(index + run) { echoed[covered] = true } }
        }
        guard echoed.contains(true) else { return sentence.text }

        var pieces: [[String]] = [], current: [String] = []
        for (index, word) in mine.enumerated() {
            if echoed[index] {
                if !current.isEmpty { pieces.append(current) }
                current = []
            } else {
                current.append(word.original)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let kept = pieces.filter { $0.count >= keptPiece }.flatMap { $0 }
        guard kept.count > keptPiece else { return nil }
        let text = kept.joined(separator: " ")
        return text.prefix(1).uppercased(with: locale) + text.dropFirst()
    }

    private struct Word {
        let original: String
        let folded: String
    }

    private static func words(_ text: String, locale: Locale) -> [Word] {
        var out: [Word] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let original = String(token)
            var folded = original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                .trimmingCharacters(in: .punctuationCharacters)
            // A lone "?" or ":", French-spaced, stays with the word before it.
            guard !folded.isEmpty else {
                if let last = out.popLast() { out.append(Word(original: last.original + " " + original, folded: last.folded)) }
                continue
            }
            // One side hears a plural, the other a singular: the same word here.
            if folded.count > 3, folded.hasSuffix("s") || folded.hasSuffix("x") { folded.removeLast() }
            out.append(Word(original: original, folded: folded))
        }
        return out
    }

    private static func grams(_ words: [String]) -> [String] {
        guard words.count >= run else { return [] }
        return (0...(words.count - run)).map { words[$0..<($0 + run)].joined(separator: " ") }
    }
}
