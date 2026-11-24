import NoiseKit
import SwiftUI

/// The four things a layer is described by. Each is one tab of its controls.
enum Principle: String, CaseIterable, Identifiable {
    case texture = "Texture"
    case shape = "Shape"
    case motion = "Motion"
    case space = "Space"

    var id: String { rawValue }
}

struct LayerCard: View {
    @Environment(AppModel.self) private var model
    @Binding var layer: Layer
    @State private var principle: Principle = .shape

    private var isExpanded: Bool { model.expanded == layer.id }
    private var tint: Color { Theme.tint(layer.tint) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ParamSlider(
                title: layer.room == nil ? "Level" : "Cover point",
                value: Describe.level(layer.level),
                position: $layer.level.position(in: Layer.levelRange, step: 1),
                tint: tint
            )
            if isExpanded {
                editor
                    .transition(.opacity)
            }
        }
        .card()
        .opacity(layer.isOn ? 1 : 0.5)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Describe.title(layer))
                        .font(.headline)
                    Text(Describe.subtitle(layer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) {
                    model.expanded = isExpanded ? nil : layer.id
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Hides the controls" : "Shows the controls")

            Button {
                layer.isOn.toggle()
            } label: {
                Image(systemName: layer.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.subheadline)
                    .frame(width: 36, height: 36)
                    .background(Theme.cardRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(layer.isOn ? tint : .secondary)
            .accessibilityLabel(layer.isOn ? "Mute layer" : "Unmute layer")
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Principle", selection: $principle) {
                ForEach(Principle.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch principle {
            case .texture: texture
            case .shape: if layer.room != nil { roomShape } else { shape }
            case .motion: motion
            case .space: space
            }

            Divider().overlay(Theme.stroke)
            HStack {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    model.duplicate(layer.id)
                }
                .disabled(!model.canAddLayer || layer.room != nil)
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive) {
                    model.remove(layer.id)
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }

    private var texture: some View {
        VStack(alignment: .leading, spacing: 16) {
            Explanation("What the noise is made of. A continuous noise takes a new random value for every sample, tens of thousands a second, and sounds like a smooth hiss. With fewer events there is silence between them, and you hear each one as a tick.")
            ParamSlider(
                title: "Density",
                value: Describe.density(layer.texture),
                position: $layer.texture.density.position(in: Texture.densityRange, curved: true),
                low: "single ticks", high: "continuous", tint: tint
            )
            if !layer.texture.isContinuous {
                Explanation("Each tick takes its sound from Shape: a deep shape makes thumps, a thin one makes clicks.")
            }
        }
    }

    private var shape: some View {
        VStack(alignment: .leading, spacing: 16) {
            Explanation("Which frequencies the noise holds. The plot at the top draws it: low frequencies on the left, high on the right, more power higher up.")
            ParamSlider(
                title: "Tilt",
                value: Describe.tilt(layer.shape.tilt),
                position: $layer.shape.tilt.position(in: SpectralShape.tiltRange, step: 0.5),
                low: "deeper", high: "thinner", tint: tint
            )
            Explanation("At 0 every frequency has the same power. At −3 the power halves each time the frequency doubles, so every octave carries the same amount.")
            edges

            SectionLabel("Resonance")
            Explanation("A peak at one frequency. Make it strong and sharp and the noise takes on a pitch: a hum when it is low, a whistle when it is high.")
            ParamSlider(
                title: "Strength",
                value: layer.shape.resonance.isOn ? "+" + Describe.number(layer.shape.resonance.strength, digits: 0) + " dB" : "off",
                position: $layer.shape.resonance.strength.position(in: Resonance.strengthRange, step: 1),
                low: "no peak", high: "nearly a tone", tint: tint
            )
            Group {
                ParamSlider(
                    title: "Frequency",
                    value: Describe.hz(layer.shape.resonance.frequency),
                    position: $layer.shape.resonance.frequency.position(in: Resonance.frequencyRange, curved: true),
                    tint: tint
                )
                ParamSlider(
                    title: "Sharpness",
                    value: Describe.number(layer.shape.resonance.sharpness, digits: 1),
                    position: $layer.shape.resonance.sharpness.position(in: Resonance.sharpnessRange, curved: true),
                    low: "broad", high: "narrow", tint: tint
                )
            }
            .disabled(!layer.shape.resonance.isOn)
            .opacity(layer.shape.resonance.isOn ? 1 : 0.4)
        }
    }

    /// The two band edges. They are kept at least an octave apart.
    private var edges: some View {
        Group {
            ParamSlider(
                title: "Low edge",
                value: Describe.hz(layer.shape.lowEdge),
                position: Binding(
                    get: { layer.shape.lowEdge },
                    set: { layer.shape.lowEdge = min($0, layer.shape.highEdge / 2) }
                ).position(in: SpectralShape.lowEdgeRange, curved: true),
                tint: tint
            )
            ParamSlider(
                title: "High edge",
                value: Describe.hz(layer.shape.highEdge),
                position: Binding(
                    get: { layer.shape.highEdge },
                    set: { layer.shape.highEdge = max($0, layer.shape.lowEdge * 2) }
                ).position(in: SpectralShape.highEdgeRange, curved: true),
                tint: tint
            )
        }
    }

    @ViewBuilder
    private var roomShape: some View {
        if let room = layer.room {
            VStack(alignment: .leading, spacing: 16) {
                Explanation("This layer copies the room: it has power at the frequencies where the room has power. Two margins keep the room covered when it changes a little.")
                ParamSlider(
                    title: "Louder by",
                    value: "+" + Describe.number(room.louderBy, digits: 0) + " dB",
                    position: Binding(get: { room.louderBy }, set: { layer.room?.louderBy = $0 })
                        .position(in: RoomMask.louderByRange, step: 1),
                    tint: tint
                )
                Explanation(room.coverIsSet
                    ? "Added on top of the cover point, the level where the room just disappeared."
                    : "Added on top of the cover point. The cover point has not been set by ear yet, so this margin has nothing sure to stand on.")
                ParamSlider(
                    title: "Wider by",
                    value: Describe.octaves(room.widerBy),
                    position: Binding(get: { room.widerBy }, set: { layer.room?.widerBy = $0 })
                        .position(in: RoomMask.widerByRange, step: 1.0 / 12),
                    tint: tint
                )
                Explanation("How far the mask reaches to each side of every sound it measured.")
                edges

                HStack(spacing: 10) {
                    Button("Listen again", systemImage: "ear") {
                        model.matchSheet = .listen
                    }
                    Button("Set cover point", systemImage: "slider.horizontal.below.rectangle") {
                        model.matchSheet = .coverPoint
                    }
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                Text(measuredNote(room.profile))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func measuredNote(_ profile: RoomProfile) -> String {
        let when = profile.date.formatted(date: .abbreviated, time: .shortened)
        let source = profile.simulated ? "Simulated room (no microphone here), made" : "Measured"
        return "\(source) \(when), over \(Int(profile.seconds.rounded())) s"
    }

    private var motion: some View {
        let moving = layer.motion
        let hasPeak = layer.shape.resonance.isOn && layer.room == nil
        let still = moving.swell == 0 && !moving.hasSweep && !(hasPeak && moving.hasDrift)
        return VStack(alignment: .leading, spacing: 16) {
            Explanation("How the noise changes over time. One slow signal rises to a crest and falls to a trough, again and again. Swell, sweep and drift set what the crest does to the sound.")
            if still {
                Label("Nothing is moving yet. Raise swell, sweep or drift.", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(tint)
            }
            ParamSlider(
                title: "Swell",
                value: Describe.percent(moving.swell),
                position: $layer.motion.swell.position(in: 0 ... 1, step: 0.01),
                low: "steady loudness", high: "fades to silence", tint: tint
            )
            ParamSlider(
                title: "Sweep",
                value: Describe.tilt(moving.sweep),
                position: $layer.motion.sweep.position(in: Motion.sweepRange, step: 0.5),
                low: "deeper at the crest", high: "thinner at the crest", tint: tint
            )
            ParamSlider(
                title: "Drift",
                value: Describe.number(moving.drift, digits: 1, plus: true) + " octaves",
                position: $layer.motion.drift.position(in: Motion.driftRange, step: 0.1),
                low: "peak falls", high: "peak rises", tint: tint
            )
            .disabled(!hasPeak)
            .opacity(hasPeak ? 1 : 0.4)
            if !hasPeak {
                Explanation("Drift moves the resonance, and this layer has none. Give it one under Shape.")
            }

            SectionLabel("Timing")
            ParamSlider(
                title: "Rate",
                value: Describe.rate(moving.rate),
                position: $layer.motion.rate.position(in: Motion.rateRange, curved: true),
                low: "slow", high: "fast", tint: tint
            )
            ParamSlider(
                title: "Pattern",
                value: moving.randomness < 0.03 ? "regular" : moving.randomness > 0.97 ? "random" : Describe.percent(moving.randomness) + " random",
                position: $layer.motion.randomness.position(in: 0 ... 1, step: 0.01),
                low: "repeats exactly", high: "never repeats", tint: tint
            )
            Explanation("With a random pattern every cycle gets its own height and its own length.")
            ParamSlider(
                title: "Rise",
                value: Describe.percent(moving.rise) + " of the cycle",
                position: $layer.motion.rise.position(in: Motion.riseRange, step: 0.01),
                low: "quick rise, slow fall", high: "slow rise, quick fall", tint: tint
            )
            ParamSlider(
                title: "Delay",
                value: Describe.percent(moving.delay) + " of the cycle",
                position: $layer.motion.delay.position(in: 0 ... 1, step: 0.01),
                low: "on time", high: "a full cycle late", tint: tint
            )
            Explanation("Layers with the same rate and pattern move together. Delay sets this layer behind the others, so one part of a sound can follow another.")
        }
    }

    private var space: some View {
        VStack(alignment: .leading, spacing: 16) {
            Explanation("How the noise sits between your ears. At 0% both ears get the same noise, and it seems to come from the middle of your head. At 100% each ear gets its own, and it surrounds you.")
            ParamSlider(
                title: "Width",
                value: Describe.percent(layer.space.width),
                position: $layer.space.width.position(in: 0 ... 1, step: 0.01),
                low: "one point", high: "all around", tint: tint
            )
            Explanation("This needs headphones or two speakers. A single speaker plays both sides from one place.")
        }
    }
}
