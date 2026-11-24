import NoiseKit
import SwiftUI

/// Name and save the current sound, open a saved one, or open a starting point.
struct SoundsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("This sound") {
                    TextField("Name", text: $model.sound.name)
                        .submitLabel(.done)
                    Button(model.saved.contains { $0.id == model.sound.id } ? "Update the saved copy" : "Save", systemImage: "square.and.arrow.down") {
                        model.saveCurrent()
                    }
                    .disabled(model.currentIsSaved || model.sound.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Theme.card)

                if !model.saved.isEmpty {
                    Section("Your sounds") {
                        ForEach(model.saved) { sound in
                            row(sound, note: Describe.layerCount(sound)) {
                                model.load(sound, asNew: false)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets.sorted(by: >) {
                                model.deleteSaved(model.saved[index].id)
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                }

                if Features.scenes {
                Section {
                    ForEach(StartingPoints.scenes) { entry in
                        row(entry.sound, note: entry.note) {
                            model.load(entry.sound, asNew: true)
                        }
                    }
                } header: {
                    Text("Scenes")
                } footer: {
                    Text("A scene is made of single events, like a wheel crossing a rail joint or a crackle in a fire. Layers of steady noise cannot make those, so a scene has its own sliders. You can still add layers on top of it.")
                }
                .listRowBackground(Theme.card)
                }

                Section {
                    ForEach(StartingPoints.all) { entry in
                        row(entry.sound, note: entry.note) {
                            model.load(entry.sound, asNew: true)
                        }
                    }
                } header: {
                    Text("Starting points")
                } footer: {
                    Text("A starting point is only a set of slider positions. Open one and look through its layers to see how it is put together. Opening a sound replaces the one you are editing, so save that first if you want to keep it.")
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Sounds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ sound: Sound, note: String, open: @escaping () -> Void) -> some View {
        Button {
            open()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Group {
                    if Features.scenes, let scene = sound.scene {
                        Image(systemName: Describe.sceneIcon(scene.kind))
                            .font(.body)
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SpectrumPlot(curves: thumbnail(sound), showsAxes: false)
                    }
                }
                .frame(width: 54, height: 34)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The sound's overall spectrum, small.
    private func thumbnail(_ sound: Sound) -> [PlotCurve] {
        let curves = sound.layers.filter(\.isOn).map { Spectrum.curve(for: $0, motion: 1) }
        guard !curves.isEmpty else { return [] }
        return [PlotCurve(values: Spectrum.sum(curves), color: Theme.accent, lineWidth: 1.5, fill: 0.3)]
    }
}
