import Foundation

/// Plays a `Sound`. Call `apply` whenever the sound changes and `render` from the audio thread.
///
/// Filter design takes a millisecond or two per layer, so it runs on a background queue. While a slider is
/// dragged, only the newest setting of each layer is designed; older ones still waiting are dropped.
public final class NoiseSynth: @unchecked Sendable {
    public let sampleRate: Double

    private let kernel: NoiseKernel
    private let designer: FilterDesigner
    private let queue = DispatchQueue(label: "noisekit.design", qos: .userInitiated)

    private let lock = NSLock()
    private var slotOf: [UUID: Int] = [:]
    private var freeSlots: [Int] = Array((0 ..< NoiseKernel.slotCount).reversed())
    /// Newest wanted state per slot, waiting to be designed. `.some(nil)` means "turn this slot off".
    private var waiting: [Int: Layer?] = [:]
    private var draining = false

    /// What each slot's filters were last designed for. Only touched on `queue`.
    private var designed: [Int: FilterKey] = [:]

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        kernel = NoiseKernel(sampleRate: sampleRate)
        designer = FilterDesigner(sampleRate: sampleRate, kernelSize: NoiseKernel.fftSize)
    }

    /// Makes the synth play `sound`. Returns at once; the change is heard a moment later.
    public func apply(_ sound: Sound) {
        kernel.submitScene(Self.sceneParams(sound.scene))
        if enqueue(sound) {
            queue.async { self.drain() }
        }
    }

    /// Like `apply`, but returns only when the audio thread has been handed the new settings.
    public func applyAndWait(_ sound: Sound) {
        kernel.submitScene(Self.sceneParams(sound.scene))
        _ = enqueue(sound)
        queue.sync { self.drain() }
    }

    /// Moves the overall gain to `target` (0 silent, 1 full) over `seconds`.
    public func setMaster(_ target: Float, over seconds: Double) {
        kernel.setMaster(target, over: seconds)
    }

    /// RMS of the most recent render call, after the master gain. 1 is full scale.
    public var outputLevel: Float { kernel.outputLevel }

    /// Fills `frames` samples of each channel. Safe to call from the audio thread.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        kernel.render(left: left, right: right, frames: frames)
    }

    // MARK: Private

    private static func sceneParams(_ scene: Soundscape?) -> SceneParams {
        var p = SceneParams()
        guard let scene, scene.isOn else { return p }
        p.active = true
        p.kind = scene.kind == .train ? 0 : 1
        p.gain = Float(pow(10, scene.level / 20))
        p.v0 = Float(scene.value(0))
        p.v1 = Float(scene.value(1))
        p.v2 = Float(scene.value(2))
        p.v3 = Float(scene.value(3))
        p.v4 = Float(scene.value(4))
        p.v5 = Float(scene.value(5))
        return p
    }

    /// Records what each slot should become. Returns true if a drain needs to be started.
    private func enqueue(_ sound: Sound) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let layers = Array(sound.layers.prefix(Sound.maxLayers))
        let wanted = Set(layers.map(\.id))
        for (id, slot) in slotOf where !wanted.contains(id) {
            slotOf[id] = nil
            freeSlots.append(slot)
            waiting[slot] = .some(nil)
        }
        for layer in layers {
            let slot: Int
            if let existing = slotOf[layer.id] {
                slot = existing
            } else if let free = freeSlots.popLast() {
                slot = free
                slotOf[layer.id] = free
            } else {
                continue
            }
            waiting[slot] = .some(layer)
        }
        if draining || waiting.isEmpty { return false }
        draining = true
        return true
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = waiting
            waiting.removeAll(keepingCapacity: true)
            if batch.isEmpty {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            for (slot, layer) in batch {
                design(slot: slot, layer: layer)
            }
        }
    }

    private func design(slot: Int, layer: Layer?) {
        guard let layer, layer.isOn else {
            kernel.submit(slot: slot, params: LayerParams(), filters: nil)
            return
        }
        let key = FilterKey(layer: layer)
        var filters: (a: PackedFilter, b: PackedFilter?)?
        if designed[slot] != key {
            let a = designer.design(shape: key.trough, peak: Peak(layer.shape.resonance, sampleRate: sampleRate))
            let b = key.crest.map {
                designer.design(shape: $0, peak: Peak(layer.shape.resonance, shiftedBy: layer.motion.drift, sampleRate: sampleRate))
            }
            filters = (a, b)
            designed[slot] = key
        }
        kernel.submit(slot: slot, params: params(for: layer), filters: filters)
    }

    private func params(for layer: Layer) -> LayerParams {
        var p = LayerParams()
        p.active = true
        p.gain = Float(pow(10, layer.playedLevel / 20))
        if layer.texture.isContinuous {
            p.eventsPerSample = 1
            p.grainAmp = 1
        } else {
            let perSample = min(layer.texture.density / sampleRate, 0.999)
            p.eventsPerSample = Float(perSample)
            p.grainAmp = Float(Spectrum.grainAmplitude(eventsPerSample: perSample))
        }
        p.correlation = Float(1 - min(max(layer.space.width, 0), 1))
        p.wide = layer.space.width > 0.001
        let resonance = layer.shape.resonance
        let motion = layer.motion
        p.resonant = resonance.isOn
        p.resFrequency = Float(resonance.frequency)
        p.resDamping = Float(1 / max(resonance.sharpness, 0.1))
        p.resGain = Float(pow(10, resonance.strength / 20) - 1)
        p.drift = resonance.isOn ? Float(motion.drift) : 0
        p.sweep = motion.hasSweep
        p.swell = Float(min(max(motion.swell, 0), 1))
        p.motion = motion.swell > 0 || motion.hasSweep || (resonance.isOn && motion.hasDrift)
        p.cyclesPerSample = Float(motion.rate / sampleRate)
        p.randomness = Float(min(max(motion.randomness, 0), 1))
        p.rise = Float(min(max(motion.rise, 0.05), 0.95))
        p.curve = 1 + 2 * abs(0.5 - p.rise) / 0.45
        p.delay = Float(min(max(motion.delay, 0), 1))
        let rateBits = motion.rate.bitPattern, patternBits = motion.randomness.bitPattern
        var seed = UInt32(truncatingIfNeeded: rateBits ^ (rateBits >> 32)) &* 0x9E37_79B1
        seed ^= UInt32(truncatingIfNeeded: patternBits ^ (patternBits >> 32)) &* 0x85EB_CA6B
        p.motionSeed = seed | 1
        return p
    }
}

/// Everything the filters of a layer depend on. If this is unchanged, the filters are kept.
private struct FilterKey: Equatable {
    var trough: ShapeCurve
    var crest: ShapeCurve?
    var resonance: Resonance
    var drift: Double

    init(layer: Layer) {
        trough = ShapeCurve(layer: layer)
        crest = layer.motion.hasSweep ? ShapeCurve(layer: layer, tiltOffset: layer.motion.sweep) : nil
        // The resonance is not part of the filters, but they are scaled so the power stays 1 with it in place.
        resonance = layer.shape.resonance
        drift = crest == nil ? 0 : layer.motion.drift
    }
}
