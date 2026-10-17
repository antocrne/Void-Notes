import AVFoundation
import Speech

/// One listening: its sources — the microphone, the Mac's sound, or both —, each read by a
/// transcriber of its own as it goes, and written to a file if the sound is kept. Taken from
/// Cairn's, made lighter for Void Notes:
/// - each buffer is converted once, where it arrives, straight to what the transcriber reads
///   (one channel at its rate); the same buffer is what is recorded;
/// - the recording is AAC at 24 kbit/s, 16 kHz (`Recording`);
/// - the models are let go as soon as the listening ends, rather than kept in memory;
/// - fast results: the words come as they are said, not by long stretches.
@available(macOS 26, iOS 26, *)
final class ListeningSession: @unchecked Sendable {
    /// One source: what hears it, what reads it, where it is written.
    final class Channel: @unchecked Sendable {
        let kind: ListenChannel
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        var input: AudioInput?
        let recorder: Recorder?
        var results: Task<Void, Never>?

        init(kind: ListenChannel, analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, recorder: Recorder?) {
            self.kind = kind
            self.analyzer = analyzer
            self.continuation = continuation
            self.recorder = recorder
        }

        func stop() async {
            input?.stop()
            continuation.finish()
            recorder?.close()
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
            await results?.value
        }

        func cancel() async {
            input?.stop()
            continuation.finish()
            recorder?.close()
            await analyzer.cancelAndFinishNow()
            results?.cancel()
        }
    }

    private(set) var channels: [Channel]

    private init(channels: [Channel]) {
        self.channels = channels
    }

    /// Loudness of what is heard now, 0...1: the loudest source.
    var level: Float { channels.compactMap { $0.input?.level }.max() ?? 0 }

    /// The files being written, by source.
    var recordings: [ListenChannel: URL] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { channel in channel.recorder.map { (channel.kind, $0.url) } })
    }

    /// The Mac's sound was heard: louder than silence at least once.
    var macWasHeard: Bool {
        channels.first { $0.kind == .mac }.map { ($0.input?.loudest ?? 0) > 0.05 } ?? true
    }

    /// Starts listening to `source`. A final result is a sentence or so the transcriber won't
    /// revise, with when its first word starts and its last one ends (seconds since the start); a
    /// volatile one is its guess at the words still being said. `recordings`: the folder the sound
    /// is written to, or nil not to keep it. `warning`: the Mac's sound could not be heard, and
    /// the listening goes on with the microphone alone.
    static func start(locale: Locale, source: ListenSource, recordings folder: URL?,
                      onFinal: @escaping @MainActor (ListenChannel, String, TimeInterval, TimeInterval) -> Void,
                      onVolatile: @escaping @MainActor (ListenChannel, String) -> Void,
                      warning: @escaping @MainActor (Error) -> Void) async throws -> ListeningSession {
        var started: [Channel] = []
        // The sources' common clock: each one's sound is laid on it (`SoundClock`).
        let start = mach_absolute_time()
        for kind in source.channels {
            do {
                let channel = try await open(kind, start: start, locale: locale, recordings: folder, onFinal: onFinal, onVolatile: onVolatile)
                started.append(channel)
            } catch {
                // The Mac's sound failing is no reason to lose the listening: it goes on with the
                // microphone, and says what is missing.
                if kind == .mac, !started.isEmpty {
                    await warning(error)
                } else {
                    for channel in started { await channel.cancel() }
                    throw error
                }
            }
        }
        return ListeningSession(channels: started)
    }

    private static func open(_ kind: ListenChannel, start: UInt64, locale: Locale, recordings folder: URL?,
                             onFinal: @escaping @MainActor (ListenChannel, String, TimeInterval, TimeInterval) -> Void,
                             onVolatile: @escaping @MainActor (ListenChannel, String) -> Void) async throws -> Channel {
        // `.fastResults`: without it the transcriber reads in long stretches, and the first words
        // came after 12 s, a sentence ended in silence only at the next stretch (measured on
        // 2026-10-14 with the same speech: 35 results either way, so no more work). With it, the
        // words in flight come every second, and a sentence is written about 3 s after it ends.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ListenError.unsupported(locale.identifier)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let recorder = try folder.map { try Recorder(url: $0.appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString.prefix(8)).aac"), format: format) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let channel = Channel(kind: kind, analyzer: analyzer, continuation: continuation, recorder: recorder)
        channel.results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        await onVolatile(kind, "")
                        // When its first word starts and its last one ends: the result's own range
                        // runs on from the previous one, silence included.
                        let words = result.text.runs.compactMap(\.audioTimeRange)
                        let start = words.first?.start.seconds ?? result.range.start.seconds
                        let end = words.last?.end.seconds ?? result.range.end.seconds
                        if !text.isEmpty { await onFinal(kind, text, start, end) }
                    } else {
                        await onVolatile(kind, text)
                    }
                }
            } catch {
                // The results end with an error only when the analysis is cancelled; what was
                // final by then has been handed over.
            }
        }
        try await analyzer.start(inputSequence: stream)

        let clock = SoundClock(start: start, format: format)
        let take: (AVAudioPCMBuffer, UInt64) -> Void = { [weak recorder] buffer, heard in
            for piece in clock.aligned(buffer, heardAt: heard) {
                continuation.yield(AnalyzerInput(buffer: piece))
                recorder?.write(piece)
            }
        }
        let input: AudioInput
        switch kind {
        case .microphone:
            input = Microphone(target: format, onBuffer: take)
        case .mac:
            #if os(macOS)
            input = MacSound(target: format, onBuffer: take)
            #else
            throw ListenError.noMicrophone
            #endif
        }
        channel.input = input
        do {
            try input.start()
        } catch {
            await channel.cancel()
            if let recorder { try? FileManager.default.removeItem(at: recorder.url) }
            throw error
        }
        return channel
    }

    /// Makes final what was being said, without ending the listening: before a pause of the
    /// microphone (a call on the iPhone), so the words before it aren't joined to those after.
    func settle() async {
        for channel in channels { try? await channel.analyzer.finalize(through: nil) }
    }

    private var microphone: Microphone? { channels.lazy.compactMap { $0.input as? Microphone }.first }

    /// Takes the microphone again: after a call, or when the input changed (a headset).
    func resume() throws {
        try microphone?.restart()
    }

    /// Sound comes in from the microphone (or there is none to wait for).
    var isHearing: Bool { microphone?.isRunning ?? true }

    /// Ends the listening and waits until the last words are final.
    func stop() async {
        await withTaskGroup(of: Void.self) { group in
            for channel in channels { group.addTask { await channel.stop() } }
        }
    }

    func cancel() async {
        for channel in channels { await channel.cancel() }
    }
}
