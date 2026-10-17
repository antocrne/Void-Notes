import Foundation
#if os(macOS)
import FoundationModels
import SwiftUI

/// What a summary of a note says, in paragraphs — no lists (the user asked, 2026-10-15: no key
/// points, no actions), and as long as what was said asks (an hour isn't six sentences): the
/// whole in brief, then, for a long listening, a paragraph for each of its parts, in order. The
/// tab says « Résumé ».
struct NoteSummary: Equatable {
    var brief: String
    var parts: [String] = []

    /// As Markdown, made note by `NoteMarkdown`: a paragraph a line.
    var markdown: String { ([brief] + parts).joined(separator: "\n") }
}

// MARK: - The summaries of the notes

/// Summarises a note's transcript on the device (Apple Intelligence), asked from its tabs: the
/// summary goes in the « Résumé » tab — in place of the one written before —, which opens. What
/// one wrote in the note counts first, as in Cairn.
@MainActor @Observable
final class NoteSummaries {
    static let shared = NoteSummaries()

    /// The note being summarised.
    private(set) var working: UUID?
    /// What is being done, beside the tabs.
    private(set) var step = ""
    /// Why the summary couldn't be written.
    var errorMessage: String?

    /// This Mac's system can summarise (macOS 26); whether Apple Intelligence is on is said on
    /// trying.
    static var isAvailable: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    /// A transcript shorter than this has nothing to summarise.
    static let shortest = 80

    func summarize(_ id: UUID) {
        guard #available(macOS 26, *), working == nil else { return }
        let listener = Listener.shared
        let transcript = Self.plain(listener.text(of: id, part: .transcript))
        // What one wrote in the note, after its title.
        let written = listener.text(of: id, part: .notes)
        let title = TranscriptText.partStart(of: .summary, in: written.string as NSString)
        let notes = Self.plain(written.attributedSubstring(from: NSRange(location: title, length: written.length - title)))
        let speakers = listener.voices(in: id)
        guard transcript.count >= Self.shortest else {
            errorMessage = SummaryError.empty.localizedDescription
            return
        }
        working = id
        step = String(localized: "Résumé en cours…")
        Task {
            defer {
                working = nil
                step = ""
            }
            do {
                let summary = try await Summarizer().summarize(transcript, notes: notes, speakers: speakers) { step in self.step = step }
                listener.replace(id, part: .summary, with: NoteMarkdown.content(fromMarkdown: summary.markdown))
                NoteTabs.shared.show(.summary, in: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The words of a part, without its files.
    static func plain(_ text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SummaryError: LocalizedError {
    case unavailable(String)
    case refused
    case empty
    case unreadable

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case .refused: String(localized: "Apple Intelligence a refusé de résumer un passage de cette note.")
        case .empty: String(localized: "Il n'y a pas encore assez de texte à résumer dans cette note.")
        case .unreadable: String(localized: "Apple Intelligence n'a pas rendu de résumé lisible. Réessayez.")
        }
    }
}

// MARK: - The model

/// Apple Intelligence on this Mac, as Cairn's `AppleScribe` (2026-09), made lighter: no project,
/// no subjects, no other engine. Nothing leaves the Mac.
///
/// The on-device model reads 4,096 tokens, instructions and answer included — about ten minutes
/// of talk. Longer, the transcript is read in passages: each becomes a paragraph of the summary,
/// in order, and the model writes the brief of the whole from those paragraphs.
///
/// Answers are plain text under fixed headings, read back by `SummaryText`: in structured
/// generation the small model kept writing until the cap, and invented (Cairn).
@available(macOS 26, *)
struct Summarizer {
    /// Tokens of transcript per call, leaving room for the instructions, the format and the answer.
    /// `VOID_PASSAGE_BUDGET` (debug builds) lowers it, so a short test goes through the passages.
    static var passageBudget: Int {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["VOID_PASSAGE_BUDGET"].flatMap(Int.init) { return value }
        #endif
        return 2_200
    }

    /// Summarising someone's words is transforming them, what the permissive guardrails are for:
    /// the default ones refuse a passage now and then for a word out of context.
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    /// In the language of the app: the summary is written in it, whatever the transcript's.
    var prompts = SummaryPrompts.current

    static func availability() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Apple Intelligence est désactivé. Activez-le dans les Réglages Système pour résumer sur le Mac.")
        case .unavailable(.modelNotReady): String(localized: "Le modèle d'Apple Intelligence est encore en cours de téléchargement. Réessayez dans un moment.")
        case .unavailable(.deviceNotEligible): String(localized: "Ce Mac ne peut pas faire tourner Apple Intelligence.")
        case .unavailable: String(localized: "Apple Intelligence n'est pas disponible pour l'instant.")
        }
    }

    /// `notes`: what was written in the note besides; `speakers`: the names before the lines of
    /// the transcript, in order — none when nobody is told apart.
    func summarize(_ transcript: String, notes: String = "", speakers: [String], progress: @escaping @MainActor (String) -> Void) async throws -> NoteSummary {
        let text = prompts
        let who = text.speakers(speakers)
        let written = String(notes.prefix(1_600))
        let hand = written.isEmpty ? "" : "\n\n\(text.notes)\n\(written)"
        if let reason = Self.availability() { throw SummaryError.unavailable(reason) }
        let lines = transcript.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw SummaryError.empty }
        let whole = lines.joined(separator: "\n")

        let size = try await tokens(whole)
        if size + (try await tokens(written)) <= Self.passageBudget {
            // Short enough to read at once, what the model does best: one paragraph, as long as
            // the transcript asks.
            let sentences = SummaryText.sentences(for: size)
            let answer = try await respond("\(who)\n\n\(text.transcript)\n\(whole)\(hand)\n\n\(text.summarize)\n\n\(text.essentials(sentences))", limit: 120 + 45 * sentences)
            return NoteSummary(brief: try paragraph(answer, heading: text.briefHeading, sentences: sentences + 2))
        }

        // Longer: each passage, about ten minutes, its paragraph; then the brief of the whole.
        let passages = try await pack(lines, budget: Self.passageBudget)
        var parts: [String] = []
        for (index, passage) in passages.enumerated() {
            await progress(String(localized: "Lecture, passage \(index + 1) sur \(passages.count)…"))
            let before = parts.last.map { "\n\n\(text.previous)\n\($0)" } ?? ""
            let answer = try await respond("\(who)\(before)\n\n\(text.passageIntro)\n\n\(passage)\n\n\(text.passage)", limit: 420)
            if let part = try? paragraph(answer, heading: text.partHeading, sentences: SummaryText.passageSentences + 4) { parts.append(part) }
        }
        guard !parts.isEmpty else { throw SummaryError.unreadable }
        await progress(String(localized: "Rédaction du résumé…"))
        // The parts, shortened to their first sentences when together they don't fit.
        var outline = parts
        var kept = SummaryText.passageSentences + 4
        while kept > 1, try await tokens(outline.joined(separator: "\n")) > Self.passageBudget {
            kept -= 1
            outline = parts.map { SummaryText.paragraph($0, sentences: kept) }
        }
        // The brief of the whole stays short: the parts say the rest.
        let sentences = min(5, 2 + passages.count / 3)
        let answer = try await respond("\(who)\n\n\(text.parts)\n\(outline.joined(separator: "\n"))\(hand)\n\n\(text.overview)\n\n\(text.essentials(sentences))", limit: 120 + 45 * sentences)
        // The small model tends to copy the first part into the brief: what a part says already goes.
        let said = parts.flatMap(SummaryText.sentences(of:))
        let brief = SummaryText.distinct(SummaryText.sentences(of: try paragraph(answer, heading: text.briefHeading, sentences: sentences + 2)), from: said, threshold: 0.7)
        // A brief of one sentence left says nothing the parts don't: the parts alone.
        guard brief.count >= 2 else { return NoteSummary(brief: parts[0], parts: Array(parts.dropFirst())) }
        return NoteSummary(brief: brief.joined(separator: " "), parts: parts)
    }

    /// The paragraph under `heading` in an answer, without its repeats, `sentences` at most.
    private func paragraph(_ answer: String, heading: String, sentences: Int) throws -> String {
        let text = SummaryText.paragraph(SummaryText.body(of: answer, under: heading), sentences: sentences)
        guard !text.isEmpty else { throw SummaryError.unreadable }
        return text
    }

    /// `limit` caps the answer: a model that falls into repeating a line is cut short, and the
    /// repeats are dropped by `SummaryText.distinct`. A fresh session per call: each has the whole
    /// context to itself.
    private func respond(_ prompt: String, limit: Int) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: prompts.instructions)
        do {
            let content = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: limit)).content
            #if DEBUG
            if ProcessInfo.processInfo.environment["VOID_SUMMARY_RAW"] != nil { print("---- réponse brute\n\(content)\n----") }
            #endif
            return content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: throw SummaryError.refused
            case .exceededContextWindowSize: throw SummaryError.unavailable(String(localized: "Un passage est trop long pour le modèle d'Apple."))
            case .unsupportedLanguageOrLocale: throw SummaryError.unavailable(String(localized: "Apple Intelligence ne résume pas dans la langue de cette note."))
            default: throw error
            }
        }
    }

    private func tokens(_ text: String) async throws -> Int {
        guard !text.isEmpty else { return 0 }
        if #available(macOS 26.4, *) { return try await model.tokenCount(for: text) }
        // Before 26.4 the model can't count: about three characters a token, in French.
        return text.count / 3 + 1
    }

    /// Lines packed into passages of at most `budget` tokens, cut only between lines: estimated,
    /// then counted, and halved when the estimate was short.
    private func pack(_ lines: [String], budget: Int) async throws -> [String] {
        var passages: [String] = [], current: [String] = []
        var estimate = 0
        for line in lines {
            let piece = line.count > budget * 3 ? String(line.prefix(budget * 3)) : line
            let cost = max(1, piece.count / 3)
            if !current.isEmpty, estimate + cost > budget {
                passages.append(current.joined(separator: "\n"))
                current = []
                estimate = 0
            }
            current.append(piece)
            estimate += cost
        }
        if !current.isEmpty { passages.append(current.joined(separator: "\n")) }

        var checked: [String] = []
        var queue = passages
        while !queue.isEmpty {
            let passage = queue.removeFirst()
            let parts = passage.components(separatedBy: "\n")
            if parts.count > 1, try await tokens(passage) > budget {
                let half = parts.count / 2
                queue.insert(parts[half...].joined(separator: "\n"), at: 0)
                queue.insert(parts[..<half].joined(separator: "\n"), at: 0)
            } else {
                checked.append(passage)
            }
        }
        return checked
    }
}
#endif

// MARK: - The text asked for, and how it is read

/// What is asked of the model, in the language of the app — the summary is written in it,
/// whatever the transcript's (2026-10-15: an app in English had its summary in French). Told in
/// French « write in English », the small model followed the language of the instructions and the
/// example: each language has its own. Cairn's instructions, for any listening — a meeting, a
/// call, a lesson, a note said aloud.
struct SummaryPrompts {
    var instructions: String
    /// Before what one wrote in the note during the listening.
    var notes: String
    var transcript: String
    var summarize: String
    var passageIntro: String
    var previous: String
    var parts: String
    var overview: String
    var briefHeading: String
    var partHeading: String
    var passage: String
    var essentials: (Int) -> String
    /// Who speaks, told to the model: the names written before the lines — "Voix 1", or the
    /// names given since —, or that nobody is known. Given only the transcript, it took "moi je
    /// finis…" for someone called Moi, and made up "Une personne"; told not to invent names, it
    /// left out Sarah and Julien.
    var speakers: ([String]) -> String

    /// The app's language since launch: French, or English for any other.
    static var current: SummaryPrompts { AppLanguage.shown.hasPrefix("fr") ? french : english }

    static let french = SummaryPrompts(
        instructions: """
        Tu résumes la transcription d'une écoute : une réunion, un appel, un cours ou une note dictée. \
        Tu écris court, sobre et exact, avec des phrases simples.
        Tu t'appuies uniquement sur ce qu'on te donne. Tu n'inventes ni noms, ni dates, ni chiffres, \
        ni tâches. Une date s'écrit comme elle a été dite, sans la compléter ni la changer : « vendredi » reste « vendredi ».
        La transcription vient d'une reconnaissance vocale automatique : corrige en silence les mots \
        mal compris quand le sens est évident.
        Ce qui a été promis n'est pas encore fait : écris-le au futur, jamais au passé composé.
        Ne répète jamais une phrase.
        Écris en français, quelle que soit la langue de la transcription, et garde les titres du format tels quels.
        """,
        notes: "Notes écrites à la main dans la note, ce qui comptait pour la personne : appuie-toi dessus en priorité.",
        transcript: "Transcription :",
        summarize: "Résume cette transcription.",
        passageIntro: "Voici un passage d'une transcription.",
        previous: "Le passage précédent, déjà résumé (ne le répète pas) :",
        parts: "Le résumé de chaque partie, dans l'ordre :",
        overview: "Écris les grandes lignes de l'ensemble : les sujets abordés, de la première partie à la dernière, et ce qui en ressort. Ne reprends pas les phrases des parties et n'entre pas dans le détail : chaque partie a déjà son paragraphe.",
        briefHeading: "EN BREF",
        partHeading: "PARAGRAPHE",
        passage: """
        Résume ce passage avec tes propres mots, sans recopier les répliques : ce qui a été dit, \
        décidé ou prévu, les faits, les chiffres, les raisons, les désaccords, les noms cités.
        Réponds exactement dans ce format, sans rien ajouter :
        PARAGRAPHE
        (un seul paragraphe de cinq à huit phrases, sans liste, qui n'oublie aucun sujet du passage)
        """,
        essentials: { sentences in
            """
            Réponds exactement dans ce format, sans rien ajouter avant ni après :
            EN BREF
            (un seul paragraphe d'environ \(sentences) phrases : l'essentiel de ce qui a été dit, décidé ou prévu, sans liste)

            Exemple de réponse, pour une tout autre transcription :
            EN BREF
            Léa et Marc ont comparé les deux devis pour la cuisine et retiennent celui de l'atelier Morel, plus cher mais livré avant l'été. Le second devis oubliait la pose. Marc enverra l'acompte avant jeudi ; le plan de travail reste à choisir.
            """
        },
        speakers: { names in
            guard let first = names.first else { return "On ne sait pas qui parle : n'écris jamais qui a dit quoi." }
            let list = names.map { "« \($0) »" }.joined(separator: ", ")
            return "Chaque réplique commence par qui parle : \(list). Reprends ces noms tels quels pour dire qui fait quoi, " +
                "dans la phrase (« \(first) propose… »), jamais en tête de ligne avec deux-points. « Je » et « moi » dans une réplique " +
                "désignent la personne qui la dit. Les noms cités dans la conversation (personnes, entreprises, lieux) se gardent tels quels."
        }
    )

    static let english = SummaryPrompts(
        instructions: """
        You summarize the transcript of a recording: a meeting, a call, a lecture or a dictated note. \
        You write briefly, plainly and accurately, in simple sentences.
        You rely only on what you are given. You never invent names, dates, figures or tasks. A date \
        is written as it was said, without completing or changing it: "Friday" stays "Friday".
        The transcript comes from automatic speech recognition: silently fix misheard words when the \
        meaning is obvious.
        What was promised is not done yet: write it in the future tense, never in the past.
        Never repeat a sentence.
        Write in English, whatever the language of the transcript, and keep the headings of the format as they are.
        """,
        notes: "Notes the person wrote in the note, what mattered to them: rely on them first.",
        transcript: "Transcript:",
        summarize: "Summarize this transcript.",
        passageIntro: "Here is a passage of a transcript.",
        previous: "The previous passage, already summarized (do not repeat it):",
        parts: "The summary of each part, in order:",
        overview: "Write the outline of the whole: the subjects discussed, from the first part to the last, and what came out of them. Do not reuse the parts' sentences and do not go into detail: each part already has its own paragraph.",
        briefHeading: "SUMMARY",
        partHeading: "PARAGRAPH",
        passage: """
        Summarize this passage in your own words, without copying the lines: what was said, decided \
        or planned, the facts, the figures, the reasons, the disagreements, the names mentioned.
        Answer exactly in this format, adding nothing:
        PARAGRAPH
        (a single paragraph of five to eight sentences, no list, leaving out none of the passage's subjects)
        """,
        essentials: { sentences in
            """
            Answer exactly in this format, adding nothing before or after:
            SUMMARY
            (a single paragraph of about \(sentences) sentences: the essentials of what was said, decided or planned, no list)

            Example answer, for a completely different transcript:
            SUMMARY
            Lea and Mark compared the two quotes for the kitchen and chose the Morel workshop, more expensive but delivered before summer. The second quote left out the installation. Mark will send the deposit before Thursday; the countertop is still to be chosen.
            """
        },
        speakers: { names in
            guard let first = names.first else { return "Nobody knows who speaks: never write who said what." }
            let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
            return "Each line starts with who speaks: \(list). Use these names as they are to say who does what, " +
                "inside the sentence (\"\(first) suggests…\"), never at the start of a line with a colon. \"I\" and \"me\" in a line " +
                "mean the person saying it. Names mentioned in the conversation (people, companies, places) are kept as they are."
        }
    )
}

/// The reading of the model's answers. Each reading also defends against a sentence repeated
/// until the answer is cut: repeats go, every part has a ceiling.
enum SummaryText {
    /// The sentences a transcript read at once asks for: about one a minute of talk (~200 tokens),
    /// three at least, ten at most.
    static func sentences(for tokens: Int) -> Int { min(10, max(3, tokens / 200)) }

    /// The sentences of a passage's paragraph: about ten minutes of talk.
    static let passageSentences = 8

    private static let french = Locale(identifier: "fr_FR")

    /// An answer split on its uppercase headings.
    static func sections(_ text: String, headings: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var lines: [String] = []
        func close() {
            if let current { out[current] = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            lines = []
        }
        for raw in text.components(separatedBy: "\n") {
            let bare = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*#: ")).uppercased(with: french)
            if let heading = headings.first(where: { $0 == bare }) {
                close()
                current = heading
            } else {
                lines.append(raw)
            }
        }
        close()
        return out
    }

    /// The items of a list, without "aucune", the placeholders copied from the format, repeats,
    /// and no more than `limit`.
    static func items(_ text: String?, limit: Int = 12) -> [String] {
        let nothing: Set<String> = ["aucune", "aucun", "aucune action", "aucune décision", "néant", "rien", "none", "nothing", "n/a"]
        let bare = { (text: String) in text.trimmingCharacters(in: CharacterSet(charactersIn: ".()« »\"")).lowercased() }
        let all = (text ?? "").components(separatedBy: "\n").compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*") else { return nil }
            line = String(line.drop { $0 == "-" || $0 == "•" || $0 == "*" }).trimmingCharacters(in: .whitespaces)
            // "aucune", and "Marc : aucune", which is still nothing.
            let afterName = line.range(of: ": ").map { String(line[$0.upperBound...]) } ?? line
            guard !line.isEmpty, !nothing.contains(bare(line)), !nothing.contains(bare(afterName)), !line.hasPrefix("(") else { return nil }
            // "Oui": a word alone isn't a point, a decision or a task.
            guard afterName.split(separator: " ").count > 1 else { return nil }
            return sentence(line.trimmingCharacters(in: CharacterSet(charactersIn: " .")))
        }
        return Array(distinct(all).prefix(limit))
    }

    /// A paragraph of at most `limit` sentences, without a stray "(…)", quotes, or a sentence
    /// already written.
    static func paragraph(_ text: String?, sentences limit: Int) -> String {
        let flat = (text ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("(") }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " «»\""))
        let sentences = sentences(of: flat)
        // Stricter than for a list: two sentences of a paragraph share more words without saying
        // the same thing.
        return Array(distinct(sentences, threshold: 0.8).prefix(limit)).joined(separator: " ")
    }

    /// What an answer says under `heading` — or, the heading misspelled (« PARAGRAPHUE », seen) or
    /// left out, the answer without its first line when that one is in capitals.
    static func body(of answer: String, under heading: String) -> String {
        if let body = sections(answer, headings: [heading])[heading], !body.isEmpty { return body }
        var lines = answer.components(separatedBy: "\n")
        let first = lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: " *#:")) ?? ""
        if !first.isEmpty, first == first.uppercased(with: french), first.split(separator: " ").count <= 3 { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// The sentences of a text, each with its final mark.
    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?…".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    /// The items of `list` that don't say what an earlier one, or one of `others`, says: the same
    /// words, give or take a few.
    static func distinct(_ list: [String], from others: [String] = [], threshold: Double = 0.6) -> [String] {
        var seen = others.map(words)
        var out: [String] = []
        for item in list {
            let set = words(item)
            if seen.contains(where: { overlap($0, set) >= threshold }) { continue }
            seen.append(set)
            out.append(item)
        }
        return out
    }

    private static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: french)
        return Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
    }

    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        let smaller = min(a.count, b.count)
        return smaller == 0 ? 0 : Double(a.intersection(b).count) / Double(smaller)
    }

    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
