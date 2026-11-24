import NoiseKit
import SwiftUI

/// One line on the plot.
struct PlotCurve {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.5
    /// A second line; the space between the two is shaded. Used to show how far a moving layer swings.
    var other: [Double]?
    /// How strongly the area under the line is filled, 0 for none.
    var fill: Double = 0
    var dashed = false
}

/// Power against frequency. The x axis runs from 20 Hz to 20 kHz by ratio, so each octave is the same width;
/// the y axis is in dB, one line per 10 dB.
struct SpectrumPlot: View {
    var curves: [PlotCurve]
    var frequencies: [Double] = Spectrum.displayFrequencies
    /// How many dB the plot shows from top to bottom.
    var span: Double = 70
    /// Off for thumbnails: no grid and no labels.
    var showsAxes = true

    private static let marks: [(Double, String)] = [(100, "100"), (1_000, "1k"), (10_000, "10k")]
    private static let minor: [Double] = [50, 200, 500, 2_000, 5_000]

    var body: some View {
        Canvas { context, size in
            let top = self.top
            let plot = CGRect(x: 0, y: 0, width: size.width, height: size.height - (showsAxes ? 16 : 0))

            func x(_ f: Double) -> CGFloat {
                plot.minX + plot.width * CGFloat(log(f / 20) / log(1000))
            }
            func y(_ db: Double) -> CGFloat {
                plot.minY + plot.height * CGFloat(min(max((top - db) / span, -0.05), 1))
            }

            // Grid
            if showsAxes {
            var grid = Path()
            for step in stride(from: 10.0, to: span, by: 10) {
                grid.move(to: CGPoint(x: plot.minX, y: y(top - step)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y(top - step)))
            }
            for f in Self.minor {
                grid.move(to: CGPoint(x: x(f), y: plot.minY))
                grid.addLine(to: CGPoint(x: x(f), y: plot.maxY))
            }
            context.stroke(grid, with: .color(.white.opacity(0.045)), lineWidth: 1)
            var major = Path()
            for (f, _) in Self.marks {
                major.move(to: CGPoint(x: x(f), y: plot.minY))
                major.addLine(to: CGPoint(x: x(f), y: plot.maxY))
            }
            context.stroke(major, with: .color(.white.opacity(0.1)), lineWidth: 1)
            }

            // Curves, clipped to the plot
            context.drawLayer { layer in
                layer.clip(to: Path(plot))
                for curve in curves where curve.values.count == frequencies.count {
                    let points = curve.values.indices.map { CGPoint(x: x(frequencies[$0]), y: y(curve.values[$0])) }
                    var line = Path()
                    line.addLines(points)

                    if let other = curve.other, other.count == frequencies.count {
                        var band = Path()
                        band.addLines(points)
                        for i in other.indices.reversed() {
                            band.addLine(to: CGPoint(x: x(frequencies[i]), y: y(other[i])))
                        }
                        band.closeSubpath()
                        layer.fill(band, with: .color(curve.color.opacity(0.16)))
                        var second = Path()
                        second.addLines(other.indices.map { CGPoint(x: x(frequencies[$0]), y: y(other[$0])) })
                        layer.stroke(second, with: .color(curve.color.opacity(0.35)), lineWidth: 1)
                    }
                    if curve.fill > 0, let first = points.first, let last = points.last {
                        var area = line
                        area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                        area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
                        area.closeSubpath()
                        layer.fill(area, with: .linearGradient(
                            Gradient(colors: [curve.color.opacity(curve.fill), curve.color.opacity(0)]),
                            startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)
                        ))
                    }
                    layer.stroke(
                        line, with: .color(curve.color),
                        style: StrokeStyle(lineWidth: curve.lineWidth, lineCap: .round, lineJoin: .round, dash: curve.dashed ? [4, 4] : [])
                    )
                }
            }

            // Axis labels
            guard showsAxes else { return }
            let label = Font.system(size: 10, weight: .medium, design: .rounded)
            for (f, text) in Self.marks {
                context.draw(
                    Text(text).font(label).foregroundStyle(.white.opacity(0.4)),
                    at: CGPoint(x: x(f), y: size.height - 6), anchor: .center
                )
            }
            context.draw(
                Text("20 Hz").font(label).foregroundStyle(.white.opacity(0.4)),
                at: CGPoint(x: 0, y: size.height - 6), anchor: .leading
            )
            context.draw(
                Text("20k").font(label).foregroundStyle(.white.opacity(0.4)),
                at: CGPoint(x: size.width, y: size.height - 6), anchor: .trailing
            )
        }
        .accessibilityHidden(true)
    }

    /// The top of the plot: just above the highest point, in whole steps of 10 dB so it does not twitch.
    private var top: Double {
        let highest = curves.flatMap { $0.values + ($0.other ?? []) }.max() ?? -40
        return (highest / 10).rounded(.up) * 10 + 5
    }
}
