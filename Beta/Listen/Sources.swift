import Accelerate
import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// What the listening hears: the microphone, the Mac's own sound (a call, a video), or both. The
/// iPhone can't hear another app's sound: it listens to the microphone.
enum ListenSource: String, CaseIterable, Identifiable {
    case microphone, mac, both

    var id: String { rawValue }

    static let key = "listenSource"

    /// The one chosen (Réglages → Écoute, or the note's listening menu).
    static var current: ListenSource {
        #if os(macOS)
        UserDefaults.standard.string(forKey: key).flatMap(ListenSource.init) ?? .microphone
        #else
        .microphone
        #endif
    }

    /// The choices of this device.
    static var choices: [ListenSource] {
        #if os(macOS)
        allCases
        #else
        [.microphone]
        #endif
    }

    var label: String {
        switch self {
        case .microphone: String(localized: "Micro")
        case .mac: String(localized: "Son du Mac")
        case .both: String(localized: "Micro et son du Mac")
        }
    }

    /// In the note's listening options, side by side.
    var shortLabel: String {
        switch self {
        case .microphone: String(localized: "Micro")
        case .mac: String(localized: "Son du Mac")
        case .both: String(localized: "Les deux")
        }
    }

    var channels: [ListenChannel] {
        switch self {
        case .microphone: [.microphone]
        case .mac: [.mac]
        case .both: [.microphone, .mac]
        }
    }
}

/// One of the sounds heard, with its own transcriber and its own recording.
enum ListenChannel: String, Sendable, Hashable {
    case microphone, mac
}

/// What the listening keeps, besides the words (Réglages → Écoute).
enum ListenPreferences {
    static let keepsAudioKey = "listenKeepsAudio"
    static let separatesVoicesKey = "listenSeparatesVoices"

    /// The sound, compressed, joined to the note. On by default.
    static var keepsAudio: Bool { UserDefaults.standard.object(forKey: keepsAudioKey) as? Bool ?? true }
    /// The voices told apart once the listening ends, where it can be. On by default.
    static var separatesVoices: Bool { UserDefaults.standard.object(forKey: separatesVoicesKey) as? Bool ?? true }
}

/// Something that hands over sound while it runs, each buffer already in the transcriber's
/// format, on its own thread, with the host time its first sample was heard at.
protocol AudioInput: AnyObject {
    func start() throws
    func stop()
    /// Loudness of what is heard now, 0...1.
    var level: Float { get }
    /// The loudest heard since it started: a Mac whose sound stays silent for a whole listening
    /// almost always means the permission was refused — the system then hands over silence, not
    /// an error.
    var loudest: Float { get }
}

/// Loudness on a 0...1 scale that suits the eye (Cairn's): RMS in decibels, -55 dB as silence
/// and -10 dB as full. Of the first channel, or of the samples as they come when interleaved.
func audioLevel(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var rms: Float = 0
    vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
    let db = 20 * log10(max(rms, 1e-7))
    return min(1, max(0, (db + 55) / 45))
}

/// The meter's two numbers, shared between the audio thread and the main one.
final class SoundLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Float = 0
    private var top: Float = 0

    var level: Float { lock.withLock { current } }
    var loudest: Float { lock.withLock { top } }

    func take(_ buffer: AVAudioPCMBuffer) {
        let level = audioLevel(buffer)
        lock.withLock {
            current = level
            top = max(top, level)
        }
    }

    func reset() { lock.withLock { current = 0 } }
}

// MARK: - Microphone

/// The default input, through AVAudioEngine. Each buffer leaves the tap already in the
/// transcriber's format.
final class Microphone: AudioInput, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let target: AVAudioFormat
    private let onBuffer: (AVAudioPCMBuffer, UInt64) -> Void
    private let meter = SoundLevel()
    private var running = false
    /// The node the tap is on: the input — or, in the self-test, the player.
    private var tapped: AVAudioNode?

    #if DEBUG
    /// Debug builds only: a recording played as if it were the microphone (the self-test). No
    /// permission is asked; nothing is heard on the speakers.
    nonisolated(unsafe) static var debugFile: URL?
    #endif

    init(target: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void) {
        self.target = target
        self.onBuffer = onBuffer
    }

    var level: Float { meter.level }
    var loudest: Float { meter.loudest }
    var isRunning: Bool { engine.isRunning }

    static func requestAccess() async -> Bool {
        #if DEBUG
        if debugFile != nil { return true }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        #if os(iOS)
        try Self.activateSession()
        #endif
        try tapAndStart()
        running = true
    }

    /// With a new engine, which reads the input's format of now: it changes with a headset, or
    /// after a call, and a tap left at the old rate would stop the app.
    func restart() throws {
        guard running else { return }
        tapped?.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        do {
            #if os(iOS)
            try Self.activateSession()
            #endif
            try tapAndStart()
        } catch {
            tapped?.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard running else { return }
        running = false
        tapped?.removeTap(onBus: 0)
        tapped = nil
        engine.stop()
        meter.reset()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func tapAndStart() throws {
        #if DEBUG
        if let file = Self.debugFile { return try play(file) }
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenError.noMicrophone }
        tap(input, format: format)
        engine.prepare()
        try engine.start()
    }

    private func tap(_ node: AVAudioNode, format: AVAudioFormat) {
        let converter = StreamConverter(from: format, to: target)
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.meter.take(buffer)
            let heard = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            if let converted = converter.convert(buffer) { self.onBuffer(converted, heard) }
        }
        tapped = node
    }

    #if DEBUG
    private func play(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        engine.mainMixerNode.outputVolume = 0
        player.scheduleFile(file, at: nil)
        tap(player, format: file.processingFormat)
        engine.prepare()
        try engine.start()
        player.play()
    }
    #endif

    #if os(iOS)
    /// Records with the screen locked too (`UIBackgroundModes` audio). The iPhone refuses
    /// `.spokenAudio` with `.record`: the default mode.
    private static func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            // A call that rings and is declined leaves the listening alone.
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
        } catch {
            let code = (error as NSError).code
            switch AVAudioSession.ErrorCode(rawValue: code) {
            case .insufficientPriority, .cannotInterruptOthers, .isBusy, .siriIsRecording, .cannotStartRecording:
                throw ListenError.microphoneBusy
            default:
                throw ListenError.audioSession(code)
            }
        }
    }
    #endif
}

// MARK: - The Mac's sound

#if os(macOS)
/// Everything the Mac plays, through a Core Audio process tap (Cairn's): a Teams, Meet or Zoom
/// call is heard whichever app or browser tab plays it, without joining it and without the screen
/// recording permission — macOS asks only for "system audio recording". The tap leaves out this
/// app, and is wrapped in a private aggregate device, which gives it a clock and a callback.
@available(macOS 14.2, *)
final class MacSound: AudioInput, @unchecked Sendable {
    private let target: AVAudioFormat
    private let onBuffer: (AVAudioPCMBuffer, UInt64) -> Void
    private let meter = SoundLevel()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.void.notes.beta.mac-sound", qos: .userInitiated)

    init(target: AVAudioFormat, onBuffer: @escaping (AVAudioPCMBuffer, UInt64) -> Void) {
        self.target = target
        self.onBuffer = onBuffer
    }

    var level: Float { meter.level }
    var loudest: Float { meter.loudest }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Void Notes Beta"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw ListenError.macSound("tap", status) }
        tapID = tap

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw ListenError.macSound("format", status)
        }

        let outputUID: String
        do {
            outputUID = try Self.defaultOutputDeviceUID()
        } catch {
            stop()
            throw error
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Void Notes Beta",
            kAudioAggregateDeviceUIDKey: "app.void.notes.beta.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else {
            stop()
            throw ListenError.macSound("aggregate", status)
        }
        aggregateID = aggregateDevice

        // The buffer belongs to Core Audio for the call only: it is converted (a copy) at once.
        let converter = StreamConverter(from: format, to: target)
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            self.meter.take(buffer)
            let stamp = inputTime.pointee
            let heard = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
            if let converted = converter.convert(buffer) { self.onBuffer(converted, heard) }
        }
        guard status == noErr else {
            stop()
            throw ListenError.macSound("io", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw ListenError.macSound("start", status)
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        meter.reset()
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw ListenError.macSound("output", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else { throw ListenError.macSound("output uid", status) }
        return value as String
    }
}
#endif

// MARK: - One clock

/// A source's sound on the listening's clock. Each source starts when its transcriber is ready,
/// and the Mac's sound comes only while something plays: the silence missing before a buffer is
/// put back, so that the sources line up — in the recording, where they are mixed, and in the
/// times of the sentences. Used on the source's own thread only.
final class SoundClock: @unchecked Sendable {
    /// When the listening started (host time).
    private let start: UInt64
    private let format: AVAudioFormat
    /// Frames handed over so far, silence included.
    private var frames: AVAudioFramePosition = 0

    /// Less missing than this is the buffers' jitter (or the clocks drifting), not a silence.
    static let slack: TimeInterval = 0.25

    init(start: UInt64, format: AVAudioFormat) {
        self.start = start
        self.format = format
    }

    /// The silence missing before `buffer`, heard at `hostTime` — in pieces of a second at most —,
    /// then `buffer`.
    func aligned(_ buffer: AVAudioPCMBuffer, heardAt hostTime: UInt64) -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        if hostTime > start {
            let due = AVAudioFramePosition(AVAudioTime.seconds(forHostTime: hostTime - start) * format.sampleRate)
            var missing = due - frames
            if Double(missing) > Self.slack * format.sampleRate {
                while missing > 0, let piece = silence(min(missing, AVAudioFramePosition(format.sampleRate))) {
                    out.append(piece)
                    frames += AVAudioFramePosition(piece.frameLength)
                    missing -= AVAudioFramePosition(piece.frameLength)
                }
            }
        }
        frames += AVAudioFramePosition(buffer.frameLength)
        return out + [buffer]
    }

    private func silence(_ count: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
        }
        return buffer
    }
}

// MARK: - Conversion

/// Converts a stream of buffers (any channels, any rate, interleaved or not) to one format,
/// keeping the resampler's state between buffers so there is no click at every seam. Each output
/// is a new buffer: the source's own is only lent for the call.
final class StreamConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat

    init(from source: AVAudioFormat, to target: AVAudioFormat) {
        self.target = target
        converter = AVAudioConverter(from: source, to: target)
        // Several channels (stereo, a USB interface): their average, not the first one alone.
        converter?.downmix = true
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if handed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
