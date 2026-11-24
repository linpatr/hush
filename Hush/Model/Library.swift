import Foundation
import NoiseKit

/// Switches for parts of the app that are built but not shown.
enum Features {
    /// The Scenes section (train, fireplace). Off: Patrick heard them and they do not sound real yet.
    static let scenes = false
}

/// What is kept between launches: the sound being edited and the saved ones.
struct Library: Codable {
    var current: Sound
    var saved: [Sound]

    private static var file: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Hush", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "library.json")
    }

    static func load() -> Library {
        if let data = try? Data(contentsOf: file), let library = try? JSONDecoder().decode(Library.self, from: data) {
            return retiring(library)
        }
        var first = StartingPoints.deepStatic
        first.id = UUID()
        return Library(current: first, saved: [])
    }

    /// If the open sound is one of the retired starting points, opens the default in its place.
    /// A room mask in it is kept, because that was measured, not part of the starting point.
    private static func retiring(_ library: Library) -> Library {
        var library = library
        if !Features.scenes, library.current.scene != nil {
            // Scenes are switched off. A sound that was only a scene would be silent, so open the default.
            // The scene stays in saved sounds, untouched, for when the switch goes back on.
            library.current.scene = nil
            if library.current.layers.isEmpty {
                library.current = StartingPoints.deepStatic
                library.current.id = UUID()
            }
        }
        guard StartingPoints.retired.contains(library.current.name) else { return library }
        let masks = library.current.layers.filter { $0.room != nil }
        library.current = StartingPoints.deepStatic
        library.current.id = UUID()
        library.current.layers.insert(contentsOf: masks, at: 0)
        return library
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}

/// Sounds to start from. Each is only a set of slider positions; nothing here is a recording.
/// `all` is the list Patrick kept after listening. No ticks in those: they sounded bad.
enum StartingPoints {
    struct Entry: Identifiable {
        let sound: Sound
        let note: String
        var id: UUID { sound.id }
    }

    static let deepStatic = Sound(name: "Deep static", layers: [
        Layer(level: -20, shape: SpectralShape(tilt: -6), space: Space(width: 0.7), tint: 2),
    ])

    /// Names of starting points from the first build that imitated rain, surf, wind, a fan and a fire.
    /// They were removed after being heard on a phone.
    static let retired: Set<String> = ["Rain", "Surf", "Wind", "Fan", "Fire"]

    /// Sounds built on a scene. A scene is made of separate events, which layers cannot make.
    static let scenes: [Entry] = [
        Entry(
            sound: Sound(name: "Train to somewhere", layers: [], scene: Soundscape(kind: .train)),
            note: "Wheels over rail joints, heard from inside a carriage. The track changes as you go."
        ),
        Entry(
            sound: Sound(name: "Fireplace", layers: [], scene: Soundscape(kind: .fireplace)),
            note: "Crackles in bursts, hiss, and the low flutter of the flames."
        ),
    ]

    static let all: [Entry] = [
        Entry(sound: deepStatic, note: "A steep lean to the lows. Fullest on headphones or a real speaker."),
        Entry(
            sound: Sound(name: "Rumble", layers: [
                Layer(level: -18, shape: SpectralShape(tilt: -6, lowEdge: 20, highEdge: 600), space: Space(width: 0.7), tint: 5),
            ]),
            note: "Deep static with everything above 600 Hz cut off. A phone's own speaker can barely play it."
        ),
        Entry(
            sound: Sound(name: "Low rumble", layers: [
                Layer(level: -20, shape: SpectralShape(tilt: -7, lowEdge: 20, highEdge: 300), space: Space(width: 0.5), tint: 0),
            ]),
            note: "Between Rumble and Vacuum: nothing above 300 Hz. Needs headphones."
        ),
        Entry(
            sound: Sound(name: "Vacuum", layers: [
                Layer(level: -22, shape: SpectralShape(tilt: -9, lowEdge: 20, highEdge: 150), space: Space(width: 0.3), tint: 3),
            ]),
            note: "Only very low sound: nothing above 150 Hz. A faint, sealed-in pressure. Needs headphones; a phone's speaker cannot play it."
        ),
        Entry(
            sound: Sound(name: "Submarine", layers: [
                Layer(level: -22, shape: SpectralShape(tilt: -9, lowEdge: 20, highEdge: 180),
                      motion: Motion(rate: 0.04, randomness: 1, swell: 0.2), space: Space(width: 0.3), tint: 3),
                Layer(level: -30,
                      shape: SpectralShape(tilt: -8, lowEdge: 30, highEdge: 200,
                                           resonance: Resonance(frequency: 60, strength: 10, sharpness: 15)),
                      space: Space(width: 0.2), tint: 4),
            ]),
            note: "Vacuum's deep pressure with a slow, slight waver and a faint hum at 60 Hz. Needs headphones."
        ),
        Entry(
            sound: Sound(name: "Ship's cabin", layers: [
                Layer(level: -22, shape: SpectralShape(tilt: -7, lowEdge: 20, highEdge: 400), space: Space(width: 0.5), tint: 5),
                Layer(level: -24,
                      shape: SpectralShape(tilt: -8, lowEdge: 25, highEdge: 120,
                                           resonance: Resonance(frequency: 50, strength: 10, sharpness: 6)),
                      motion: Motion(rate: 2, randomness: 0.1, swell: 0.5), space: Space(width: 0.2), tint: 1),
            ]),
            note: "A soft rumble with a deep engine throb around 50 Hz that pulses twice a second. Needs headphones."
        ),
        Entry(
            // One wave is three layers on one clock (same rate and pattern): a low surge that builds first,
            // the crash, and a thin fizz that peaks after it. A second, smaller wave runs on its own clock.
            sound: Sound(name: "Waves", layers: [
                Layer(level: -19, shape: SpectralShape(tilt: -7, lowEdge: 80, highEdge: 3_500),
                      motion: Motion(rate: 0.055, randomness: 0.6, swell: 0.93, sweep: 2.5, rise: 0.28), space: Space(width: 0.9), tint: 4),
                Layer(level: -23, shape: SpectralShape(tilt: -8, lowEdge: 30, highEdge: 400),
                      motion: Motion(rate: 0.055, randomness: 0.6, swell: 0.8, rise: 0.45, delay: 0.77), space: Space(width: 0.5), tint: 5),
                Layer(level: -40, shape: SpectralShape(tilt: -2, lowEdge: 1_500, highEdge: 6_000),
                      motion: Motion(rate: 0.055, randomness: 0.6, swell: 1, rise: 0.3, delay: 0.25), space: Space(width: 1), tint: 1),
                Layer(level: -25, shape: SpectralShape(tilt: -7, lowEdge: 120, highEdge: 2_500),
                      motion: Motion(rate: 0.075, randomness: 0.8, swell: 0.9, sweep: 2, rise: 0.3), space: Space(width: 1), tint: 0),
                Layer(level: -27, shape: SpectralShape(tilt: -6, lowEdge: 40, highEdge: 1_200),
                      motion: Motion(rate: 0.03, randomness: 1, swell: 0.3), space: Space(width: 0.6), tint: 2),
            ]),
            note: "A low surge builds, the wave comes in over about 5 seconds and dies away slowly, and a faint fizz drains after it. A smaller wave overlaps at its own pace."
        ),
        Entry(
            sound: Sound(name: "Distant surf", layers: [
                Layer(level: -21, shape: SpectralShape(tilt: -7, lowEdge: 40, highEdge: 700),
                      motion: Motion(rate: 0.05, randomness: 0.7, swell: 0.6, rise: 0.4), space: Space(width: 0.8), tint: 4),
                Layer(level: -23, shape: SpectralShape(tilt: -7, lowEdge: 60, highEdge: 900),
                      motion: Motion(rate: 0.035, randomness: 0.9, swell: 0.55, rise: 0.45), space: Space(width: 1), tint: 0),
                Layer(level: -26, shape: SpectralShape(tilt: -8, lowEdge: 20, highEdge: 300), space: Space(width: 0.5), tint: 2),
            ]),
            note: "Waves from far away: only the lows, no crash. Two slow swells blur into each other over a steady bed."
        ),
        Entry(
            sound: Sound(name: "Propeller plane", layers: [
                Layer(level: -21,
                      shape: SpectralShape(tilt: -5, lowEdge: 40, highEdge: 2_500,
                                           resonance: Resonance(frequency: 95, strength: 16, sharpness: 18)),
                      motion: Motion(rate: 6, randomness: 0.15, swell: 0.1), space: Space(width: 0.5), tint: 3),
                Layer(level: -29,
                      shape: SpectralShape(tilt: -5, lowEdge: 80, highEdge: 2_500,
                                           resonance: Resonance(frequency: 190, strength: 14, sharpness: 18)),
                      space: Space(width: 0.5), tint: 1),
            ]),
            note: "A sharp drone at 95 Hz and its double at 190 Hz, with a fast, shallow flutter."
        ),
        Entry(
            sound: Sound(name: "Space station", layers: [
                Layer(level: -22, shape: SpectralShape(tilt: -4, lowEdge: 60, highEdge: 6_000), space: Space(width: 1), tint: 4),
                Layer(level: -27,
                      shape: SpectralShape(tilt: -5, lowEdge: 40, highEdge: 900,
                                           resonance: Resonance(frequency: 140, strength: 14, sharpness: 20)),
                      space: Space(width: 0.4), tint: 2),
                Layer(level: -40,
                      shape: SpectralShape(tilt: -3, lowEdge: 500, highEdge: 4_000,
                                           resonance: Resonance(frequency: 1_100, strength: 12, sharpness: 25)),
                      space: Space(width: 0.7), tint: 1),
            ]),
            note: "Fans that never stop: a wide wash of air, a pump hum at 140 Hz, and a faint whine at 1.1 kHz."
        ),
        Entry(
            sound: Sound(name: "Air conditioning", layers: [
                Layer(level: -21, shape: SpectralShape(tilt: -4.5, lowEdge: 80, highEdge: 7_000),
                      motion: Motion(rate: 0.05, randomness: 1, swell: 0.06), space: Space(width: 0.9), tint: 0),
                Layer(level: -27,
                      shape: SpectralShape(tilt: -6, lowEdge: 40, highEdge: 600,
                                           resonance: Resonance(frequency: 120, strength: 10, sharpness: 12)),
                      space: Space(width: 0.4), tint: 5),
            ]),
            note: "Steady air through a vent, with a compressor hum at 120 Hz underneath."
        ),
    ]
}
