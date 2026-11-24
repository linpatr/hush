import SwiftUI

/// A labelled slider: name on the left, current value on the right, and optional words under each end.
struct ParamSlider: View {
    let title: String
    let value: String
    /// Slider position from 0 to 1.
    @Binding var position: Double
    var low: String?
    var high: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(value: $position)
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(value)
            if low != nil || high != nil {
                HStack {
                    Text(low ?? "")
                    Spacer()
                    Text(high ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, -2)
            }
        }
    }
}

extension Binding where Value == Double {
    /// Maps a value in `range` to a slider position from 0 to 1. `curved` spaces it by ratio (for Hz and rates);
    /// `step` rounds what the slider writes back.
    func position(in range: ClosedRange<Double>, curved: Bool = false, step: Double? = nil) -> Binding<Double> {
        let low = range.lowerBound, high = range.upperBound
        return Binding<Double>(
            get: {
                let v = Swift.min(Swift.max(wrappedValue, low), high)
                return curved ? log(v / low) / log(high / low) : (v - low) / (high - low)
            },
            set: { p in
                var v = curved ? low * pow(high / low, p) : low + (high - low) * p
                if let step { v = (v / step).rounded() * step }
                wrappedValue = Swift.min(Swift.max(v, low), high)
            }
        )
    }
}

/// A short paragraph that says what a group of controls is for.
struct Explanation: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small all-caps heading inside a card.
struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}
