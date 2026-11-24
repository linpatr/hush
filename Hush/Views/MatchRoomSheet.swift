import NoiseKit
import SwiftUI

/// Listens to the room, then walks through the two steps that turn the measurement into a mask:
/// find the cover point by ear, then add the margins.
struct MatchRoomSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let start: MatchStart

    private enum Stage {
        case intro, listening, cover, margin
    }

    @State private var stage: Stage = .intro
    @State private var task: Task<Void, Never>?

    private var layerID: UUID? { model.roomLayer?.id }
    private let tint = Theme.accent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    plot
                    switch stage {
                    case .intro: intro
                    case .listening: listening
                    case .cover: cover
                    case .margin: margin
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Match the room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(stage == .listening)
        .onAppear {
            if start == .coverPoint, let layerID {
                model.tuning = (layerID, false)
                if !model.isPlaying { model.togglePlay() }
                stage = .cover
            }
        }
        .onDisappear {
            task?.cancel()
            model.tuning = nil
        }
    }

    // MARK: Plot

    private var plot: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpectrumPlot(curves: plotCurves, frequencies: RoomProfile.centers)
                .frame(height: 190)
            HStack(spacing: 14) {
                legend("Room", color: .white.opacity(0.75))
                if stage == .cover || stage == .margin {
                    legend("Mask", color: tint)
                }
                Spacer()
                if model.roomLayer?.room?.profile.simulated == true, stage != .listening {
                    Text("Simulated room")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .card(padding: 14)
    }

    private func legend(_ name: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(name)
        }
    }

    private var plotCurves: [PlotCurve] {
        let room = PlotCurve(values: [], color: .white.opacity(0.75), lineWidth: 1.5, fill: 0.14)
        switch stage {
        case .listening:
            guard let bands = model.listener.liveBands else { return [] }
            return [with(room, bands.map(Double.init))]
        case .intro:
            guard let bands = model.roomLayer?.room?.profile.bands else { return [] }
            return [with(room, bands.map(Double.init))]
        case .cover, .margin:
            guard var layer = model.roomLayer, let profile = layer.room?.profile else { return [] }
            // Before the margin step the mask is drawn sitting on the room; after it, raised by the margin.
            if stage == .cover { layer.room?.louderBy = 0 }
            return [
                with(room, profile.bands.map(Double.init)),
                PlotCurve(values: Spectrum.maskOverRoom(layer), color: tint, lineWidth: 2.2),
            ]
        }
    }

    private func with(_ curve: PlotCurve, _ values: [Double]) -> PlotCurve {
        var curve = curve
        curve.values = values
        return curve
    }

    // MARK: Stages

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hush listens for 8 seconds and measures how much sound the room has at each frequency. Then it builds a noise with the same shape, so the noise is strong exactly where the room is.")
            Text("Keep quiet while it listens. Your noise pauses so the phone does not measure itself. Nothing is saved: the sound is measured and dropped.")
                .foregroundStyle(.secondary)
            failureNote
            Button {
                listen()
            } label: {
                Label("Listen", systemImage: "ear")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .foregroundStyle(Theme.background)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var failureNote: some View {
        switch model.listener.failure {
        case .microphoneDenied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Hush is not allowed to use the microphone.", systemImage: "mic.slash")
                    .foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .noMicrophone:
            Label("No sound is arriving from the microphone.", systemImage: "mic.slash")
                .foregroundStyle(.orange)
        case let .other(message):
            Label("Could not listen: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: model.listener.progress ?? 0)
                .tint(tint)
            Text("Listening. Keep quiet.")
                .font(.headline)
            Text("The plot fills in as the room's sound is averaged.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let layerID {
            let layer = model.binding(for: layerID)
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Find the cover point")
                Text("The mask is playing on its own now. The phone cannot hear how loud the mask is at your ears, so this step is done by ear.")
                    .font(.subheadline)
                Text("Set the phone's volume where you will keep it. Then raise the slider until the room's sound just disappears, and stop there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ParamSlider(
                    title: "Cover point",
                    value: Describe.level(layer.wrappedValue.level),
                    position: layer.level.position(in: Layer.levelRange, step: 1),
                    low: "room still heard", high: "room gone", tint: tint
                )
                .card()
                if layer.wrappedValue.shape.lowEdge >= 100 {
                    Explanation("The mask starts at \(Describe.hz(layer.wrappedValue.shape.lowEdge)), so on the plot it falls away below that. The phone's own speaker makes almost no sound that low, so the mask does not ask it to. With headphones or a larger speaker, lower Low edge under the mask's Shape.")
                }
                Button {
                    layer.wrappedValue.room?.coverIsSet = true
                    model.tuning = (layerID, true)
                    withAnimation(.snappy) { stage = .margin }
                } label: {
                    Text("The room is covered")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(Theme.background)
            }
        }
    }

    @ViewBuilder
    private var margin: some View {
        if let layerID, let room = model.roomLayer?.room {
            let layer = model.binding(for: layerID)
            VStack(alignment: .leading, spacing: 14) {
                step(2, "Add the margins")
                Text("At the cover point the room is only just hidden. Margins keep it hidden when it gets a little louder or changes pitch.")
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 14) {
                    ParamSlider(
                        title: "Louder by",
                        value: "+" + Describe.number(room.louderBy, digits: 0) + " dB",
                        position: Binding(get: { room.louderBy }, set: { layer.wrappedValue.room?.louderBy = $0 })
                            .position(in: RoomMask.louderByRange, step: 1),
                        tint: tint
                    )
                    Explanation("With this margin a steady room sound adds \(Describe.number(Self.added(by: room.louderBy), digits: 1)) dB to what you hear. About 1 dB is the smallest change in loudness an ear can pick out.")
                    ParamSlider(
                        title: "Wider by",
                        value: Describe.octaves(room.widerBy),
                        position: Binding(get: { room.widerBy }, set: { layer.wrappedValue.room?.widerBy = $0 })
                            .position(in: RoomMask.widerByRange, step: 1.0 / 12),
                        tint: tint
                    )
                    Explanation("How far the mask reaches to each side of every sound it measured. On the plot, the peaks grow wider.")
                }
                .card()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(Theme.background)
                Text("Closing this brings your other layers back. The margins stay adjustable under the mask's Shape.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.2), in: Circle())
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.bold())
        }
    }

    /// How many dB a sound adds when it joins a noise that is `margin` dB louder than it.
    /// Powers add: 10·log10(1 + 10^(−margin/10)).
    private static func added(by margin: Double) -> Double {
        10 * log10(1 + pow(10, -margin / 10))
    }

    private func listen() {
        withAnimation(.snappy) { stage = .listening }
        task = Task {
            let ok = await model.listenToRoom()
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { stage = ok ? .cover : .intro }
        }
    }
}
