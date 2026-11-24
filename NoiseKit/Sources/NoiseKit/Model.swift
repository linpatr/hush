import Foundation

/// A sound is a stack of noise layers, added together.
public struct Sound: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var layers: [Layer]
    /// A sound made of events (a train, a fire) that plays next to the layers. Most sounds have none.
    public var scene: Soundscape?

    public static let maxLayers = 6

    public init(id: UUID = UUID(), name: String, layers: [Layer], scene: Soundscape? = nil) {
        self.id = id
        self.name = name
        self.layers = layers
        self.scene = scene
    }
}

/// One noise, described by four things: what it is made of (texture), which frequencies it holds (shape),
/// how it changes over time (motion) and how it sits between the ears (space).
public struct Layer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var isOn: Bool
    /// Loudness as an RMS level in dB below full scale. For a room mask this is the cover point.
    public var level: Double
    public var texture: Texture
    public var shape: SpectralShape
    public var motion: Motion
    public var space: Space
    /// When set, the shape follows a measured room instead of the tilt.
    public var room: RoomMask?
    /// Which color the layer is drawn in.
    public var tint: Int

    public static let levelRange = -60.0 ... -6.0

    public init(
        id: UUID = UUID(), isOn: Bool = true, level: Double = -24,
        texture: Texture = Texture(), shape: SpectralShape = SpectralShape(), motion: Motion = Motion(), space: Space = Space(),
        room: RoomMask? = nil, tint: Int = 0
    ) {
        self.id = id
        self.isOn = isOn
        self.level = level
        self.texture = texture
        self.shape = shape
        self.motion = motion
        self.space = space
        self.room = room
        self.tint = tint
    }

    /// The level the layer plays at, in dB below full scale.
    public var playedLevel: Double {
        min(0, level + (room?.louderBy ?? 0))
    }
}

/// What the noise is made of in time: a new random value on every sample (a smooth hiss),
/// or separate random ticks with silence between them (crackle, drops).
public struct Texture: Codable, Equatable, Sendable {
    /// Random events per second. At `continuousFrom` and above, every sample is random.
    public var density: Double

    public static let densityRange = 1.0 ... 48_000.0
    public static let continuousFrom = 24_000.0

    public init(density: Double = 48_000) {
        self.density = density
    }

    public var isContinuous: Bool { density >= Self.continuousFrom }
}

/// Which frequencies the noise holds.
public struct SpectralShape: Codable, Equatable, Sendable {
    /// How the power leans across frequency, in dB per octave. 0 is flat, negative is deeper, positive is thinner.
    public var tilt: Double
    /// The lowest frequency present, in Hz.
    public var lowEdge: Double
    /// The highest frequency present, in Hz.
    public var highEdge: Double
    public var resonance: Resonance

    public static let tiltRange = -12.0 ... 12.0
    public static let lowEdgeRange = 20.0 ... 5_000.0
    public static let highEdgeRange = 100.0 ... 20_000.0

    public init(tilt: Double = -3, lowEdge: Double = 20, highEdge: Double = 20_000, resonance: Resonance = Resonance()) {
        self.tilt = tilt
        self.lowEdge = lowEdge
        self.highEdge = highEdge
        self.resonance = resonance
    }
}

/// A peak at one frequency. A strong, sharp peak turns noise into a pitch: a hum or a whistle.
public struct Resonance: Codable, Equatable, Sendable {
    /// Where the peak is, in Hz.
    public var frequency: Double
    /// How far the peak rises above the rest, in dB. 0 means no peak.
    public var strength: Double
    /// How narrow the peak is (its Q: center frequency divided by width).
    public var sharpness: Double

    public static let frequencyRange = 30.0 ... 12_000.0
    public static let strengthRange = 0.0 ... 36.0
    public static let sharpnessRange = 0.7 ... 40.0

    public init(frequency: Double = 400, strength: Double = 0, sharpness: Double = 4) {
        self.frequency = frequency
        self.strength = strength
        self.sharpness = sharpness
    }

    public var isOn: Bool { strength > 0.05 }
}

/// How the noise changes over time. One slow signal rises and falls between a trough and a crest;
/// swell, sweep and drift say what the crest does to loudness, tilt and resonance.
public struct Motion: Codable, Equatable, Sendable {
    /// Cycles per second.
    public var rate: Double
    /// 0 repeats exactly. Higher makes each cycle a different height and length.
    public var randomness: Double
    /// Part of each cycle spent rising. 0.5 rises and falls evenly; less rises quickly and falls slowly.
    public var rise: Double
    /// How far behind this layer runs, as a part of one cycle. Layers with the same rate and randomness
    /// share one clock, so a delay sets one behind another.
    public var delay: Double
    /// How far the loudness falls in the trough: 0 not at all, 1 to silence.
    public var swell: Double
    /// dB per octave added to the tilt at the crest.
    public var sweep: Double
    /// Octaves the resonance moves at the crest.
    public var drift: Double

    public static let rateRange = 0.02 ... 20.0
    public static let riseRange = 0.05 ... 0.95
    public static let sweepRange = -9.0 ... 9.0
    public static let driftRange = -2.0 ... 2.0

    public init(rate: Double = 0.12, randomness: Double = 0.3, swell: Double = 0, sweep: Double = 0, drift: Double = 0, rise: Double = 0.5, delay: Double = 0) {
        self.rate = rate
        self.randomness = randomness
        self.rise = rise
        self.delay = delay
        self.swell = swell
        self.sweep = sweep
        self.drift = drift
    }

    /// Sounds saved before `rise` and `delay` existed have no value for them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rate = try c.decode(Double.self, forKey: .rate)
        randomness = try c.decode(Double.self, forKey: .randomness)
        swell = try c.decode(Double.self, forKey: .swell)
        sweep = try c.decode(Double.self, forKey: .sweep)
        drift = try c.decode(Double.self, forKey: .drift)
        rise = try c.decodeIfPresent(Double.self, forKey: .rise) ?? 0.5
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
    }

    public var hasSweep: Bool { abs(sweep) > 0.01 }
    public var hasDrift: Bool { abs(drift) > 0.001 }
}

/// How the noise sits between the two ears.
public struct Space: Codable, Equatable, Sendable {
    /// 0 plays the same noise in both ears (it sits in the middle). 1 plays unrelated noise in each ear (it surrounds).
    public var width: Double

    public init(width: Double = 0.6) {
        self.width = width
    }
}

/// A shape taken from a recording of the room, widened and raised by a margin.
public struct RoomMask: Codable, Equatable, Sendable {
    public var profile: RoomProfile
    /// Level margin in dB above the cover point.
    public var louderBy: Double
    /// Frequency margin: how far the mask reaches to each side of every measured sound, in octaves.
    public var widerBy: Double
    /// Whether the cover point (the layer's level) has been set by ear.
    public var coverIsSet: Bool

    public static let louderByRange = 0.0 ... 18.0
    public static let widerByRange = 0.0 ... 1.0

    public init(profile: RoomProfile, louderBy: Double = 6, widerBy: Double = 1.0 / 3, coverIsSet: Bool = false) {
        self.profile = profile
        self.louderBy = louderBy
        self.widerBy = widerBy
        self.coverIsSet = coverIsSet
    }

    /// The room's spectrum widened by `widerBy`: each band takes the loudest value within that distance.
    public func bands() -> [Float] {
        let source = profile.bands
        guard !source.isEmpty else { return source }
        let radius = max(0, widerBy) * Double(RoomProfile.bandsPerOctave)
        let whole = Int(radius.rounded(.down))
        let fraction = Float(radius - Double(whole))

        func widened(_ r: Int) -> [Float] {
            guard r > 0 else { return source }
            return source.indices.map { i in
                source[max(0, i - r) ... min(source.count - 1, i + r)].max() ?? source[i]
            }
        }
        let near = widened(whole)
        let far = fraction > 0 ? widened(whole + 1) : near
        let blended = zip(near, far).map { $0 + ($1 - $0) * fraction }
        // A light smoothing takes the corners off the widened peaks.
        return blended.indices.map { i in
            let a = blended[max(0, i - 1)], b = blended[i], c = blended[min(blended.count - 1, i + 1)]
            return 0.25 * a + 0.5 * b + 0.25 * c
        }
    }
}

/// The measured spectrum of a room: power per Hz in sixth-octave bands.
public struct RoomProfile: Codable, Equatable, Sendable {
    public var date: Date
    /// How long the recording was.
    public var seconds: Double
    /// Overall RMS level in dB below the microphone's full scale.
    public var level: Double
    /// Power density in dB (relative to full scale squared per Hz) at each of `centers`.
    public var bands: [Float]
    /// True when the samples came from the built-in test room instead of a microphone.
    public var simulated: Bool

    public static let bandsPerOctave = 6
    public static let bandCount = 61
    /// Band centers from about 20 Hz to about 20 kHz.
    public static let centers: [Double] = (0 ..< bandCount).map { center($0) }

    public static func center(_ index: Int) -> Double {
        1000 * pow(2, Double(index - 34) / Double(bandsPerOctave))
    }

    /// Position of a frequency on the band axis, as a fractional index.
    public static func position(of frequency: Double) -> Double {
        log2(frequency / 1000) * Double(bandsPerOctave) + 34
    }

    public init(date: Date, seconds: Double, level: Double, bands: [Float], simulated: Bool = false) {
        self.date = date
        self.seconds = seconds
        self.level = level
        self.bands = bands
        self.simulated = simulated
    }
}
