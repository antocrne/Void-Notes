import Accelerate
import AudioToolbox
import AVFoundation
import Foundation

/// The sound of a listening, kept light: AAC, one channel, 16 kHz, 24 kbit/s — about 12 MB an
/// hour, five times less than Cairn's two files at 64 kbit/s, and plenty for speech (the
/// transcriber and the voices read it at 16 kHz anyway).
///
/// While listening each source is written as ADTS (`.aac`): frames that carry their own header,
/// readable up to the last one written even if the app is killed (an `.m4a` can be read only once
/// closed). When the listening ends, they become the one `.m4a` joined to the note: the
/// microphone's put into it as it is (the same packets, nothing encoded again), the microphone
/// and the Mac's sound mixed into one.
enum Recording {
    static let sampleRate = 16_000.0
    static let bitRate = 24_000

    static var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: bitRate]
    }

    /// Where the sound of the listenings under way is written: on the device, outside the notes.
    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Listening", isDirectory: true)
    }

    /// Seconds of sound a file holds, or nil when it can't be read.
    static func seconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    enum Failure: Error {
        case audioFile(String, OSStatus)
        case unreadable
    }

    /// The `.m4a` of `sources` (the `.aac` files of a listening), at `target`. Blocking: off the
    /// main thread. Files with no sound in them are left out; nil when none has any.
    static func finish(_ sources: [URL], to target: URL) throws -> URL? {
        let heard = sources.filter { (seconds(of: $0) ?? 0) > 0 }
        switch heard.count {
        case 0: return nil
        case 1: try remux(heard[0], to: target)
        default: try mix(heard, to: target)
        }
        return target
    }

    /// Puts an ADTS file's packets into an MPEG-4 file without encoding them again (Cairn's).
    static func remux(_ source: URL, to target: URL) throws {
        func check(_ status: OSStatus, _ step: String) throws {
            if status != noErr { throw Failure.audioFile(step, status) }
        }
        var inputID: AudioFileID?
        try check(AudioFileOpenURL(source as CFURL, .readPermission, kAudioFileAAC_ADTSType, &inputID), "open")
        guard let input = inputID else { throw Failure.unreadable }
        defer { AudioFileClose(input) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFileGetProperty(input, kAudioFilePropertyDataFormat, &size, &format), "format")

        try? FileManager.default.removeItem(at: target)
        var outputID: AudioFileID?
        try check(AudioFileCreateWithURL(target as CFURL, kAudioFileM4AType, &format, .eraseFile, &outputID), "create")
        guard let output = outputID else { throw Failure.unreadable }
        var closed = false
        defer { if !closed { AudioFileClose(output) } }

        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(input, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            try check(AudioFileGetProperty(input, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie), "cookie")
            try check(AudioFileSetProperty(output, kAudioFilePropertyMagicCookieData, cookieSize, cookie), "cookie")
        }

        var largest: UInt32 = 0
        size = 4
        try check(AudioFileGetProperty(input, kAudioFilePropertyMaximumPacketSize, &size, &largest), "packet size")
        let perRead: UInt32 = 512
        var data = [UInt8](repeating: 0, count: Int(max(largest, 2048) * perRead))
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(perRead))
        var read: Int64 = 0, written: Int64 = 0
        while true {
            var bytes = UInt32(data.count)
            var count = perRead
            let status = AudioFileReadPacketData(input, false, &bytes, &descriptions, read, &count, &data)
            if count == 0 { break }
            // The last frame of a file cut short can be incomplete: what came before is kept.
            if status != noErr, status != kAudioFileEndOfFileError { break }
            var toWrite = count
            try check(AudioFileWritePackets(output, false, bytes, descriptions, written, &toWrite, data), "write")
            read += Int64(count)
            written += Int64(toWrite)
        }
        guard written > 0 else { throw Failure.unreadable }
        try check(AudioFileClose(output), "close")
        closed = true
    }

    /// The files read together, sample by sample, into one: the microphone and the Mac's sound
    /// were written on the listening's clock, silences included (`SoundClock`), so they line up.
    /// A sum that would clip is held at full scale.
    static func mix(_ sources: [URL], to target: URL) throws {
        let inputs = try sources.map { try AVAudioFile(forReading: $0) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { throw Failure.unreadable }
        try? FileManager.default.removeItem(at: target)
        let output = try AVAudioFile(forWriting: target, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 160_000
        let readers = inputs.map { FileReader(file: $0, target: format) }
        guard let sum = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk), let out = sum.floatChannelData?[0] else { throw Failure.unreadable }
        while true {
            let pieces = readers.compactMap { $0.read(chunk) }
            let frames = pieces.map(\.frameLength).max() ?? 0
            if frames == 0 { break }
            sum.frameLength = frames
            out.update(repeating: 0, count: Int(frames))
            for piece in pieces {
                guard let samples = piece.floatChannelData?[0] else { continue }
                vDSP_vadd(samples, 1, out, 1, out, 1, vDSP_Length(piece.frameLength))
            }
            var low: Float = -1, high: Float = 1
            vDSP_vclip(out, 1, &low, &high, out, 1, vDSP_Length(frames))
            try output.write(from: sum)
        }
        // Closed here, its index written: an `.m4a` reads only then.
        if #available(macOS 15, iOS 18, *) { output.close() }
    }

    /// A file read in pieces, in `target`'s format.
    private final class FileReader {
        let file: AVAudioFile
        let converter: AVAudioConverter?
        let target: AVAudioFormat
        var ended = false

        init(file: AVAudioFile, target: AVAudioFormat) {
            self.file = file
            self.target = target
            converter = file.processingFormat == target ? nil : AVAudioConverter(from: file.processingFormat, to: target)
        }

        func read(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
            guard !ended, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
            do { try file.read(into: buffer, frameCount: frames) } catch { ended = true; return nil }
            if buffer.frameLength == 0 { ended = true; return nil }
            guard let converter else { return buffer }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var handed = false
            converter.convert(to: out, error: nil) { _, status in
                if handed { status.pointee = .noDataNow; return nil }
                handed = true
                status.pointee = .haveData
                return buffer
            }
            return out
        }
    }
}

/// One source's sound, written as it comes, on a queue of its own (encoding is not for the audio
/// thread).
final class Recorder: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "app.void.notes.beta.recorder", qos: .utility)
    private var file: AVAudioFile?

    /// `format`: that of the buffers handed over (the transcriber's).
    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var settings = Recording.settings
        // The file's rate is the buffers': a transcriber that reads other than 16 kHz is followed.
        settings[AVSampleRateKey] = format.sampleRate
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in try? file?.write(from: buffer) }
    }

    /// Waits for what is on its way, and closes the file.
    func close() {
        queue.sync {
            if #available(macOS 15, iOS 18, *) { file?.close() }
            file = nil
        }
    }
}

/// The listening under way on this device, kept so that one cut short (a crash, the app killed,
/// the battery) still gives its note the sound, at the next launch.
enum ListeningLedger {
    private static let key = "listeningInProgress"

    struct Item: Codable, Equatable {
        var note: UUID
        var files: [String]
        var started: Date
    }

    static var item: Item? {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Item.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
