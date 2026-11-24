import Foundation

/// Scene settings as plain numbers. Copied to the audio thread as a whole.
struct SceneParams {
    var active = false
    /// 0 train, 1 fireplace.
    var kind: Int32 = 0
    var gain: Float = 0
    var v0: Float = 0, v1: Float = 0, v2: Float = 0, v3: Float = 0, v4: Float = 0, v5: Float = 0
}

// MARK: Small parts

private enum DSP {
    /// A random number from 0 up to (not including) 1.
    @inline(__always)
    static func rnd(_ s: inout UInt32) -> Float {
        s ^= s << 13
        s ^= s >> 17
        s ^= s << 5
        return Float(s >> 8) * (1.0 / 16_777_216.0)
    }

    /// White noise from -1 to 1. Its RMS is 0.577.
    @inline(__always)
    static func noise(_ s: inout UInt32) -> Float {
        2 * rnd(&s) - 1
    }

    /// The coefficient of a one-pole lowpass with its corner at `hz`.
    @inline(__always)
    static func pole(_ hz: Float, _ sr: Float) -> Float {
        1 - expf(-2 * .pi * min(hz, 0.45 * sr) / sr)
    }

    /// What to multiply white noise by so that, after two one-pole lowpasses at `hz`, its RMS is 1.
    @inline(__always)
    static func lowpassedNorm(_ hz: Float, _ sr: Float) -> Float {
        1 / (0.577 * (0.5 * .pi * hz / sr).squareRoot())
    }

    /// The same for a band-pass with a peak gain of 1.
    @inline(__always)
    static func bandNorm(_ hz: Float, _ q: Float, _ sr: Float) -> Float {
        1 / (0.577 * (.pi * hz / (q * sr)).squareRoot())
    }
}

/// A state-variable filter. `band` has a peak gain of 1.
private struct SVF {
    var s1: Float = 0, s2: Float = 0
    var a1: Float = 0, a2: Float = 0, a3: Float = 0, k: Float = 1

    mutating func set(_ hz: Float, _ q: Float, _ sr: Float) {
        let g = tanf(.pi * min(hz, 0.45 * sr) / sr)
        k = 1 / q
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always)
    mutating func band(_ x: Float) -> Float {
        let v3 = x - s2
        let v1 = a1 * s1 + a2 * v3
        let v2 = s2 + a2 * s1 + a3 * v3
        s1 = 2 * v1 - s1
        s2 = 2 * v2 - s2
        return v1 * k
    }
}

/// One way a struck body rings: a pitch that dies away. An impulse of area 1 starts a ring of height `gain`.
private struct Mode {
    var c1: Float = 0, c2: Float = 0, input: Float = 0
    var y1: Float = 0, y2: Float = 0

    init(hz: Float, seconds: Float, gain: Float, sr: Float) {
        let w = 2 * Float.pi * hz / sr
        let r = expf(-6.91 / (seconds * sr))
        c1 = 2 * r * cosf(w)
        c2 = r * r
        input = gain * sinf(w)
    }

    @inline(__always)
    mutating func ring(_ x: Float) -> Float {
        let y = x * input + c1 * y1 - c2 * y2
        y2 = y1
        y1 = y
        return y
    }
}

/// A value that drifts between 0 and 1: now and then it picks a new random target and eases toward it.
private struct Wander {
    var value: Float = 0.5
    var target: Float = 0.5
    var left: Float = 0

    @inline(__always)
    mutating func step(_ dt: Float, _ rng: inout UInt32, every low: Float, to high: Float, ease: Float) -> Float {
        left -= dt
        if left <= 0 {
            target = DSP.rnd(&rng)
            left = low + (high - low) * DSP.rnd(&rng)
        }
        value += (target - value) * min(1, dt / ease)
        return value
    }
}

// MARK: Train

/// A train heard from inside a carriage.
///
/// The rhythm comes from geometry. Rails are 18.3 m long with a joint between them. A carriage rides on two
/// bogies with two axles each, 2.5 m apart. Every axle clacks as it crosses a joint, so one joint is heard
/// as a pair from the bogie under the listener, and fainter pairs from the bogies further along.
/// Each hit strikes the carriage body, which rings at a few fixed low pitches, and briefly lifts the
/// rumble and the steel-on-steel noise.
private struct Train {
    static let axles = 6
    static let nearModes = 10
    static let farModes = 4
    static let railLength: Float = 18.3

    var rng: UInt32 = 0x2F6E_2B1D
    // Per axle: metres to its next joint, and how many joints it has crossed.
    let ahead: UnsafeMutablePointer<Float>
    let crossed: UnsafeMutablePointer<UInt32>
    // Body modes, left then right, near bank then far bank.
    let modes: UnsafeMutablePointer<Mode>

    var speed: Float = 25
    var speedDrift = Wander()
    var sway = Wander()
    var wheel: Float = 0

    // Track sections: how far in we are (0 to 1) and how many seconds are left.
    var bridge: Float = 0, tunnel: Float = 0, welded: Float = 0
    var bridgeLeft: Float = 0, tunnelLeft: Float = 0, weldedLeft: Float = 0
    var nextChange: Float = 25
    var pointsLeft: Int32 = 0
    var pointsIn: Float = 0
    var trackSeed: UInt32 = 0x51ED_270B

    // Impulses waiting to strike the body this sample.
    var hitNL: Float = 0, hitNR: Float = 0, hitFL: Float = 0, hitFR: Float = 0
    var thump: Float = 0
    var click: Float = 0
    var knock: Float = 0

    // Filters.
    var pulseNL1: Float = 0, pulseNL2: Float = 0, pulseNR1: Float = 0, pulseNR2: Float = 0
    var pulseFL1: Float = 0, pulseFL2: Float = 0, pulseFR1: Float = 0, pulseFR2: Float = 0
    var rumL1: Float = 0, rumL2: Float = 0, rumR1: Float = 0, rumR2: Float = 0
    var rumLdc: Float = 0, rumRdc: Float = 0
    var rollL = SVF(), rollR = SVF()
    var clickBand = SVF()
    var knockBand = SVF()
    var hollow = SVF()
    var airL: Float = 0, airR: Float = 0, airLlow: Float = 0, airRlow: Float = 0
    var outL1: Float = 0, outL2: Float = 0, outR1: Float = 0, outR2: Float = 0

    init(sr: Float) {
        ahead = .allocate(capacity: Self.axles)
        crossed = .allocate(capacity: Self.axles)
        modes = .allocate(capacity: 2 * (Self.nearModes + Self.farModes))
        for a in 0 ..< Self.axles {
            let offset = Self.offset(a) + 40
            ahead[a] = Self.railLength - offset.truncatingRemainder(dividingBy: Self.railLength)
            crossed[a] = UInt32(offset / Self.railLength)
        }
        // Pitch (Hz), ring time (s), strength. The right ear's body is tuned a touch apart from the left.
        let near: [(Float, Float, Float)] = [(57, 0.2, 0.7), (86, 0.17, 0.9), (127, 0.14, 1), (203, 0.11, 0.8),
                                             (331, 0.08, 0.55), (517, 0.06, 0.35), (842, 0.04, 0.2),
                                             // Steel: higher, and it rings on.
                                             (1_130, 0.28, 0.22), (1_740, 0.22, 0.16), (2_630, 0.16, 0.1)]
        let far: [(Float, Float, Float)] = [(47, 0.22, 1), (73, 0.18, 0.7), (111, 0.14, 0.4), (171, 0.1, 0.2)]
        // Every second mode starts downward, so a hit does not begin with all of them stacked into one spike.
        var i = 0
        for detune in [Float(1), 1.017] {
            for m in near + far {
                (modes + i).initialize(to: Mode(hz: m.0 * detune, seconds: m.1, gain: i % 2 == 0 ? m.2 : -m.2, sr: sr))
                i += 1
            }
        }
        clickBand.set(1_700, 1.1, sr)
        knockBand.set(230, 0.7, sr)
        hollow.set(132, 3, sr)
    }

    func free() {
        ahead.deallocate()
        crossed.deallocate()
        modes.deallocate()
    }

    /// Where each axle sits along the train, in metres ahead of the listener.
    @inline(__always)
    static func offset(_ axle: Int) -> Float {
        switch axle {
        case 0: 1.25 // the bogie under the listener
        case 1: -1.25
        case 2: 15.25 // the other bogie of the same carriage
        case 3: 12.75
        case 4: -4.75 // the nearest bogie of the next carriage
        default: -7.25
        }
    }

    @inline(__always)
    mutating func strike(_ amp: Float, near: Bool, pan: Float) {
        let left = 1 - max(pan, 0) * 0.7
        let right = 1 + min(pan, 0) * 0.7
        if near {
            hitNL += amp * left
            hitNR += amp * right
            thump += amp * 3.4
            click += amp
            knock += amp
        } else {
            hitFL += amp * left
            hitFR += amp * right
            thump += amp * 1.6
            click += amp * 0.25
            knock += amp * 0.35
        }
    }

    mutating func run(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int,
                      _ v: UnsafePointer<Float>, _ g0: Float, _ g1: Float, _ sr: Float) {
        let dt = Float(n) / sr
        let clack = v[1], rumbleSet = v[2], window = v[3], journey = v[4]

        // Speed: the slider, with a slow drift of ±10% around it.
        let drift = speedDrift.step(dt, &rng, every: 15, to: 40, ease: 8)
        let wantedSpeed = (40 + 120 * v[0]) / 3.6 * (0.9 + 0.2 * drift)
        speed += (wantedSpeed - speed) * min(1, dt / 4)
        let pace = min(max((speed - 11) / 33, 0), 1)

        // Track changes.
        if journey > 0.02 {
            nextChange -= dt
            if nextChange <= 0 {
                nextChange = (110 - 92 * journey) * (0.5 + DSP.rnd(&rng))
                let pick = DSP.rnd(&rng)
                let u = DSP.rnd(&rng)
                if pick < 0.3 {
                    pointsLeft = 5 + Int32(u * 5)
                    pointsIn = 0
                } else if pick < 0.55 {
                    bridgeLeft = 6 + 12 * u
                } else if pick < 0.75 {
                    tunnelLeft = 10 + 25 * u
                } else {
                    weldedLeft = 20 + 40 * u
                }
            }
        }
        if bridgeLeft > 0 { bridgeLeft -= dt }
        if tunnelLeft > 0 { tunnelLeft -= dt }
        if weldedLeft > 0 {
            weldedLeft -= dt
            // New rails after the welded stretch: every joint gets a new character.
            if weldedLeft <= 0 { trackSeed = trackSeed &* 1_664_525 &+ 1_013_904_223 }
        }
        bridge += ((bridgeLeft > 0 ? 1 : 0) - bridge) * min(1, dt / 0.5)
        tunnel += ((tunnelLeft > 0 ? 1 : 0) - tunnel) * min(1, dt / 0.35)
        welded += ((weldedLeft > 0 ? 1 : 0) - welded) * min(1, dt / 2.5)

        // Wheels over joints.
        let hard = 1.1 * powf(clack, 1.3) * powf(speed / 25, 0.6) * (1 + 0.4 * bridge)
        let jointed = hard * (1 - 0.93 * welded)
        let advance = speed * dt
        for a in 0 ..< Self.axles {
            ahead[a] -= advance
            if ahead[a] <= 0 {
                ahead[a] += Self.railLength
                crossed[a] &+= 1
                // A joint sounds the same to every axle that crosses it: some are tight, a few are bad.
                var h = (crossed[a] &* 2_654_435_761) ^ trackSeed
                h |= 1
                let u = DSP.rnd(&h)
                let joint: Float = u < 0.08 ? 1.35 : 0.45 + 0.55 * u
                let spread = 0.85 + 0.3 * DSP.rnd(&rng)
                if a < 2 {
                    strike(jointed * joint * spread, near: true, pan: a == 0 ? 0.15 : -0.15)
                } else if a < 4 {
                    strike(jointed * joint * spread * 0.3, near: false, pan: 0.7)
                } else {
                    strike(jointed * joint * spread * 0.45, near: false, pan: -0.6)
                }
            }
        }
        // A set of points: a short run of hits with no pattern.
        if pointsLeft > 0 {
            pointsIn -= dt
            if pointsIn <= 0 {
                let u = DSP.rnd(&rng)
                strike(hard * (0.5 + 0.7 * u), near: DSP.rnd(&rng) < 0.6, pan: 1.4 * DSP.rnd(&rng) - 0.7)
                pointsLeft -= 1
                pointsIn = (0.07 + 0.2 * DSP.rnd(&rng)) * 25 / max(speed, 8)
            }
        }

        // Levels for this stretch of samples.
        let lean = sway.step(dt, &rng, every: 0.8, to: 2.5, ease: 0.9)
        let rumbleHz = 62 + 40 * pace
        let rumbleNorm = DSP.lowpassedNorm(rumbleHz, sr)
        let rumbleGain = 0.5 * (rumbleSet / 0.6) * (0.75 + 0.5 * pace) * (1 + 0.8 * bridge) * (0.85 + 0.3 * lean)
        let rumblePole = DSP.pole(rumbleHz, sr)
        let dcPole = DSP.pole(22, sr)
        let rollHz = 260 + 420 * pace
        rollL.set(rollHz, 0.7, sr)
        rollR.set(rollHz * 1.06, 0.7, sr)
        let rollGain = DSP.bandNorm(rollHz, 0.7, sr) * 0.17 * (0.5 + pace) * (1 + 1.5 * tunnel)
        let hollowGain = DSP.bandNorm(132, 3, sr) * 0.3 * bridge
        let clickGain = DSP.bandNorm(1_700, 1.1, sr) * (0.12 + 0.88 * window) * 0.55
        let airGain = 0.035 * (0.3 + window) * (1 + 3 * tunnel) * (0.5 + pace)
        let airPole = DSP.pole(3_000, sr), airLowPole = DSP.pole(300, sr)
        let nearPole = DSP.pole(1_800 + 800 * pace, sr), farPole = DSP.pole(260, sr)
        let outPole = DSP.pole(350 * powf(23, window) * (1 + 0.6 * tunnel), sr)
        let knockGain = DSP.bandNorm(230, 0.7, sr) * 0.75
        let hitFall = expf(-1 / (0.006 * sr)), knockFall = expf(-1 / (0.045 * sr))
        let thumpFall = expf(-1 / (0.11 * sr)), clickFall = expf(-1 / (0.011 * sr))
        let wheelStep = speed / 2.83 / sr
        let balance = 0.12 * (lean - 0.5)
        let nearL = modes, farL = modes + Self.nearModes
        let nearR = modes + Self.nearModes + Self.farModes, farR = nearR + Self.nearModes
        let gStep = (g1 - g0) / Float(n)
        var g = g0

        for i in 0 ..< n {
            let c = DSP.noise(&rng), a = DSP.noise(&rng), b = DSP.noise(&rng)

            // The hits, rounded off, strike the body.
            // A hit is a few milliseconds of noise, not one clean knock, so no two hits ring the body alike.
            let inNL = hitNL * a * 0.14, inNR = hitNR * b * 0.14, inFL = hitFL * a * 0.14, inFR = hitFR * b * 0.14
            pulseNL1 += nearPole * (inNL - pulseNL1); pulseNL2 += nearPole * (pulseNL1 - pulseNL2)
            pulseNR1 += nearPole * (inNR - pulseNR1); pulseNR2 += nearPole * (pulseNR1 - pulseNR2)
            pulseFL1 += farPole * (inFL - pulseFL1); pulseFL2 += farPole * (pulseFL1 - pulseFL2)
            pulseFR1 += farPole * (inFR - pulseFR1); pulseFR2 += farPole * (pulseFR1 - pulseFR2)
            hitNL *= hitFall; hitNR *= hitFall; hitFL *= hitFall; hitFR *= hitFall
            var bodyL: Float = 0, bodyR: Float = 0
            for m in 0 ..< Self.nearModes {
                bodyL += nearL[m].ring(pulseNL2)
                bodyR += nearR[m].ring(pulseNR2)
            }
            for m in 0 ..< Self.farModes {
                bodyL += farL[m].ring(pulseFL2)
                bodyR += farR[m].ring(pulseFR2)
            }

            // Rumble, lifted for a moment by each hit.
            rumL1 += rumblePole * (c + 0.45 * a - rumL1); rumL2 += rumblePole * (rumL1 - rumL2)
            rumR1 += rumblePole * (c - 0.45 * a - rumR1); rumR2 += rumblePole * (rumR1 - rumR2)
            rumLdc += dcPole * (rumL2 - rumLdc)
            rumRdc += dcPole * (rumR2 - rumRdc)
            let lift = rumbleGain + thump
            let rumbleL = (rumL2 - rumLdc) * rumbleNorm * lift * (1 - balance)
            let rumbleR = (rumR2 - rumRdc) * rumbleNorm * lift * (1 + balance)
            thump *= thumpFall

            // Steel rolling on steel, with a faint beat once per turn of the wheel.
            wheel += wheelStep
            if wheel >= 1 { wheel -= 1 }
            let turn = 1 + 0.1 * sinf(2 * .pi * wheel)
            let rollingL = rollL.band(a) * rollGain * turn
            let rollingR = rollR.band(b) * rollGain * turn
            let snap = clickBand.band(c) * clickGain * click
            click *= clickFall
            let thud = knockBand.band(b) * knockGain * knock
            knock *= knockFall
            let drum = hollow.band(a + b) * hollowGain

            airL += airPole * (a - airL); airLlow += airLowPole * (airL - airLlow)
            airR += airPole * (b - airR); airRlow += airLowPole * (airR - airRlow)

            let sumL = rumbleL + rollingL + 0.7 * bodyL + thud + snap + drum + (airL - airLlow) * airGain
            let sumR = rumbleR + rollingR + 0.7 * bodyR + thud + snap + drum + (airR - airRlow) * airGain
            outL1 += outPole * (sumL - outL1); outL2 += outPole * (outL1 - outL2)
            outR1 += outPole * (sumR - outR1); outR2 += outPole * (outR1 - outR2)
            g += gStep
            // Halved so the heaviest clack stays under the limiter at a level of -20.
            l[i] += outL2 * g * 0.5
            r[i] += outR2 * g * 0.5
        }
    }
}

// MARK: Fireplace

/// One crackle: a burst of noise that dies away, through a band-pass that gives it its pitch.
private struct Crackle {
    var env: Float = 0
    var fall: Float = 0
    var band = SVF()
    var left: Float = 0
    var right: Float = 0
}

/// A wood fire.
///
/// Three things are heard. Crackles: wood splitting, each a very short burst of noise. Small ones are short and
/// bright, big ones longer and lower. They arrive at random, and now and then one sets off a quick run of
/// small ones. Hiss: gas escaping, which comes and goes. Roar: the flames, a low noise whose loudness flutters
/// a few times a second and jumps when a big crackle goes off.
private struct Fire {
    static let voices = 24

    var rng: UInt32 = 0x7A3C_91E5
    let crackles: UnsafeMutablePointer<Crackle>
    var next = 0
    /// Extra crackles per second, added by a run and dying away quickly.
    var run: Float = 0
    var activity = Wander()
    var flutter = Wander()
    var flutter2 = Wander()
    var gas = Wander()
    var flare: Float = 0
    var spit: Float = 0

    var roarL1: Float = 0, roarL2: Float = 0, roarR1: Float = 0, roarR2: Float = 0
    var roarLdc: Float = 0, roarRdc: Float = 0
    var bodyL = SVF(), bodyR = SVF()
    var hissL: Float = 0, hissR: Float = 0, hissLtop: Float = 0, hissRtop: Float = 0
    var outL1: Float = 0, outL2: Float = 0, outR1: Float = 0, outR2: Float = 0

    init(sr: Float) {
        crackles = .allocate(capacity: Self.voices)
        crackles.initialize(repeating: Crackle(), count: Self.voices)
        bodyL.set(400, 0.6, sr)
        bodyR.set(430, 0.6, sr)
    }

    func free() {
        crackles.deallocate()
    }

    mutating func run(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int,
                      _ v: UnsafePointer<Float>, _ g0: Float, _ g1: Float, _ sr: Float) {
        let dt = Float(n) / sr
        let rate = v[0], size = v[1], hissSet = v[2], roarSet = v[3], distance = v[4], mood = v[5]

        // How busy the fire is right now: it drifts between lulls and flare-ups.
        let drift = activity.step(dt, &rng, every: 2, to: 8, ease: 2.5)
        let busy = 1 - 0.85 * mood * (1 - drift)
        let width = 1 - 0.7 * distance

        // Crackles.
        let steady = Float(Soundscape.cracklesPerSecond(Double(rate))) * busy * busy
        run *= expf(-dt / 0.12)
        let perSecond = steady + run
        if perSecond > 0, DSP.rnd(&rng) < perSecond * dt {
            let ownStart = DSP.rnd(&rng) * perSecond < steady
            var s = powf(DSP.rnd(&rng), 4 - 2.6 * size)
            if !ownStart { s *= 0.4 }
            let hz = 7_000 * powf(0.3, s) * (0.7 + 0.6 * DSP.rnd(&rng))
            let q = 0.45 + 0.35 * DSP.rnd(&rng)
            let seconds = 0.00015 + 0.004 * s * s
            // Far away the small snaps are lost first.
            let reach = 1 - distance * 0.7 * (1 - s)
            let amp = (0.25 + 0.75 * powf(s, 1.3)) * (0.6 + 0.8 * DSP.rnd(&rng)) * reach
            let pan = (2 * DSP.rnd(&rng) - 1) * 0.85 * width
            let voice = crackles + next
            next = (next + 1) % Self.voices
            voice.pointee.band.set(hz, q, sr)
            voice.pointee.band.s1 = 0
            voice.pointee.band.s2 = 0
            voice.pointee.env = amp * DSP.bandNorm(hz, q, sr) * 3
            voice.pointee.fall = expf(-1 / (seconds * sr))
            voice.pointee.left = 1 - max(pan, 0)
            voice.pointee.right = 1 + min(pan, 0)
            if ownStart, DSP.rnd(&rng) < 0.18 { run += 35 + 30 * DSP.rnd(&rng) }
            flare += amp * s * 0.4
            spit += amp * 0.6
        }

        // Levels for this stretch of samples.
        let lap = flutter.step(dt, &rng, every: 0.06, to: 0.25, ease: 0.08)
        let lap2 = flutter2.step(dt, &rng, every: 0.08, to: 0.3, ease: 0.1)
        let vent = gas.step(dt, &rng, every: 0.5, to: 3, ease: 0.6)
        let roarNorm = DSP.lowpassedNorm(115, sr)
        let roarGain = 0.3 * powf(roarSet / 0.6, 1.5) * (0.6 + 0.4 * busy)
        let roarPole = DSP.pole(115, sr), dcPole = DSP.pole(28, sr)
        let bodyGain = DSP.bandNorm(400, 0.6, sr) * 0.25 * roarGain
        let hissGain = 0.5 * hissSet * hissSet * (0.5 + 0.5 * busy)
        let hissPole = DSP.pole(2_500, sr), topPole = DSP.pole(9_000, sr)
        let outPole = DSP.pole(15_000 * powf(0.085, distance), sr)
        let flareFall = expf(-1 / (0.09 * sr)), spitFall = expf(-1 / (0.05 * sr))
        let gStep = (g1 - g0) / Float(n)
        var g = g0

        for i in 0 ..< n {
            let c = DSP.noise(&rng), a = DSP.noise(&rng), b = DSP.noise(&rng)

            roarL1 += roarPole * (c + 0.35 * a - roarL1); roarL2 += roarPole * (roarL1 - roarL2)
            roarR1 += roarPole * (c - 0.35 * a - roarR1); roarR2 += roarPole * (roarR1 - roarR2)
            roarLdc += dcPole * (roarL2 - roarLdc)
            roarRdc += dcPole * (roarR2 - roarRdc)
            let lapping = roarGain * (0.45 + 0.55 * lap) + flare
            var outL = (roarL2 - roarLdc) * roarNorm * lapping
            var outR = (roarR2 - roarRdc) * roarNorm * lapping
            flare *= flareFall
            let lick = bodyGain * (0.3 + 0.7 * lap2)
            outL += bodyL.band(a) * lick
            outR += bodyR.band(b) * lick

            hissL += hissPole * (a - hissL); hissLtop += topPole * (a - hissL - hissLtop)
            hissR += hissPole * (b - hissR); hissRtop += topPole * (b - hissR - hissRtop)
            let venting = hissGain * (0.12 + 0.88 * vent * vent + spit)
            outL += hissLtop * venting
            outR += hissRtop * venting
            spit *= spitFall

            for k in 0 ..< Self.voices where crackles[k].env > 1e-5 {
                let x = crackles[k].band.band(DSP.noise(&rng)) * crackles[k].env
                crackles[k].env *= crackles[k].fall
                outL += x * crackles[k].left
                outR += x * crackles[k].right
            }

            let mid = 0.5 * (outL + outR), side = 0.5 * (outL - outR) * width
            outL1 += outPole * (mid + side - outL1); outL2 += outPole * (outL1 - outL2)
            outR1 += outPole * (mid - side - outR1); outR2 += outPole * (outR1 - outR2)
            g += gStep
            l[i] += outL2 * g
            r[i] += outR2 * g
        }
    }
}

// MARK: Kernel

/// Plays one scene on the audio thread and adds it to the output. Like `NoiseKernel` it never allocates or locks.
final class SceneKernel {
    private static let chunk = 16

    /// Set by `NoiseKernel` on the audio thread.
    var wanted = SceneParams()

    private let sr: Float
    private var kind: Int32 = -1
    private var gain: Float = 0
    private let values: UnsafeMutablePointer<Float>
    private let train: UnsafeMutablePointer<Train>
    private let fire: UnsafeMutablePointer<Fire>

    init(sampleRate: Float) {
        sr = sampleRate
        values = .allocate(capacity: 6)
        values.initialize(repeating: 0, count: 6)
        train = .allocate(capacity: 1)
        train.initialize(to: Train(sr: sampleRate))
        fire = .allocate(capacity: 1)
        fire.initialize(to: Fire(sr: sampleRate))
    }

    deinit {
        train.pointee.free()
        fire.pointee.free()
        train.deallocate()
        fire.deallocate()
        values.deallocate()
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let w = wanted
        if !w.active, gain < 1e-5 {
            gain = 0
            return
        }
        // A different scene takes over once the old one has faded out.
        if w.active, kind != w.kind, gain < 1e-4 {
            kind = w.kind
            values[0] = w.v0; values[1] = w.v1; values[2] = w.v2
            values[3] = w.v3; values[4] = w.v4; values[5] = w.v5
        }
        let target = w.active && kind == w.kind ? w.gain : 0
        var done = 0
        while done < frames {
            let n = min(Self.chunk, frames - done)
            let ease = min(1, Float(n) / (0.04 * sr))
            if kind == w.kind {
                values[0] += (w.v0 - values[0]) * ease; values[1] += (w.v1 - values[1]) * ease
                values[2] += (w.v2 - values[2]) * ease; values[3] += (w.v3 - values[3]) * ease
                values[4] += (w.v4 - values[4]) * ease; values[5] += (w.v5 - values[5]) * ease
            }
            let from = gain
            gain += (target - gain) * ease
            if kind == 0 {
                train.pointee.run(left + done, right + done, n, values, from, gain, sr)
            } else {
                fire.pointee.run(left + done, right + done, n, values, from, gain, sr)
            }
            done += n
        }
    }
}
