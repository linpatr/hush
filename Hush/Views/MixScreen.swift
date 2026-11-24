import NoiseKit
import SwiftUI

/// The one screen: the sound's spectrum pinned at the top, its layers below, play at the bottom.
struct MixScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 12) {
                if Features.scenes, let scene = model.sound.scene {
                    SceneCard(scene: Binding(get: { model.sound.scene ?? scene }, set: { model.sound.scene = $0 }))
                }
                ForEach(model.sound.layers) { layer in
                    LayerCard(layer: model.binding(for: layer.id))
                }
                addLayer
                matchRoom
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { transport }
        .sheet(item: $model.matchSheet) { MatchRoomSheet(start: $0) }
        .sheet(isPresented: $model.showSounds) { SoundsSheet() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Button {
                    model.showSounds = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(model.sound.name.isEmpty ? "Untitled" : model.sound.name)
                                .font(.title2.bold())
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        Text(Describe.layerCount(model.sound))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your sounds")
                Spacer()
                sleepMenu
            }

            // A scene is events, not a steady noise, so it has no line. The plot is shown once there are layers.
            let sceneOnly = Features.scenes && model.sound.scene != nil && model.sound.layers.isEmpty
            if !sceneOnly {
                SpectrumPlot(curves: curves)
                    .frame(height: 168)
            }
            HStack {
                Text(sceneOnly ? "Add a layer to mix a steady noise under the scene." : "Power at each frequency. One line is 10 dB.")
                Spacer()
                LevelMeter(player: model.player, isPlaying: model.isPlaying)
                    .frame(width: 64, height: 4)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background {
            Theme.background
                .ignoresSafeArea(edges: .top)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
        }
    }

    /// One line per layer, plus the sum of them all when there is more than one.
    private var curves: [PlotCurve] {
        let layers = model.sound.layers.filter(\.isOn)
        var result: [PlotCurve] = []
        var crests: [[Double]] = []
        for layer in layers {
            let crest = Spectrum.curve(for: layer, motion: 1)
            crests.append(crest)
            let moving = layer.motion.swell > 0 || layer.motion.hasSweep || (layer.shape.resonance.isOn && layer.motion.hasDrift)
            let highlighted = model.expanded == nil || model.expanded == layer.id
            result.append(PlotCurve(
                values: crest,
                color: Theme.tint(layer.tint).opacity(highlighted ? 1 : 0.45),
                lineWidth: model.expanded == layer.id ? 2.5 : 1.5,
                other: moving ? Spectrum.curve(for: layer, motion: 0) : nil,
                fill: layers.count == 1 ? 0.22 : 0
            ))
        }
        if layers.count > 1 {
            result.insert(PlotCurve(values: Spectrum.sum(crests), color: .white.opacity(0.9), lineWidth: 2, fill: 0.12), at: 0)
        }
        return result
    }

    private var sleepMenu: some View {
        Menu {
            if model.sleepEnds != nil {
                Button("Turn off timer", systemImage: "xmark") { model.sleep(afterMinutes: nil) }
            }
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                Button(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : minutes == 90 ? "1½ hours" : "2 hours") {
                    model.sleep(afterMinutes: minutes)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.sleepEnds == nil ? "moon" : "moon.fill")
                if let end = model.sleepEnds {
                    Text(timerInterval: Date.now ... max(end, Date.now), countsDown: true)
                        .monospacedDigit()
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .accessibilityLabel("Sleep timer")
    }

    // MARK: List actions

    private var addLayer: some View {
        VStack(spacing: 6) {
            Button {
                model.addLayer()
            } label: {
                Label("Add a layer", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.stroke))
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddLayer)
            .opacity(model.canAddLayer ? 1 : 0.4)
            if !model.canAddLayer {
                Text("A sound holds up to \(Sound.maxLayers) layers.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var matchRoom: some View {
        Button {
            model.matchSheet = .listen
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "ear")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Theme.accent.opacity(0.16), in: Circle())
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.roomLayer == nil ? "Match the room" : "Listen to the room again")
                        .font(.headline)
                    Text("Listen for 8 seconds, then build a noise that covers what is there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    // MARK: Transport

    private var transport: some View {
        VStack(spacing: 6) {
            if let error = model.playError {
                Text("Could not start audio: \(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 76, height: 76)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.accent.opacity(model.isPlaying ? 0.35 : 0.2)).interactive(), in: .circle)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background {
            LinearGradient(
                stops: [.init(color: Theme.background.opacity(0), location: 0), .init(color: Theme.background, location: 0.28)],
                startPoint: .top, endPoint: .bottom
            )
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}

/// A thin bar showing how loud the output is right now, on a 60 dB scale. It turns amber near full scale.
struct LevelMeter: View {
    let player: Player
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !isPlaying)) { _ in
            let level = Double(player.outputLevel)
            let db = level > 0 ? 20 * log10(level) : -100
            let fraction = min(max((db + 60) / 60, 0), 1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(db > -9 ? Color.orange : Theme.accent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
