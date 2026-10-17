import Foundation
import FluidAudio

/// Who spoke from when to when in a recording, in seconds. `voice` is the diarizer's own name for
/// it: the app numbers the voices itself.
public struct VoiceTurn: Equatable, Sendable {
    public var voice: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(voice: String, start: TimeInterval, end: TimeInterval) {
        self.voice = voice
        self.start = start
        self.end = end
    }
}

/// FluidAudio's offline diarizer (pyannote's segmentation, WeSpeaker embeddings, clustering), on
/// the Neural Engine. Its models (about 20 MB) are fetched once from Hugging Face and kept in the
/// app's container; nothing of the recording leaves the device.
public actor VoiceFinder {
    public static let shared = VoiceFinder()

    private var manager: OfflineDiarizerManager?
    /// The models being fetched or loaded: asked twice meanwhile (during a listening, then at its
    /// end), they are fetched once.
    private var loading: Task<OfflineDiarizerManager, Error>?

    /// Whether the models are on this device already: the first separation downloads them.
    public nonisolated static var hasModels: Bool {
        let directory = OfflineDiarizerModels.defaultModelsDirectory()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return !contents.isEmpty
    }

    /// Loads the models — downloading them the first time.
    public func prepare() async throws {
        guard manager == nil else { return }
        let task = loading ?? Task {
            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await manager.prepareModels()
            return manager
        }
        loading = task
        defer { loading = nil }
        manager = try await task.value
    }

    /// The turns of each voice in the recording at `url`, in order.
    public func turns(in url: URL) async throws -> [VoiceTurn] {
        try await prepare()
        guard let manager else { return [] }
        let result = try await manager.process(url)
        return result.segments
            .map { VoiceTurn(voice: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }

    /// Lets the models go: they are loaded again for the next recording.
    public func release() {
        manager = nil
    }
}
