import Accelerate
import Foundation
import Synchronization
import os

/// Everything about a layer that is a plain number. Copied to the audio thread as a whole.
struct LayerParams {
    var active = false
    /// Linear gain.
    var gain: Float = 0
    /// Chance that a sample holds a random event. 1 means every sample does.
    var eventsPerSample: Float = 1
    var grainAmp: Float = 1
    /// How alike the two ears are: 1 identical, 0 unrelated.
    var correlation: Float = 1
    var wide = false
    var sweep = false
    var motion = false
    var cyclesPerSample: Float = 0
    var randomness: Float = 0
    /// Part of each cycle spent rising, 0 to 1.
    var rise: Float = 0.5
    /// Power applied to the longer side of the cycle, so a quick rise is followed by a decay, not a mirror image.
    var curve: Float = 1
    /// How far behind the shared clock this layer runs, in cycles.
    var delay: Float = 0
    /// Layers with the same rate and pattern get the same seed, so their cycles match.
    var motionSeed: UInt32 = 1
    var swell: Float = 0
    var resonant = false
    var resFrequency: Float = 400
    /// 1 / Q.
    var resDamping: Float = 0.25
    /// Amplitude gain at the peak, minus 1.
    var resGain: Float = 0
    var drift: Float = 0
}

/// The part that runs on the audio thread. It never allocates, never waits for a lock and never calls
/// into Objective-C, so a render call always returns in time.
///
/// Each layer runs in two stages:
/// 1. Block stage: 4096 samples of raw randomness (texture) are filtered into shape with an FFT.
///    A block is filtered whole by one filter, so swapping filters between blocks never clicks.
/// 2. Sample stage: resonance, motion, stereo width and level, applied sample by sample so they respond at once.
final class NoiseKernel {
    static let slotCount = 8
    static let fftSize = 8192
    private static let chunk = 16

    let sampleRate: Float
    private let n = NoiseKernel.fftSize
    private let hop = NoiseKernel.fftSize / 2
    private let half = NoiseKernel.fftSize / 2
    private let fft: RealFFT

    private let time: UnsafeMutablePointer<Float>
    private let xr: UnsafeMutablePointer<Float>
    private let xi: UnsafeMutablePointer<Float>
    private let yr: UnsafeMutablePointer<Float>
    private let yi: UnsafeMutablePointer<Float>
    private let slots: UnsafeMutablePointer<Slot>

    // Handoff from other threads. They take the lock; the audio thread only ever tries it.
    private let lock: UnsafeMutablePointer<os_unfair_lock_s>
    private let pending: UnsafeMutablePointer<Pending>
    private var pendingMasterTarget: Float = 0
    private var pendingMasterSeconds: Float = 0
    private var pendingMasterDirty = false
    private var pendingScene = SceneParams()
    private var pendingSceneDirty = false
    private let scene: SceneKernel

    private var master: Float = 0
    private var masterTarget: Float = 0
    private var masterStep: Float = 0
    private let gainAlpha: Float
    private let meter = Atomic<UInt32>(0)

    private struct Pending {
        var params = LayerParams()
        var dirty = false
        var filtersDirty = false
    }

    private struct Slot {
        var p = LayerParams()
        /// Still making sound (on, or fading out).
        var live = false
        // Filter spectra: A is the shape at the trough of the motion, B at the crest.
        var aR, aI, bR, bI: UnsafeMutablePointer<Float>
        var nextAR, nextAI, nextBR, nextBI: UnsafeMutablePointer<Float>
        // Two independent noise chains (the second only when the layer is wide), each with a filter tail
        // carried into the next block and one block of shaped output.
        var tailA0, tailA1, tailB0, tailB1: UnsafeMutablePointer<Float>
        var outA0, outA1, outB0, outB1: UnsafeMutablePointer<Float>
        var readPos = 0
        var blockWide = false
        var blockSweep = false
        var rng0: UInt32
        var rng1: UInt32
        var rngMotion: UInt32
        var gap0 = 0
        var gap1 = 0
        var gain: Float = 0
        var corr: Float = 1
        var phase: Float = 0
        /// This cycle's crest height (0 to 1) and how fast it runs next to the set rate.
        var peak: Float = 1
        var pace: Float = 1
        var m: Float = 1
        var s1a: Float = 0, s2a: Float = 0, s1b: Float = 0, s2b: Float = 0
    }

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        fft = RealFFT(size: n)
        scene = SceneKernel(sampleRate: Float(sampleRate))
        gainAlpha = 1 - exp(-1 / (0.04 * Float(sampleRate)))

        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        time = buffer(n)
        xr = buffer(half)
        xi = buffer(half)
        yr = buffer(half)
        yi = buffer(half)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock_s())
        pending = .allocate(capacity: Self.slotCount)
        pending.initialize(repeating: Pending(), count: Self.slotCount)
        slots = .allocate(capacity: Self.slotCount)
        for i in 0 ..< Self.slotCount {
            let seed = UInt32(truncatingIfNeeded: 0x9E37_79B9 &* UInt32(i + 1))
            var slot = Slot(
                aR: buffer(half), aI: buffer(half), bR: buffer(half), bI: buffer(half),
                nextAR: buffer(half), nextAI: buffer(half), nextBR: buffer(half), nextBI: buffer(half),
                tailA0: buffer(hop), tailA1: buffer(hop), tailB0: buffer(hop), tailB1: buffer(hop),
                outA0: buffer(hop), outA1: buffer(hop), outB0: buffer(hop), outB1: buffer(hop),
                rng0: seed | 1, rng1: (seed ^ 0x5bd1_e995) | 1, rngMotion: (seed ^ 0x1b87_3593) | 1
            )
            // Slots start their blocks at different moments, so the FFT work is spread over several render calls.
            slot.readPos = i * hop / Self.slotCount
            (slots + i).initialize(to: slot)
        }
    }

    deinit {
        for i in 0 ..< Self.slotCount {
            let s = slots[i]
            for p in [s.aR, s.aI, s.bR, s.bI, s.nextAR, s.nextAI, s.nextBR, s.nextBI,
                      s.tailA0, s.tailA1, s.tailB0, s.tailB1, s.outA0, s.outA1, s.outB0, s.outB1] {
                p.deallocate()
            }
        }
        slots.deallocate()
        pending.deallocate()
        lock.deallocate()
        for p in [time, xr, xi, yr, yi] { p.deallocate() }
    }

    // MARK: Called from other threads

    /// Hands new settings for one slot to the audio thread. `filters` is nil when the shape did not change.
    func submit(slot: Int, params: LayerParams, filters: (a: PackedFilter, b: PackedFilter?)?) {
        os_unfair_lock_lock(lock)
        pending[slot].params = params
        pending[slot].dirty = true
        if let filters {
            let bytes = half * MemoryLayout<Float>.stride
            let s = slots + slot
            filters.a.real.withUnsafeBytes { _ = memcpy(s.pointee.nextAR, $0.baseAddress!, bytes) }
            filters.a.imag.withUnsafeBytes { _ = memcpy(s.pointee.nextAI, $0.baseAddress!, bytes) }
            if let b = filters.b {
                b.real.withUnsafeBytes { _ = memcpy(s.pointee.nextBR, $0.baseAddress!, bytes) }
                b.imag.withUnsafeBytes { _ = memcpy(s.pointee.nextBI, $0.baseAddress!, bytes) }
            }
            pending[slot].filtersDirty = true
        }
        os_unfair_lock_unlock(lock)
    }

    /// Hands new scene settings to the audio thread.
    func submitScene(_ params: SceneParams) {
        os_unfair_lock_lock(lock)
        pendingScene = params
        pendingSceneDirty = true
        os_unfair_lock_unlock(lock)
    }

    /// Moves the master gain to `target` over `seconds`.
    func setMaster(_ target: Float, over seconds: Double) {
        os_unfair_lock_lock(lock)
        pendingMasterTarget = target
        pendingMasterSeconds = Float(seconds)
        pendingMasterDirty = true
        os_unfair_lock_unlock(lock)
    }

    /// RMS of the most recent render call, after the master gain.
    var outputLevel: Float {
        Float(bitPattern: meter.load(ordering: .relaxed))
    }

    // MARK: Audio thread

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        adopt()
        vDSP_vclr(left, 1, vDSP_Length(frames))
        vDSP_vclr(right, 1, vDSP_Length(frames))
        if master == 0, masterTarget == 0 {
            meter.store(0, ordering: .relaxed)
            return
        }
        for i in 0 ..< Self.slotCount where slots[i].live {
            mix(i, left, right, frames)
        }
        scene.render(left: left, right: right, frames: frames)

        var g = master
        let target = masterTarget
        let step = masterStep
        var sum: Float = 0
        for i in 0 ..< frames {
            if g != target {
                g += step
                if (step > 0 && g > target) || (step < 0 && g < target) || step == 0 { g = target }
            }
            let l = Self.limit(left[i] * g)
            let r = Self.limit(right[i] * g)
            left[i] = l
            right[i] = r
            sum += l * l + r * r
        }
        master = g
        meter.store((sum / Float(2 * max(frames, 1))).squareRoot().bitPattern, ordering: .relaxed)
    }

    /// Leaves samples alone below 0.8 and bends anything louder so it can never pass 1.
    @inline(__always)
    private static func limit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }

    /// Takes over whatever other threads have handed in. Skipped (until the next call) if they hold the lock.
    private func adopt() {
        guard os_unfair_lock_trylock(lock) else { return }
        for i in 0 ..< Self.slotCount where pending[i].dirty {
            let s = slots + i
            let old = s.pointee.p
            let new = pending[i].params
            s.pointee.p = new
            if new.active {
                if !s.pointee.live {
                    // A layer that starts playing starts its motion from the beginning, so layers that
                    // start together and share a rate and pattern stay in step.
                    s.pointee.phase = -new.delay
                    s.pointee.peak = 1
                    s.pointee.pace = 1
                    s.pointee.rngMotion = new.motionSeed
                } else {
                    if new.motionSeed != old.motionSeed { s.pointee.rngMotion = new.motionSeed }
                    s.pointee.phase -= new.delay - old.delay
                }
            }
            if pending[i].filtersDirty {
                swap(&s.pointee.aR, &s.pointee.nextAR)
                swap(&s.pointee.aI, &s.pointee.nextAI)
                swap(&s.pointee.bR, &s.pointee.nextBR)
                swap(&s.pointee.bI, &s.pointee.nextBI)
                pending[i].filtersDirty = false
            }
            if s.pointee.p.active { s.pointee.live = true }
            pending[i].dirty = false
        }
        if pendingSceneDirty {
            scene.wanted = pendingScene
            pendingSceneDirty = false
        }
        if pendingMasterDirty {
            masterTarget = pendingMasterTarget
            let samples = max(1, pendingMasterSeconds * sampleRate)
            masterStep = (masterTarget - master) / samples
            pendingMasterDirty = false
        }
        os_unfair_lock_unlock(lock)
    }

    // MARK: Block stage

    private func produce(_ s: inout Slot) {
        let p = s.p
        let wide = p.wide || s.corr < 0.9995
        let sweep = p.sweep
        // A chain that stops running must not leave an old tail behind for when it starts again.
        if s.blockWide, !wide {
            vDSP_vclr(s.tailA1, 1, vDSP_Length(hop))
            vDSP_vclr(s.tailB1, 1, vDSP_Length(hop))
        }
        if s.blockSweep, !sweep {
            vDSP_vclr(s.tailB0, 1, vDSP_Length(hop))
            vDSP_vclr(s.tailB1, 1, vDSP_Length(hop))
        }
        s.blockWide = wide
        s.blockSweep = sweep

        fillExcitation(&s.rng0, &s.gap0, p)
        convolve(s.aR, s.aI, tail: s.tailA0, out: s.outA0)
        if sweep { convolve(s.bR, s.bI, tail: s.tailB0, out: s.outB0) }
        if wide {
            fillExcitation(&s.rng1, &s.gap1, p)
            convolve(s.aR, s.aI, tail: s.tailA1, out: s.outA1)
            if sweep { convolve(s.bR, s.bI, tail: s.tailB1, out: s.outB1) }
        }
        s.readPos = 0
    }

    /// Writes one block of raw randomness into `time` (zero-padded) and leaves its spectrum in xr/xi.
    private func fillExcitation(_ rng: inout UInt32, _ gap: inout Int, _ p: LayerParams) {
        var x = rng
        if p.eventsPerSample >= 1 {
            // Every sample random, evenly spread over ±√3 so the power is 1.
            let scale: Float = 1.7320508 / 2_147_483_648
            for i in 0 ..< hop {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                time[i] = Float(Int32(bitPattern: x)) * scale
            }
            gap = 0
        } else {
            // Mostly silence, with a tick wherever a random wait runs out.
            vDSP_vclr(time, 1, vDSP_Length(hop))
            let meanWait = -1 / log1pf(-p.eventsPerSample)
            let scale = p.grainAmp * (1.7320508 / 2_147_483_648)
            var pos = gap
            while pos < hop {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                time[pos] = Float(Int32(bitPattern: x)) * scale
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                let u = (Float(x >> 8) + 1) * (1 / 16_777_216)
                pos += Int(-logf(u) * meanWait) + 1
            }
            gap = pos - hop
        }
        rng = x
        vDSP_vclr(time + hop, 1, vDSP_Length(n - hop))
        fft.forward(time, xr, xi)
    }

    /// Filters the block whose spectrum is in xr/xi. The first half of the result joins the previous block's
    /// tail to make this block's output; the second half becomes the tail for the next block.
    private func convolve(
        _ filterReal: UnsafeMutablePointer<Float>, _ filterImag: UnsafeMutablePointer<Float>,
        tail: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>
    ) {
        RealFFT.multiply(xr, xi, filterReal, filterImag, yr, yi, half: half)
        fft.inverse(yr, yi, time)
        vDSP_vadd(time, 1, tail, 1, out, 1, vDSP_Length(hop))
        memcpy(tail, time + hop, hop * MemoryLayout<Float>.stride)
    }

    // MARK: Sample stage

    private func mix(_ index: Int, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, _ frames: Int) {
        var s = slots[index]
        let p = s.p
        let gainTarget: Float = p.active ? p.gain : 0
        let corrTarget: Float = p.wide ? p.correlation : 1
        let piOverRate = Float.pi / sampleRate
        let maxResonance = 0.45 * sampleRate

        var i = 0
        while i < frames {
            if s.readPos >= hop { produce(&s) }
            let run = min(Self.chunk, frames - i, hop - s.readPos)
            let runF = Float(run)
            let ease = min(1, gainAlpha * runF)

            // Motion: one value between 0 (trough) and 1 (crest), stepped once per chunk.
            let m0 = s.m
            var m1: Float = 1
            if p.motion {
                s.phase += p.cyclesPerSample * s.pace * runF
                if s.phase >= 1 {
                    // A new cycle starts at the trough, so its height and pace can change without a jump.
                    s.phase -= s.phase.rounded(.down)
                    var x = s.rngMotion
                    x ^= x << 13; x ^= x >> 17; x ^= x << 5
                    let u1 = Float(x >> 8) * (1 / 16_777_216)
                    x ^= x << 13; x ^= x >> 17; x ^= x << 5
                    let u2 = Float(x >> 8) * (1 / 16_777_216)
                    s.rngMotion = x
                    s.peak = 1 - 0.65 * p.randomness * u1
                    s.pace = powf(2, 1.6 * p.randomness * (u2 - 0.5))
                }
                let t = s.phase
                let a = p.rise
                var shape: Float = 0
                if t > 0, t < a {
                    shape = 0.5 - 0.5 * cosf(.pi * t / a)
                    if a > 0.5 { shape = powf(shape, p.curve) }
                } else if t >= a {
                    shape = 0.5 + 0.5 * cosf(.pi * (t - a) / (1 - a))
                    if a < 0.5 { shape = powf(shape, p.curve) }
                }
                m1 = s.peak * shape
            }
            s.m = m1

            // Level and swell, ramped across the chunk.
            let g1 = s.gain + ease * (gainTarget - s.gain)
            var amp = s.gain * (1 - p.swell * (1 - m0 * m0))
            let ampStep = (g1 * (1 - p.swell * (1 - m1 * m1)) - amp) / runF
            s.gain = g1

            // Sweep: crossfade from the trough shape to the crest shape.
            let sweep = s.blockSweep
            var blend = m0
            let blendStep = (m1 - m0) / runF

            // Width.
            s.corr += ease * (corrTarget - s.corr)
            let wide = s.blockWide
            let c: Float = wide ? s.corr : 1
            let q = max(0, 1 - c * c).squareRoot()

            // Resonance: a band-pass copy of the signal added back on top. Its frequency follows the motion.
            let resonant = p.resonant
            var a1: Float = 0, a2: Float = 0, a3: Float = 0, peak: Float = 0
            if resonant {
                let f = min(max(p.resFrequency * exp2f(p.drift * 0.5 * (m0 + m1)), 10), maxResonance)
                let g = tanf(piOverRate * f)
                a1 = 1 / (1 + g * (g + p.resDamping))
                a2 = g * a1
                a3 = g * a2
                peak = p.resGain * p.resDamping
            }

            let base = s.readPos
            let srcA0 = s.outA0 + base, srcB0 = s.outB0 + base
            let srcA1 = s.outA1 + base, srcB1 = s.outB1 + base
            let dstL = outL + i, dstR = outR + i
            var s1a = s.s1a, s2a = s.s2a, s1b = s.s1b, s2b = s.s2b

            for j in 0 ..< run {
                var a = srcA0[j]
                if sweep { a += blend * (srcB0[j] - a) }
                if resonant {
                    let v3 = a - s2a
                    let v1 = a1 * s1a + a2 * v3
                    let v2 = s2a + a2 * s1a + a3 * v3
                    s1a = 2 * v1 - s1a
                    s2a = 2 * v2 - s2a
                    a += peak * v1
                }
                var r = a
                if wide {
                    var b = srcA1[j]
                    if sweep { b += blend * (srcB1[j] - b) }
                    if resonant {
                        let v3 = b - s2b
                        let v1 = a1 * s1b + a2 * v3
                        let v2 = s2b + a2 * s1b + a3 * v3
                        s1b = 2 * v1 - s1b
                        s2b = 2 * v2 - s2b
                        b += peak * v1
                    }
                    r = c * a + q * b
                }
                dstL[j] += a * amp
                dstR[j] += r * amp
                amp += ampStep
                blend += blendStep
            }

            s.s1a = s1a; s.s2a = s2a; s.s1b = s1b; s.s2b = s2b
            s.readPos += run
            i += run
        }

        if !p.active, s.gain < 1e-5 {
            // Faded out: go quiet and forget the filter state, so the slot starts clean next time.
            s.live = false
            s.gain = 0
            s.s1a = 0; s.s2a = 0; s.s1b = 0; s.s2b = 0
            vDSP_vclr(s.tailA0, 1, vDSP_Length(hop))
            vDSP_vclr(s.tailA1, 1, vDSP_Length(hop))
            vDSP_vclr(s.tailB0, 1, vDSP_Length(hop))
            vDSP_vclr(s.tailB1, 1, vDSP_Length(hop))
            vDSP_vclr(s.outA0, 1, vDSP_Length(hop))
            vDSP_vclr(s.outB0, 1, vDSP_Length(hop))
            vDSP_vclr(s.outA1, 1, vDSP_Length(hop))
            vDSP_vclr(s.outB1, 1, vDSP_Length(hop))
            s.blockWide = false
            s.blockSweep = false
        }
        slots[index] = s
    }
}
