import AVFoundation
import NoiseKit
import Observation
import SwiftUI

/// Where the room sheet opens.
enum MatchStart: String, Identifiable {
    case listen
    case coverPoint

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    /// The sound being edited and played.
    var sound: Sound {
        didSet {
            guard sound != oldValue else { return }
            push()
            scheduleSave()
        }
    }

    /// Sounds the user has saved by name.
    var saved: [Sound] {
        didSet { scheduleSave() }
    }

    private(set) var isPlaying = false
    private(set) var playError: String?
    /// The layer whose controls are open.
    var expanded: UUID?
    var matchSheet: MatchStart?
    var showSounds = false
    /// When the sleep timer will stop the sound.
    private(set) var sleepEnds: Date?

    /// While the cover point of a room mask is being set by ear, only that layer plays.
    /// `withMargin` says whether its level margin is included yet.
    var tuning: (layer: UUID, withMargin: Bool)? {
        didSet { push() }
    }

    let player = Player()
    let listener = RoomListener()

    private var saveTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?

    init() {
        let library = Library.load()
        sound = library.current
        saved = library.saved
        player.onChange = { [weak self] playing in
            guard let self else { return }
            self.isPlaying = playing
            self.playError = self.player.lastError
            if !playing { self.cancelSleep() }
        }
        push()
    }

    // MARK: Playing

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
            playError = player.lastError
        }
    }

    /// What the synth is asked to play: the whole sound, or just the room mask while it is being tuned.
    private var played: Sound {
        guard let tuning, var layer = sound.layers.first(where: { $0.id == tuning.layer }) else {
            guard Features.scenes else { return Sound(id: sound.id, name: sound.name, layers: sound.layers) }
            return sound
        }
        layer.isOn = true
        if !tuning.withMargin { layer.room?.louderBy = 0 }
        return Sound(id: sound.id, name: sound.name, layers: [layer])
    }

    private func push() {
        player.apply(played)
    }

    // MARK: Layers

    func binding(for id: UUID) -> Binding<Layer> {
        Binding(
            get: { self.sound.layers.first { $0.id == id } ?? Layer() },
            set: { new in
                if let index = self.sound.layers.firstIndex(where: { $0.id == id }) {
                    self.sound.layers[index] = new
                }
            }
        )
    }

    var canAddLayer: Bool { sound.layers.count < Sound.maxLayers }

    private func freeTint() -> Int {
        let used = Set(sound.layers.map(\.tint))
        return (0 ..< Theme.tints.count).first { !used.contains($0) } ?? sound.layers.count % Theme.tints.count
    }

    func addLayer() {
        guard canAddLayer else { return }
        let layer = Layer(tint: freeTint())
        withAnimation(.snappy) {
            sound.layers.append(layer)
            expanded = layer.id
        }
    }

    func duplicate(_ id: UUID) {
        guard canAddLayer, let index = sound.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = sound.layers[index]
        copy.id = UUID()
        copy.tint = freeTint()
        withAnimation(.snappy) {
            sound.layers.insert(copy, at: index + 1)
            expanded = copy.id
        }
    }

    func remove(_ id: UUID) {
        withAnimation(.snappy) {
            sound.layers.removeAll { $0.id == id }
            if expanded == id { expanded = nil }
        }
    }

    func removeScene() {
        withAnimation(.snappy) { sound.scene = nil }
    }

    // MARK: Room mask

    var roomLayer: Layer? { sound.layers.first { $0.room != nil } }

    /// Records the room and puts (or updates) a mask layer for it. Returns false if recording failed.
    func listenToRoom(seconds: Double = 8) async -> Bool {
        let wasPlaying = isPlaying
        cancelSleep()
        await player.stopForRecording()
        guard let profile = await listener.listen(seconds: seconds) else {
            if wasPlaying { player.play() }
            return false
        }

        let id: UUID
        if let index = sound.layers.firstIndex(where: { $0.room != nil }) {
            sound.layers[index].room?.profile = profile
            sound.layers[index].room?.coverIsSet = false
            sound.layers[index].isOn = true
            id = sound.layers[index].id
        } else {
            if !canAddLayer { sound.layers.removeLast() }
            // The phone's own speaker makes almost no sound below about 150 Hz, so there is no point asking it to.
            let onPhoneSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
            let layer = Layer(
                level: -30,
                shape: SpectralShape(tilt: 0, lowEdge: onPhoneSpeaker ? 150 : 50, highEdge: 16_000),
                space: Space(width: 0.8),
                room: RoomMask(profile: profile),
                tint: freeTint()
            )
            sound.layers.insert(layer, at: 0)
            id = layer.id
        }
        tuning = (id, false)
        player.play()
        playError = player.lastError
        return true
    }

    // MARK: Sleep timer

    func sleep(afterMinutes minutes: Int?) {
        cancelSleep()
        guard let minutes else { return }
        if !isPlaying { togglePlay() }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepEnds = end
        sleepTask = Task { [weak self] in
            // The last half minute is a slow fade, so the silence does not arrive as a jolt.
            let fade = 30.0
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow - fade)))
            guard !Task.isCancelled, let self else { return }
            self.player.fadeOut(over: fade)
            try? await Task.sleep(for: .seconds(fade))
            guard !Task.isCancelled else { return }
            self.sleepEnds = nil
            self.sleepTask = nil
            self.player.pause(fade: 0.1)
        }
    }

    private func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEnds = nil
    }

    // MARK: Library

    func load(_ other: Sound, asNew: Bool) {
        var copy = other
        if asNew {
            // A starting point is a recipe: loading it makes a fresh sound of your own.
            copy.id = UUID()
            copy.layers = copy.layers.map { layer in
                var layer = layer
                layer.id = UUID()
                return layer
            }
        }
        tuning = nil
        expanded = nil
        sound = copy
    }

    /// Saves the current sound under its name, replacing the saved copy if there is one.
    func saveCurrent() {
        if let index = saved.firstIndex(where: { $0.id == sound.id }) {
            saved[index] = sound
        } else {
            saved.insert(sound, at: 0)
        }
    }

    var currentIsSaved: Bool { saved.contains { $0 == sound } }

    func deleteSaved(_ id: UUID) {
        saved.removeAll { $0.id == id }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, let self else { return }
            Library(current: self.sound, saved: self.saved).save()
        }
    }
}
