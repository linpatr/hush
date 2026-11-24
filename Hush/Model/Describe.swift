import Foundation
import NoiseKit

/// Turns settings into the words and numbers shown next to the sliders.
enum Describe {
    /// A number with a real minus sign, and a plus sign when asked.
    static func number(_ value: Double, digits: Int = 1, plus: Bool = false) -> String {
        let rounded = abs(value) < 0.5 * pow(10, -Double(digits)) ? 0 : value
        let text = String(format: "%.\(digits)f", abs(rounded))
        if rounded < 0 { return "−" + text }
        return (plus && rounded > 0 ? "+" : "") + text
    }

    static func hz(_ frequency: Double) -> String {
        if frequency < 1000 { return "\(Int(frequency.rounded())) Hz" }
        let k = frequency / 1000
        return (k >= 10 || abs(k - k.rounded()) < 0.05 ? "\(Int(k.rounded()))" : String(format: "%.1f", k)) + " kHz"
    }

    static func density(_ texture: Texture) -> String {
        if texture.isContinuous { return "continuous" }
        let d = texture.density
        if d < 10 { return String(format: "%.1f per second", d) }
        if d < 1000 { return "\(Int(d.rounded())) per second" }
        return String(format: "%.1fk per second", d / 1000)
    }

    static func tilt(_ value: Double) -> String {
        number(value, plus: true) + " dB/octave"
    }

    static func rate(_ hz: Double) -> String {
        if hz < 1 {
            let period = 1 / hz
            return period >= 10 ? "every \(Int(period.rounded())) s" : String(format: "every %.1f s", period)
        }
        return String(format: "%.1f per second", hz)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func level(_ db: Double) -> String {
        number(db, digits: 0) + " dB"
    }

    static func octaves(_ value: Double) -> String {
        let thirds = value * 3
        if abs(thirds - thirds.rounded()) < 0.02, (1 ... 2).contains(Int(thirds.rounded())) {
            return thirds.rounded() == 1 ? "⅓ octave" : "⅔ octave"
        }
        return number(value, digits: 2) + (abs(value - 1) < 0.005 ? " octave" : " octaves")
    }

    // MARK: Layers

    static func title(_ layer: Layer) -> String {
        if layer.room != nil { return "Room mask" }
        let texture = layer.texture.isContinuous ? "Continuous" : ticks(layer.texture.density)
        let tilt = layer.shape.tilt
        return texture + ", " + number(tilt, digits: tilt == tilt.rounded() ? 0 : 1, plus: true) + " dB/oct"
    }

    private static func ticks(_ density: Double) -> String {
        if density < 10 { return String(format: "%.1f ticks/s", density) }
        if density < 1000 { return "\(Int(density.rounded())) ticks/s" }
        return String(format: "%.1fk ticks/s", density / 1000)
    }

    static func subtitle(_ layer: Layer) -> String {
        var parts: [String] = []
        if let room = layer.room {
            parts.append("+" + number(room.louderBy, digits: 0) + " dB")
            parts.append(octaves(room.widerBy) + " wider")
        }
        parts.append(hz(layer.shape.lowEdge) + " to " + hz(layer.shape.highEdge))
        if layer.room == nil, layer.shape.resonance.isOn {
            parts.append("peak at " + hz(layer.shape.resonance.frequency))
        }
        let motion = layer.motion
        if motion.swell > 0 || motion.hasSweep || (layer.shape.resonance.isOn && motion.hasDrift) {
            parts.append("moves " + rate(motion.rate))
        }
        return parts.joined(separator: " · ")
    }

    static func layerCount(_ sound: Sound) -> String {
        let layers = sound.layers.count == 1 ? "1 layer" : "\(sound.layers.count) layers"
        guard Features.scenes, sound.scene != nil else { return layers }
        return sound.layers.isEmpty ? "A scene" : "A scene and " + layers
    }

    // MARK: Scenes

    static func sceneName(_ kind: Soundscape.Kind) -> String {
        switch kind {
        case .train: "Train"
        case .fireplace: "Fireplace"
        }
    }

    static func sceneIcon(_ kind: Soundscape.Kind) -> String {
        switch kind {
        case .train: "tram.fill"
        case .fireplace: "flame.fill"
        }
    }

    /// The words next to slider `index` of a scene.
    static func sceneValue(_ scene: Soundscape, _ index: Int) -> String {
        let position = scene.value(index)
        switch (scene.kind, index) {
        case (.train, 0):
            return "\(Int(Soundscape.trainSpeed(position).rounded())) km/h"
        case (.fireplace, 0):
            let rate = Soundscape.cracklesPerSecond(position)
            if rate == 0 { return "none" }
            return "up to " + (rate < 10 ? number(rate, digits: 1) : "\(Int(rate.rounded()))") + " per second"
        default:
            return percent(position)
        }
    }
}
