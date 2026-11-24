import Accelerate
import Foundation

/// Measures the spectrum of a recording: how much power the room has at each frequency.
///
/// The recording is cut into overlapping frames, each frame is transformed, and the power in every
/// frequency bin is averaged over all frames (Welch's method). The bins are then gathered into
/// sixth-octave bands, because the ear groups frequencies by ratio, not by Hz.
/// Not thread-safe; use from one queue.
public final class RoomAnalyzer {
    public let sampleRate: Double

    private let frame = 8192
    private let fft: RealFFT
    private var window: [Float]
    private var windowPower: Float = 0
    private var waiting: [Float] = []
    private var work: [Float]
    private var real: [Float]
    private var imag: [Float]
    /// Summed power per bin: index 0 is DC, index frame/2 is Nyquist.
    private var sum: [Double]
    private var frames = 0
    private var squares = 0.0
    private var samples = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fft = RealFFT(size: frame)
        window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_DENORM))
        vDSP_svesq(window, 1, &windowPower, vDSP_Length(frame))
        work = [Float](repeating: 0, count: frame)
        real = [Float](repeating: 0, count: frame / 2)
        imag = [Float](repeating: 0, count: frame / 2)
        sum = [Double](repeating: 0, count: frame / 2 + 1)
    }

    /// Seconds of sound taken in so far.
    public var seconds: Double { Double(samples) / sampleRate }

    /// The loudest sample value seen would be 1; this is the overall RMS in dB below that.
    public var level: Double {
        samples > 0 ? 10 * log10(max(squares / Double(samples), 1e-20)) : -200
    }

    public func append(_ buffer: UnsafeBufferPointer<Float>) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        var energy: Float = 0
        vDSP_svesq(base, 1, &energy, vDSP_Length(buffer.count))
        squares += Double(energy)
        samples += buffer.count
        waiting.append(contentsOf: buffer)

        let hop = frame / 2
        var start = 0
        while waiting.count - start >= frame {
            waiting.withUnsafeBufferPointer { analyze($0.baseAddress! + start) }
            start += hop
        }
        if start > 0 { waiting.removeFirst(start) }
    }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    private func analyze(_ input: UnsafePointer<Float>) {
        let count = vDSP_Length(frame)
        // Remove the frame's average first, so a constant offset from the microphone does not leak into the lows.
        var mean: Float = 0
        vDSP_meanv(input, 1, &mean, count)
        var negative = -mean
        work.withUnsafeMutableBufferPointer { w in
            vDSP_vsadd(input, 1, &negative, w.baseAddress!, 1, count)
            vDSP_vmul(w.baseAddress!, 1, window, 1, w.baseAddress!, 1, count)
            fft.forward(w.baseAddress!, &real, &imag)
        }
        let unscale = Double(1 / (fft.forwardScale * fft.forwardScale))
        let half = frame / 2
        sum[0] += Double(real[0] * real[0]) * unscale
        sum[half] += Double(imag[0] * imag[0]) * unscale
        for k in 1 ..< half {
            sum[k] += Double(real[k] * real[k] + imag[k] * imag[k]) * unscale
        }
        frames += 1
    }

    /// Power per Hz in dB for each sixth-octave band, or nil before the first full frame.
    public func bands() -> [Float]? {
        guard frames > 0 else { return nil }
        let half = frame / 2
        let binWidth = sampleRate / Double(frame)
        // One-sided power per Hz in bin k. For white noise of power P this is P / (sampleRate / 2) in every bin.
        let toDensity = 2 / (Double(frame) * Double(windowPower) * Double(frames)) / binWidth
        let edge = pow(2, 0.5 / Double(RoomProfile.bandsPerOctave))

        return RoomProfile.centers.map { center in
            let low = center / edge
            let high = min(center * edge, sampleRate / 2)
            guard high > low else { return -200 }
            // Each bin covers half a bin width to either side of its frequency. Add up the parts inside the band.
            var power = 0.0
            let first = max(0, Int((low / binWidth - 0.5).rounded(.down)))
            let last = min(half, Int((high / binWidth + 0.5).rounded(.up)))
            guard first <= last else { return -200 }
            for k in first ... last {
                let binLow = (Double(k) - 0.5) * binWidth
                let overlap = min(high, binLow + binWidth) - max(low, binLow)
                if overlap > 0 { power += sum[k] * toDensity * overlap }
            }
            return Float(10 * log10(max(power / (high - low), 1e-30)))
        }
    }

    public func profile(simulated: Bool = false, date: Date = Date()) -> RoomProfile? {
        guard let bands = bands() else { return nil }
        return RoomProfile(date: date, seconds: seconds, level: level, bands: bands, simulated: simulated)
    }
}

/// A stand-in room for the Simulator and the tests: a low rumble, a 120 Hz hum, a 2.8 kHz whine and a faint hiss.
public enum TestRoom {
    public static let sound = Sound(name: "Test room", layers: [
        Layer(level: -42, shape: SpectralShape(tilt: -7, lowEdge: 30, highEdge: 1_500), space: Space(width: 0)),
        Layer(level: -50, shape: SpectralShape(tilt: 0, lowEdge: 60, highEdge: 400,
                                       resonance: Resonance(frequency: 120, strength: 30, sharpness: 30)),
              space: Space(width: 0)),
        Layer(level: -56, shape: SpectralShape(tilt: 0, lowEdge: 1_000, highEdge: 8_000,
                                       resonance: Resonance(frequency: 2_800, strength: 26, sharpness: 20)),
              space: Space(width: 0)),
        Layer(level: -62, shape: SpectralShape(tilt: -2, lowEdge: 100, highEdge: 14_000), space: Space(width: 0)),
    ])

    /// Mono samples of the test room.
    public static func samples(sampleRate: Double, seconds: Double) -> [Float] {
        render(sound, sampleRate: sampleRate, seconds: seconds).left
    }

    /// Renders any sound offline. The first second (filters and fades settling) is thrown away.
    public static func render(_ sound: Sound, sampleRate: Double, seconds: Double) -> (left: [Float], right: [Float]) {
        let synth = NoiseSynth(sampleRate: sampleRate)
        synth.applyAndWait(sound)
        synth.setMaster(1, over: 0.01)
        let warmUp = Int(sampleRate)
        let total = Int(seconds * sampleRate) + warmUp
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let step = 512
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < total {
                    let count = min(step, total - done)
                    synth.render(left: l.baseAddress! + done, right: r.baseAddress! + done, frames: count)
                    done += count
                }
            }
        }
        return (Array(left[warmUp...]), Array(right[warmUp...]))
    }
}
