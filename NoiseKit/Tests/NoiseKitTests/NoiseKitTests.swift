import Foundation
import Testing
@testable import NoiseKit

private let rate = 48_000.0

/// Band levels (power per Hz, dB) of a signal, measured the same way a room is.
private func measure(_ samples: [Float]) -> [Float] {
    let analyzer = RoomAnalyzer(sampleRate: rate)
    analyzer.append(samples)
    return analyzer.bands()!
}

private func rmsDB(_ samples: [Float]) -> Double {
    let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
    return 10 * log10(power)
}

/// The wanted curve at the band centers.
private func wanted(_ layer: Layer, motion: Double = 1) -> [Double] {
    Spectrum.curve(for: layer, sampleRate: rate, motion: motion, frequencies: RoomProfile.centers)
}

/// Largest difference between measured and wanted, over bands whose center lies in `range`.
private func worstError(_ measured: [Float], _ target: [Double], in range: ClosedRange<Double>) -> Double {
    var worst = 0.0
    for (i, center) in RoomProfile.centers.enumerated() where range.contains(center) {
        worst = max(worst, abs(Double(measured[i]) - target[i]))
    }
    return worst
}

@Test func fftScalesAreMeasured() {
    let fft = RealFFT(size: 1024)
    #expect(fft.forwardScale == 2)
    #expect(fft.roundTripScale == 2048)
}

@Test func analyzerReadsWhiteNoiseAsFlat() {
    // White noise of power P has P / (rate / 2) per Hz at every frequency.
    var generator = SystemRandomNumberGenerator()
    let amplitude: Float = 0.1
    let samples = (0 ..< Int(rate) * 20).map { _ in Float.random(in: -1 ... 1, using: &generator) * amplitude }
    let power = Double(amplitude * amplitude) / 3
    let expected = 10 * log10(power / (rate / 2))
    let bands = measure(samples)
    for (i, center) in RoomProfile.centers.enumerated() where center > 40 && center < 18_000 {
        #expect(abs(Double(bands[i]) - expected) < 1.5, "band at \(Int(center)) Hz reads \(bands[i]), expected \(expected)")
    }
}

@Test(arguments: [-6.0, -3.0, 0.0, 3.0])
func tiltGivesTheWantedSlopeAndLevel(tilt: Double) {
    let layer = Layer(level: -20, shape: SpectralShape(tilt: tilt, lowEdge: 40, highEdge: 12_000), space: Space(width: 0))
    let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: 30)
    #expect(abs(rmsDB(out.left) - (-20)) < 0.5, "level is \(rmsDB(out.left))")
    let error = worstError(measure(out.left), wanted(layer), in: 60 ... 9_000)
    #expect(error < 1.5, "worst band error \(error) dB at tilt \(tilt)")
}

@Test func resonanceAppearsWhereAsked() {
    let layer = Layer(
        level: -20,
        shape: SpectralShape(tilt: -3, resonance: Resonance(frequency: 1_000, strength: 18, sharpness: 6)),
        space: Space(width: 0)
    )
    let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: 30)
    #expect(abs(rmsDB(out.left) - (-20)) < 0.6)
    let error = worstError(measure(out.left), wanted(layer), in: 60 ... 12_000)
    #expect(error < 1.5, "worst band error \(error) dB")
}

@Test func widthSetsHowAlikeTheEarsAre() {
    for width in [0.0, 0.5, 1.0] {
        let layer = Layer(level: -20, space: Space(width: width))
        let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: 10)
        var lr = 0.0, ll = 0.0, rr = 0.0
        for i in out.left.indices {
            lr += Double(out.left[i]) * Double(out.right[i])
            ll += Double(out.left[i]) * Double(out.left[i])
            rr += Double(out.right[i]) * Double(out.right[i])
        }
        let correlation = lr / (ll * rr).squareRoot()
        #expect(abs(correlation - (1 - width)) < 0.05, "width \(width) gave correlation \(correlation)")
        #expect(abs(10 * log10(rr / ll)) < 0.3, "the two ears differ in level")
    }
}

@Test func sparseTextureMakesSeparateTicks() {
    // Flat shape and no edges to speak of: each tick stays a single sample, so ticks can be counted.
    let layer = Layer(
        level: -20, texture: Texture(density: 50),
        shape: SpectralShape(tilt: 0, lowEdge: 20, highEdge: 20_000), space: Space(width: 0)
    )
    let seconds = 40.0
    let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: seconds)
    let peak = out.left.map { abs($0) }.max()!
    #expect(peak <= 1)
    // Count moments where the signal jumps well above its surroundings.
    var ticks = 0
    var quietFor = 100
    for sample in out.left {
        if abs(sample) > peak * 0.05 {
            if quietFor > 40 { ticks += 1 }
            quietFor = 0
        } else {
            quietFor += 1
        }
    }
    let perSecond = Double(ticks) / seconds
    #expect(perSecond > 30 && perSecond < 55, "counted \(perSecond) ticks per second")
}

@Test func swellRisesAndFallsAtTheRate() {
    let layer = Layer(
        level: -20, shape: SpectralShape(tilt: 0),
        motion: Motion(rate: 2, randomness: 0, swell: 1), space: Space(width: 0)
    )
    let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: 20)
    // Loudness in 10 ms steps, then count the times it climbs through the halfway line.
    let step = Int(rate / 100)
    var envelope: [Double] = []
    var i = 0
    while i + step <= out.left.count {
        envelope.append(out.left[i ..< i + step].reduce(0.0) { $0 + Double($1) * Double($1) })
        i += step
    }
    // Smooth over 50 ms so the noise's own flicker does not count as a crossing.
    let smooth = envelope.indices.map { j in
        envelope[max(0, j - 2) ... min(envelope.count - 1, j + 2)].reduce(0, +) / 5
    }
    let middle = smooth.max()! * 0.3
    var crossings = 0
    for j in 1 ..< smooth.count where smooth[j - 1] < middle && smooth[j] >= middle {
        crossings += 1
    }
    #expect(abs(Double(crossings) / 20 - 2) < 0.3, "counted \(Double(crossings) / 20) swells per second")
}

@Test func sweepMovesBetweenTheTwoShapes() {
    // A very slow regular sweep: the first quarter of a cycle is near the trough, the middle near the crest.
    let layer = Layer(
        level: -20, shape: SpectralShape(tilt: -4, lowEdge: 40, highEdge: 12_000),
        motion: Motion(rate: 0.02, randomness: 0, swell: 0, sweep: 6), space: Space(width: 0)
    )
    let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: 49)
    // The render drops its first second, so the cycle (50 s) is 1 s in: the crest is at 24 s of what is left.
    let trough = Array(out.left[0 ..< Int(rate * 3)])
    let crest = Array(out.left[Int(rate * 21) ..< Int(rate * 27)])
    let slope = { (bands: [Float]) -> Double in
        // dB per octave between 250 Hz and 4 kHz (4 octaves apart)
        let low = RoomProfile.centers.firstIndex { $0 >= 250 }!
        return Double(bands[low + 24] - bands[low]) / 4
    }
    #expect(abs(slope(measure(trough)) - (-4)) < 1.2, "trough slope \(slope(measure(trough)))")
    #expect(abs(slope(measure(crest)) - 2) < 1.2, "crest slope \(slope(measure(crest)))")
}

@Test func roomMaskCoversTheRoomWithItsMargins() {
    // Record the test room, build a mask from it, play the mask, and measure what comes out.
    let recording = TestRoom.samples(sampleRate: rate, seconds: 12)
    let analyzer = RoomAnalyzer(sampleRate: rate)
    analyzer.append(recording)
    let profile = analyzer.profile()!

    // The hum and the whine must show up as peaks above their surroundings.
    let hum = RoomProfile.centers.firstIndex { $0 >= 118 }!
    let whine = RoomProfile.centers.firstIndex { $0 >= 2_750 }!
    #expect(profile.bands[hum] > profile.bands[hum + 6] + 10)
    #expect(profile.bands[whine] > profile.bands[whine - 6] + 10)

    let mask = Layer(
        level: -30, shape: SpectralShape(tilt: 0, lowEdge: 50, highEdge: 16_000), space: Space(width: 0),
        room: RoomMask(profile: profile, louderBy: 6, widerBy: 1.0 / 3)
    )
    let out = TestRoom.render(Sound(name: "mask", layers: [mask]), sampleRate: rate, seconds: 30)
    // Level: cover point plus the margin.
    #expect(abs(rmsDB(out.left) - (-24)) < 0.6, "mask level is \(rmsDB(out.left))")

    // Shape: at every band the mask, shifted to sit on the room's loudest band, must reach at least the room.
    let played = measure(out.left)
    let shift = profile.bands[hum] - played[hum]
    for (i, center) in RoomProfile.centers.enumerated() where center > 80 && center < 12_000 {
        #expect(played[i] + shift > profile.bands[i] - 2.5,
                "mask falls short of the room at \(Int(center)) Hz: \(played[i] + shift) vs \(profile.bands[i])")
    }
    // And it reaches a third of an octave to each side of the hum.
    #expect(played[hum + 2] + shift > profile.bands[hum] - 3)
    #expect(played[hum - 2] + shift > profile.bands[hum] - 3)
}

@Test func sixLayersRenderFarFasterThanRealTime() {
    var layers: [Layer] = []
    for i in 0 ..< 6 {
        layers.append(Layer(
            level: -30, texture: Texture(density: i == 0 ? 200 : 48_000),
            shape: SpectralShape(tilt: -3, resonance: Resonance(frequency: 500, strength: 12, sharpness: 5)),
            motion: Motion(rate: 0.3, randomness: 0.5, swell: 0.5, sweep: 3, drift: 0.5),
            space: Space(width: 1)
        ))
    }
    let seconds = 20.0
    let start = Date()
    let out = TestRoom.render(Sound(name: "heavy", layers: layers), sampleRate: rate, seconds: seconds)
    let took = Date().timeIntervalSince(start)
    #expect(out.left.allSatisfy { $0.isFinite && abs($0) <= 1 })
    print("6 heavy layers: \(String(format: "%.1f", took / (seconds + 1) * 100))% of one core")
    #expect(took < seconds * 0.25)
}

@Test(arguments: [0.0, -3.0, -6.0])
func steadyNoiseDoesNotFlutterOrClick(tilt: Double) {
    // The engine works in blocks of 4096 samples. A mistake where blocks join would repeat every block,
    // so fold the output over the block length and look for any position that stands out.
    let block = NoiseKernel.fftSize / 2
    let layer = Layer(level: -20, shape: SpectralShape(tilt: tilt, lowEdge: 20, highEdge: tilt < -4 ? 2_000 : 20_000), space: Space(width: 0.6))
    let out = TestRoom.render(Sound(name: "t", layers: [layer]), sampleRate: rate, seconds: 120)
    for channel in [out.left, out.right] {
        // Loudness by position in the block, in 32 steps.
        let steps = 32
        var power = [Double](repeating: 0, count: steps)
        // Size of the jump from one sample to the next, by position in the block.
        var jump = [Double](repeating: 0, count: block)
        let blocks = channel.count / block
        for b in 0 ..< blocks {
            for i in 0 ..< block {
                let n = b * block + i
                let x = Double(channel[n])
                power[i * steps / block] += x * x
                if n > 0 {
                    let d = x - Double(channel[n - 1])
                    jump[i] += d * d
                }
            }
        }
        let meanPower = power.reduce(0, +) / Double(steps)
        let spread = 10 * log10(power.max()! / power.min()!)
        // Chance alone gives about 0.5 dB here for the deepest noise, whatever length it is folded over.
        #expect(spread < 1.0, "loudness changes by \(spread) dB across the block at tilt \(tilt), mean \(meanPower)")
        let meanJump = jump.reduce(0, +) / Double(block)
        let worst = jump.max()! / meanJump
        #expect(worst < 1.6, "a jump \(worst) times the usual size repeats every block at tilt \(tilt)")
    }
}

@Test func layersWithTheSameRateAndPatternMoveTogether() {
    // A low layer and a high layer on one clock. Split them apart again and compare their loudness over time.
    let motion = Motion(rate: 0.5, randomness: 0.8, swell: 1)
    let low = Layer(level: -20, shape: SpectralShape(tilt: 0, lowEdge: 100, highEdge: 300), motion: motion, space: Space(width: 0))
    let high = Layer(level: -20, shape: SpectralShape(tilt: 0, lowEdge: 4_000, highEdge: 8_000), motion: motion, space: Space(width: 0))
    let out = TestRoom.render(Sound(name: "t", layers: [low, high]), sampleRate: rate, seconds: 60).left
    let window = 2_400
    var lows: [Double] = [], highs: [Double] = []
    var sum = 0.0
    var index = 64
    while index + window < out.count {
        var lowPower = 0.0, highPower = 0.0
        for n in index ..< index + window {
            // The mean of 64 samples keeps the low layer; the step between samples keeps the high one.
            if n == index { sum = 0; for k in 0 ..< 64 { sum += Double(out[n - k]) } } else { sum += Double(out[n]) - Double(out[n - 64]) }
            lowPower += sum * sum
            let step = Double(out[n]) - Double(out[n - 1])
            highPower += step * step
        }
        lows.append(lowPower.squareRoot()); highs.append(highPower.squareRoot())
        index += window
    }
    let meanLow = lows.reduce(0, +) / Double(lows.count), meanHigh = highs.reduce(0, +) / Double(highs.count)
    var top = 0.0, a = 0.0, b = 0.0
    for i in lows.indices {
        top += (lows[i] - meanLow) * (highs[i] - meanHigh)
        a += (lows[i] - meanLow) * (lows[i] - meanLow)
        b += (highs[i] - meanHigh) * (highs[i] - meanHigh)
    }
    let match = top / (a * b).squareRoot()
    #expect(match > 0.85, "the two layers' loudness matches only \(match)")
}

// MARK: Scenes

/// Writes a render to HUSH_RENDER_DIR (when set) as raw 32-bit floats, left then right, so it can be looked at.
private func dump(_ name: String, _ out: (left: [Float], right: [Float])) {
    guard let folder = ProcessInfo.processInfo.environment["HUSH_RENDER_DIR"] else { return }
    for (side, samples) in [("L", out.left), ("R", out.right)] {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: URL(fileURLWithPath: folder).appending(path: "\(name)-\(side).f32"))
    }
}

private func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

/// Loudness in steps of 10 ms, in dB.
private func envelope(_ samples: [Float]) -> [Double] {
    let step = Int(rate / 100)
    return stride(from: 0, to: samples.count - step, by: step).map { rmsDB(Array(samples[$0 ..< $0 + step])) }
}

private func scene(_ kind: Soundscape.Kind, _ changes: [Int: Double] = [:], seconds: Double = 60) -> (left: [Float], right: [Float]) {
    var scene = Soundscape(kind: kind, level: -20)
    for (index, value) in changes { scene.set(index, to: value) }
    return TestRoom.render(Sound(name: "s", layers: [], scene: scene), sampleRate: rate, seconds: seconds)
}

@Test(arguments: Soundscape.Kind.allCases)
func sceneAtItsDefaultsIsHeardAndDoesNotClip(kind: Soundscape.Kind) {
    let out = scene(kind, seconds: 120)
    dump(kind.rawValue, out)
    #expect(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
    let level = (rmsDB(out.left) + rmsDB(out.right)) / 2
    #expect(level > -36 && level < -22, "\(kind.rawValue) plays at \(level) dB")
    // The limiter starts to bend the sound at 0.8.
    #expect(max(peak(out.left), peak(out.right)) < 0.8, "\(kind.rawValue) peaks at \(peak(out.left))")
}

@Test func aSoundWithoutASceneOrWithItSwitchedOffIsSilent() {
    var off = Soundscape(kind: .train)
    off.isOn = false
    let out = TestRoom.render(Sound(name: "s", layers: [], scene: off), sampleRate: rate, seconds: 2)
    #expect(peak(out.left) == 0)
}

@Test func trainClacksOncePerRail() {
    // Journey at 0 keeps the track the same. At slider 0.4 the train does 88 km/h (±10% drift), and rails
    // are 18.3 m, so the loud pair comes round every 0.75 s. The envelope must repeat at that spacing.
    let env = envelope(scene(.train, [4: 0, 2: 0.3], seconds: 60).left)
    let mean = env.reduce(0, +) / Double(env.count)
    let centered = env.map { $0 - mean }
    func repeatAt(_ lag: Int) -> Double {
        var sum = 0.0, power = 0.0
        for i in 0 ..< centered.count - lag { sum += centered[i] * centered[i + lag] }
        for value in centered { power += value * value }
        return sum / power
    }
    let best = (55 ... 95).max { repeatAt($0) < repeatAt($1) }!
    #expect((66 ... 84).contains(best), "the envelope repeats every \(best * 10) ms")
    // 1 would be an exact repeat, 0 no rhythm at all.
    #expect(repeatAt(best) > 0.4, "no clear rhythm: \(repeatAt(best))")
}

@Test func moreCrackleMeansMoreCrackles() {
    // A crackle lasts a millisecond or so. It shows as a 2 ms window whose peak stands 4 times above the usual one.
    func jumps(_ position: Double) -> Int {
        let samples = scene(.fireplace, [0: position, 5: 0], seconds: 60).left
        let step = 96
        let peaks = stride(from: 0, to: samples.count - step, by: step).map { start in
            samples[start ..< start + step].reduce(Float(0)) { max($0, abs($1)) }
        }
        let usual = peaks.sorted()[peaks.count / 2]
        return peaks.indices.dropFirst().filter { peaks[$0] > 4 * usual && peaks[$0 - 1] <= 4 * usual }.count
    }
    let none = jumps(0), some = jumps(0.4), many = jumps(0.8)
    #expect(none == 0, "\(none) crackles with the slider at zero")
    #expect(some > 20 && Double(many) > 1.5 * Double(some), "\(some) crackles at 0.4, \(many) at 0.8")
}

@Test(arguments: Soundscape.Kind.allCases, [0.0, 1.0])
func sceneSurvivesEverySliderAtItsEnd(kind: Soundscape.Kind, position: Double) {
    let out = scene(kind, Dictionary(uniqueKeysWithValues: (0 ..< Soundscape.maxControls).map { ($0, position) }), seconds: 40)
    #expect(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
    print("\(kind.rawValue) with sliders at \(position): \(rmsDB(out.left)) dB, peak \(peak(out.left))")
}
