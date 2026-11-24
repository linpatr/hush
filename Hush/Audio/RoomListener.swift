import AVFoundation
import NoiseKit
import Observation

/// Records the room for a few seconds and measures its spectrum. Nothing is saved: samples go straight
/// into the analyzer and are dropped.
@MainActor
@Observable
final class RoomListener {
    enum Failure: Equatable {
        case microphoneDenied
        case noMicrophone
        case other(String)
    }

    /// 0 to 1 while listening, nil otherwise.
    private(set) var progress: Double?
    /// The spectrum so far, updated while listening.
    private(set) var liveBands: [Float]?
    private(set) var failure: Failure?

    /// The session takes a moment to settle after the microphone opens, so the start is thrown away.
    private let settle = 0.4

    /// Listens for `seconds` and returns the room's profile, or nil if it failed (see `failure`).
    /// The caller must have stopped its own playback first.
    func listen(seconds: Double) async -> RoomProfile? {
        failure = nil
        liveBands = nil
        progress = 0
        defer { progress = nil }

        let profile = await record(seconds: seconds)
        #if targetEnvironment(simulator)
        // The Simulator often has no working microphone. Use the built-in test room so the rest can be tried.
        if profile == nil, failure != .microphoneDenied, !Task.isCancelled {
            failure = nil
            return await simulate(seconds: seconds)
        }
        #endif
        return profile
    }

    private func record(seconds: Double) async -> RoomProfile? {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable else {
            failure = .noMicrophone
            return nil
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            failure = .microphoneDenied
            return nil
        }

        do {
            // Measurement mode turns off the processing iOS normally applies to the microphone
            // (automatic gain, voice filtering), which would change the spectrum.
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
            try session.setActive(true)
        } catch {
            failure = .other(error.localizedDescription)
            return nil
        }
        defer {
            try? session.setCategory(.playback, mode: .default)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failure = .noMicrophone
            return nil
        }
        let collector = Collector(sampleRate: format.sampleRate, skip: Int(settle * format.sampleRate))
        Self.installTap(on: input, format: format, collector: collector)
        defer {
            input.removeTap(onBus: 0)
            engine.stop()
        }
        do {
            try engine.start()
        } catch {
            failure = .other(error.localizedDescription)
            return nil
        }

        let started = Date()
        while collector.seconds < seconds {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return nil }
            progress = min(1, collector.seconds / seconds)
            liveBands = collector.bands()
            // Give up if the samples stop coming.
            if Date().timeIntervalSince(started) > seconds + 4 { break }
        }

        // Pure digital silence means the input is dead: a real microphone always has some hiss.
        guard let profile = collector.profile(), profile.level > -150 else {
            failure = .noMicrophone
            return nil
        }
        liveBands = profile.bands
        return profile
    }

    /// Built outside the main actor: the tap block runs on an audio thread.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, collector: Collector) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            collector.append(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
    }

    #if targetEnvironment(simulator)
    private func simulate(seconds: Double) async -> RoomProfile? {
        let rate = 48_000.0
        let samples = await Task.detached { TestRoom.samples(sampleRate: rate, seconds: seconds) }.value
        let collector = Collector(sampleRate: rate, skip: 0)
        let step = Int(rate * 0.25)
        var position = 0
        while position < samples.count {
            let end = min(samples.count, position + step)
            samples[position ..< end].withUnsafeBufferPointer { collector.append($0) }
            position = end
            progress = Double(position) / Double(samples.count)
            liveBands = collector.bands()
            try? await Task.sleep(for: .milliseconds(Int(250 * min(1, 2 / seconds))))
            if Task.isCancelled { return nil }
        }
        return collector.profile(simulated: true)
    }
    #endif
}

/// The analyzer behind a lock: the microphone fills it from an audio thread while the screen reads it.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private let analyzer: RoomAnalyzer
    private var skip: Int

    init(sampleRate: Double, skip: Int) {
        analyzer = RoomAnalyzer(sampleRate: sampleRate)
        self.skip = skip
    }

    func append(_ buffer: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        if skip >= buffer.count {
            skip -= buffer.count
            return
        }
        analyzer.append(UnsafeBufferPointer(rebasing: buffer[skip...]))
        skip = 0
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return analyzer.seconds
    }

    func bands() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return analyzer.bands()
    }

    func profile(simulated: Bool = false) -> RoomProfile? {
        lock.lock()
        defer { lock.unlock() }
        return analyzer.profile(simulated: simulated)
    }
}
