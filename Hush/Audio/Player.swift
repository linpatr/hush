import AVFoundation
import MediaPlayer
import NoiseKit

/// Owns the audio engine: starts and stops it, feeds it from the synth, and follows what iOS does to the
/// audio session (calls, unplugged headphones, the lock-screen play button).
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var synth = NoiseSynth(sampleRate: 48_000)
    private var sound = Sound(name: "", layers: [])
    private var stopTask: Task<Void, Never>?
    private var resumeAfterInterruption = false

    private(set) var isPlaying = false
    /// Called when playing starts or stops for any reason.
    var onChange: ((Bool) -> Void)?
    /// Set when starting failed; shown to the user.
    private(set) var lastError: String?

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { self?.interrupted(type, shouldResume: options?.contains(.shouldResume) ?? false) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Headphones pulled out or a speaker switched off: stop instead of blasting from the phone.
            if reason == .oldDeviceUnavailable {
                MainActor.assumeIsolated { self?.pause() }
            }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }

        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPlaying { self.pause() } else { self.play() }
            }
            return .success
        }
    }

    /// RMS of what is going out right now. 1 is full scale.
    var outputLevel: Float { isPlaying ? synth.outputLevel : 0 }

    func apply(_ sound: Sound) {
        self.sound = sound
        synth.apply(sound)
        if isPlaying { updateNowPlaying() }
    }

    func play() {
        stopTask?.cancel()
        stopTask = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            buildGraph()
            if !engine.isRunning { try engine.start() }
            synth.setMaster(1, over: 0.8)
            lastError = nil
            setPlaying(true)
        } catch {
            lastError = error.localizedDescription
            setPlaying(false)
        }
    }

    /// Fades out over `fade` seconds, then stops the engine and lets other apps' audio come back.
    func pause(fade: Double = 0.4) {
        guard isPlaying || engine.isRunning else { return }
        synth.setMaster(0, over: fade)
        setPlaying(false)
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(fade + 0.15))
            guard !Task.isCancelled, let self else { return }
            self.stopEngine()
        }
    }

    /// Starts a slow fade without stopping. Used by the sleep timer just before it pauses.
    func fadeOut(over seconds: Double) {
        synth.setMaster(0, over: seconds)
    }

    /// Stops at once and frees the audio session for recording.
    func stopForRecording() async {
        if isPlaying || engine.isRunning {
            synth.setMaster(0, over: 0.3)
            setPlaying(false)
            stopTask?.cancel()
            stopTask = nil
            try? await Task.sleep(for: .seconds(0.4))
            if engine.isRunning { engine.stop() }
        }
    }

    // MARK: Private

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setPlaying(_ playing: Bool) {
        let changed = playing != isPlaying
        isPlaying = playing
        updateNowPlaying()
        if changed { onChange?(playing) }
    }

    /// Connects the synth to the output. Rebuilt when the hardware's sample rate changes, since the filters
    /// are designed for one rate.
    private func buildGraph() {
        let hardware = AVAudioSession.sharedInstance().sampleRate
        let rate = hardware > 0 ? hardware : 48_000
        if source != nil, synth.sampleRate == rate { return }
        if let source {
            engine.detach(source)
        }
        synth = NoiseSynth(sampleRate: rate)
        synth.apply(sound)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let node = Self.makeSource(synth: synth, format: format)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    /// Built outside the main actor: the block runs on the audio thread.
    private nonisolated static func makeSource(synth: NoiseSynth, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
            synth.render(
                left: left.assumingMemoryBound(to: Float.self),
                right: right.assumingMemoryBound(to: Float.self),
                frames: Int(frameCount)
            )
            return noErr
        }
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            if isPlaying {
                stopTask?.cancel()
                synth.setMaster(0, over: 0.05)
                setPlaying(false)
            }
        case .ended:
            if resumeAfterInterruption, shouldResume { play() }
            resumeAfterInterruption = false
        default:
            break
        }
    }

    private func configurationChanged() {
        // The engine has stopped itself. If we were playing, start again on the new output.
        guard isPlaying else { return }
        play()
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: sound.name.isEmpty ? "Noise" : sound.name,
            MPMediaItemPropertyArtist: "Hush",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
