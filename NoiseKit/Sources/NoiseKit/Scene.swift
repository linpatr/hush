import Foundation

/// A scene is a sound made of separate events (a wheel crossing a rail joint, a crackle in a fire) on top of
/// its own background. Layers cannot make these, because a layer is one steady noise.
/// A sound can hold one scene next to its layers.
public struct Soundscape: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case train
        case fireplace
    }

    public var kind: Kind
    public var isOn: Bool
    /// Loudness in dB. A scene is mostly quiet with loud moments, so this is not its average level:
    /// at -20 the loudest clack or crackle reaches about half of full scale.
    public var level: Double
    /// One slider position from 0 to 1 per control, in the order of `controls`.
    public var values: [Double]

    public init(kind: Kind, isOn: Bool = true, level: Double = -20, values: [Double]? = nil) {
        self.kind = kind
        self.isOn = isOn
        self.level = level
        self.values = values ?? Self.controls(for: kind).map(\.standard)
    }

    /// One slider of a scene.
    public struct Control: Sendable {
        public let name: String
        public let low: String
        public let high: String
        public let note: String
        public let standard: Double
    }

    public static let maxControls = 6

    public var controls: [Control] { Self.controls(for: kind) }

    /// The slider position of control `index`, or its standard position if the saved sound has fewer values.
    public func value(_ index: Int) -> Double {
        let all = controls
        guard index < all.count else { return 0 }
        return index < values.count ? min(max(values[index], 0), 1) : all[index].standard
    }

    public mutating func set(_ index: Int, to value: Double) {
        let all = controls
        guard index < all.count else { return }
        while values.count < all.count { values.append(all[values.count].standard) }
        values[index] = min(max(value, 0), 1)
    }

    /// Train speed in km/h for a slider position.
    public static func trainSpeed(_ position: Double) -> Double { 40 + 120 * position }

    /// How many crackles a second a busy fire makes for a slider position.
    public static func cracklesPerSecond(_ position: Double) -> Double {
        position < 0.02 ? 0 : 0.6 * pow(60, position)
    }

    public static func controls(for kind: Kind) -> [Control] {
        switch kind {
        case .train:
            [
                Control(name: "Speed", low: "slow", high: "express",
                        note: "Sets how often the wheels cross a joint between two rails, and how bright the rolling is. The train drifts a little around this speed by itself.", standard: 0.4),
                Control(name: "Clack", low: "smooth track", high: "hard joints",
                        note: "How hard each wheel hits a joint. The pair of wheels under you is loud. The pairs further along the train are faint.", standard: 0.45),
                Control(name: "Rumble", low: "light", high: "heavy",
                        note: "The steady low roar of the carriage floor.", standard: 0.6),
                Control(name: "Window", low: "sealed cabin", high: "open window",
                        note: "How much high sound gets in. Sealed, you hear thuds through the floor. Open, you hear steel on steel.", standard: 0.42),
                Control(name: "Journey", low: "the same track forever", high: "always changing",
                        note: "How often the track changes: a bridge, a tunnel, a set of points, a stretch of welded rail with no joints.", standard: 0.5),
            ]
        case .fireplace:
            [
                Control(name: "Crackle", low: "embers", high: "fresh dry wood",
                        note: "How many crackles a second. They come in bursts, not evenly.", standard: 0.3),
                Control(name: "Pop size", low: "fine snaps", high: "big pops",
                        note: "A small snap is short and bright. A big pop is longer and lower, and makes the flames jump.", standard: 0.45),
                Control(name: "Hiss", low: "none", high: "sappy wood",
                        note: "Gas escaping from the wood. It comes and goes.", standard: 0.3),
                Control(name: "Roar", low: "candle", high: "big fire",
                        note: "The low fluttering sound of the flames themselves.", standard: 0.6),
                Control(name: "Distance", low: "by the hearth", high: "across the room",
                        note: "Further away the fire is duller and narrower, and the small snaps are lost.", standard: 0.35),
                Control(name: "Mood", low: "steady burn", high: "flares and lulls",
                        note: "How much the fire picks up and dies down over time.", standard: 0.5),
            ]
        }
    }
}
