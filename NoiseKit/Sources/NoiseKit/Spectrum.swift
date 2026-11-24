import Foundation

/// The spectrum a layer is asked to have. The synth designs its filters from this, and the app draws it.
public enum Spectrum {
    /// Frequencies the app draws, evenly spaced on a log axis from 20 Hz to 20 kHz.
    public static let displayFrequencies: [Double] = (0 ..< 140).map { 20 * pow(1000, Double($0) / 139) }

    /// The layer's power per Hz in dB at each frequency, scaled so the whole layer has the level it plays at.
    /// `motion` picks the moment: 0 is the trough of the layer's motion, 1 is the crest.
    public static func curve(
        for layer: Layer, sampleRate: Double = 48_000, motion m: Double = 1, frequencies: [Double] = displayFrequencies
    ) -> [Double] {
        let moving = layer.motion
        let shape = ShapeCurve(layer: layer, tiltOffset: moving.hasSweep ? moving.sweep * m : 0)
        let peak = Peak(layer.shape.resonance, shiftedBy: moving.hasDrift ? moving.drift * m : 0, sampleRate: sampleRate)

        func power(_ f: Double) -> Double {
            pow(10, shape.db(f) / 10) * (peak?.power(f) ?? 1)
        }

        // Total power, so the curve can be scaled to the layer's level. Integrated on a log axis: df = f d(ln f).
        let points = 1500
        let low = 4.0, high = sampleRate / 2
        let step = log(high / low) / Double(points)
        var total = 0.0
        for i in 0 ..< points {
            let f = low * exp((Double(i) + 0.5) * step)
            total += power(f) * f * step
        }

        let swell = 1 - moving.swell * (1 - m * m)
        var gain = pow(10, layer.playedLevel / 10) * swell * swell
        if !layer.texture.isContinuous {
            // Sparse ticks carry less power than a full hiss at the same setting.
            let perSample = layer.texture.density / sampleRate
            gain *= perSample * pow(grainAmplitude(eventsPerSample: perSample), 2)
        }
        let scale = gain / max(total, 1e-300)
        return frequencies.map { 10 * log10(max(power($0) * scale, 1e-30)) }
    }

    /// The power of several curves added together, in dB.
    public static func sum(_ curves: [[Double]]) -> [Double] {
        guard let first = curves.first else { return [] }
        return first.indices.map { i in
            10 * log10(max(curves.reduce(0) { $0 + pow(10, $1[i] / 10) }, 1e-30))
        }
    }

    /// How tall a single tick is when ticks happen `eventsPerSample` of the time. Dense ticks shrink so the power
    /// stays the same; sparse ticks stop growing at 6 so a lone tick cannot be far louder than the hiss.
    static func grainAmplitude(eventsPerSample p: Double) -> Double {
        min(1 / max(p, 1e-9).squareRoot(), 6)
    }
}

/// Tilt, band edges and (for a room mask) the measured curve, as power in dB at a frequency. Unscaled.
struct ShapeCurve: Equatable {
    var tilt: Double
    var lowEdge: Double
    var highEdge: Double
    var room: [Float]?

    init(layer: Layer, tiltOffset: Double = 0) {
        tilt = layer.shape.tilt + tiltOffset
        lowEdge = layer.shape.lowEdge
        highEdge = layer.shape.highEdge
        room = layer.room?.bands()
    }

    func db(_ frequency: Double) -> Double {
        let f = max(frequency, 1e-3)
        var d = tilt * log2(f / 1000)
        // The edges fall away at 24 dB per octave.
        var below = lowEdge / f
        below *= below; below *= below; below *= below
        d -= 10 * log10(1 + below)
        var above = f / highEdge
        above *= above; above *= above; above *= above
        d -= 10 * log10(1 + above)
        if let room, !room.isEmpty {
            let x = min(max(RoomProfile.position(of: f), 0), Double(room.count - 1))
            let i = min(Int(x), room.count - 2)
            let t = Float(x - Double(i))
            d += Double(room[i] + (room[i + 1] - room[i]) * t)
        }
        return d
    }
}

/// The resonance as the synth plays it: the input plus a band-pass copy of itself.
struct Peak: Equatable {
    var frequency: Double
    /// 1 / Q.
    var damping: Double
    /// Amplitude gain at the center.
    var gain: Double
    var sampleRate: Double

    init?(_ resonance: Resonance, shiftedBy octaves: Double = 0, sampleRate: Double) {
        guard resonance.isOn else { return nil }
        frequency = min(max(resonance.frequency * pow(2, octaves), 10), sampleRate * 0.45)
        damping = 1 / max(resonance.sharpness, 0.1)
        gain = pow(10, resonance.strength / 20)
        self.sampleRate = sampleRate
    }

    /// Power gain at a frequency.
    func power(_ f: Double) -> Double {
        // The digital filter matches the analog one with the frequency axis bent by tan().
        let nyquist = sampleRate / 2
        let w = tan(.pi / 2 * min(f, nyquist * 0.9999) / nyquist) / tan(.pi / 2 * frequency / nyquist)
        let a = (1 - w * w) * (1 - w * w)
        let b = w * damping
        return (a + b * b * gain * gain) / (a + b * b)
    }
}

extension Spectrum {
    /// For a room mask: the mask drawn on the room's own scale, at `RoomProfile.centers`.
    /// It is the room's spectrum, widened, raised by the level margin and cut at the layer's band edges.
    public static func maskOverRoom(_ layer: Layer) -> [Double] {
        guard let room = layer.room else { return [] }
        let shape = ShapeCurve(layer: layer)
        return RoomProfile.centers.map { shape.db($0) + room.louderBy }
    }
}
