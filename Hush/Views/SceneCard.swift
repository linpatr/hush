import NoiseKit
import SwiftUI

/// The controls of a sound's scene: its level, then one slider per thing the scene can vary.
struct SceneCard: View {
    @Environment(AppModel.self) private var model
    @Binding var scene: Soundscape
    @State private var isExpanded = true

    private let tint = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ParamSlider(
                title: "Level",
                value: Describe.level(scene.level),
                position: $scene.level.position(in: Layer.levelRange, step: 1),
                tint: tint
            )
            if isExpanded {
                editor
                    .transition(.opacity)
            }
        }
        .card()
        .opacity(scene.isOn ? 1 : 0.5)
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: Describe.sceneIcon(scene.kind))
                    .font(.subheadline)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Describe.sceneName(scene.kind))
                        .font(.headline)
                    Text("Scene")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) { isExpanded.toggle() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Hides the controls" : "Shows the controls")

            Button {
                scene.isOn.toggle()
            } label: {
                Image(systemName: scene.isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.subheadline)
                    .frame(width: 36, height: 36)
                    .background(Theme.cardRaised, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(scene.isOn ? tint : .secondary)
            .accessibilityLabel(scene.isOn ? "Mute scene" : "Unmute scene")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(scene.controls.enumerated()), id: \.offset) { index, control in
                VStack(alignment: .leading, spacing: 6) {
                    ParamSlider(
                        title: control.name,
                        value: Describe.sceneValue(scene, index),
                        position: Binding(get: { scene.value(index) }, set: { scene.set(index, to: $0) }),
                        low: control.low, high: control.high, tint: tint
                    )
                    Explanation(control.note)
                }
            }
            Explanation("Level sets the loudest moments, not the average. A scene is quiet between its events, so it reads lower on the meter than a steady noise at the same level.")
            Divider().overlay(Theme.stroke)
            HStack {
                Spacer()
                Button("Remove scene", systemImage: "trash", role: .destructive) {
                    model.removeScene()
                }
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }
}
