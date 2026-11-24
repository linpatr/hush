import Accelerate
import Foundation

/// A filter's spectrum in the packed layout the kernel multiplies by, already scaled for vDSP.
struct PackedFilter {
    var real: [Float]
    var imag: [Float]
}

/// Turns "this much power at each frequency" into a filter the kernel can run.
///
/// The filter is minimum-phase: of all filters with the wanted spectrum, it is the one that responds soonest.
/// For a steady hiss the phase makes no difference. For sparse ticks it does: each tick takes on the filter's
/// own response, and a minimum-phase response starts sharply and then dies away, like a real knock or drop.
/// Not thread-safe; use from one queue.
final class FilterDesigner {
    let sampleRate: Double
    /// The kernel's FFT size.
    let n: Int
    /// How many taps the filter keeps: half the kernel's FFT, so one block plus the filter's tail fits in it.
    let taps: Int
    /// The design runs on a longer FFT so the wanted spectrum is sampled finely.
    private let m: Int
    private let big: RealFFT
    private let small: RealFFT
    private var real: [Float]
    private var imag: [Float]
    private var time: [Float]
    private var scratch: [Float]
    private var phase: [Float]
    private var smallTime: [Float]

    init(sampleRate: Double, kernelSize: Int) {
        self.sampleRate = sampleRate
        n = kernelSize
        taps = kernelSize / 2
        m = kernelSize * 4
        big = RealFFT(size: m)
        small = RealFFT(size: n)
        real = [Float](repeating: 0, count: m / 2)
        imag = [Float](repeating: 0, count: m / 2)
        time = [Float](repeating: 0, count: m)
        scratch = [Float](repeating: 0, count: m / 2)
        phase = [Float](repeating: 0, count: m / 2)
        smallTime = [Float](repeating: 0, count: n)
    }

    /// Designs a filter whose power follows `shape`, scaled so that noise with unit power in gives unit power out
    /// once the resonance (if any) has acted on it.
    func design(shape: ShapeCurve, peak: Peak?) -> PackedFilter {
        let bins = m / 2
        let binWidth = sampleRate / Double(m)

        // 1. The wanted spectrum as the natural log of amplitude, floored 100 dB below its top.
        var top = -Double.infinity
        var db = [Double](repeating: 0, count: bins + 1)
        for k in 1 ... bins {
            db[k] = shape.db(Double(k) * binWidth)
            top = max(top, db[k])
        }
        let floor = top - 100
        db[0] = floor
        let toLog = Float(log(10.0) / 20)
        for k in 0 ..< bins {
            real[k] = Float(max(db[k], floor)) * toLog
            imag[k] = 0
        }
        imag[0] = Float(max(db[bins], floor)) * toLog

        // 2. Its inverse transform is the cepstrum. Folding the cepstrum onto positive time gives the
        //    minimum-phase filter with the same magnitude.
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                time.withUnsafeMutableBufferPointer { t in
                    big.inverse(r.baseAddress!, i.baseAddress!, t.baseAddress!)
                    // inverse() of a textbook spectrum returns the signal times roundTrip / forward.
                    var scale = big.forwardScale / big.roundTripScale
                    vDSP_vsmul(t.baseAddress!, 1, &scale, t.baseAddress!, 1, vDSP_Length(m))
                    var two: Float = 2
                    vDSP_vsmul(t.baseAddress! + 1, 1, &two, t.baseAddress! + 1, 1, vDSP_Length(bins - 1))
                    vDSP_vclr(t.baseAddress! + bins + 1, 1, vDSP_Length(bins - 1))
                    big.forward(t.baseAddress!, r.baseAddress!, i.baseAddress!)
                    var unscale = 1 / big.forwardScale
                    vDSP_vsmul(r.baseAddress!, 1, &unscale, r.baseAddress!, 1, vDSP_Length(bins))
                    vDSP_vsmul(i.baseAddress!, 1, &unscale, i.baseAddress!, 1, vDSP_Length(bins))
                }
            }
        }

        // 3. real + i·imag is now the log of the minimum-phase spectrum: exponentiate it.
        let dc = exp(real[0])
        let nyquist = exp(imag[0])
        var count = Int32(bins)
        phase = imag
        scratch.withUnsafeMutableBufferPointer { amplitude in
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    vvexpf(amplitude.baseAddress!, r.baseAddress!, &count)
                    // r becomes cos(phase), i becomes sin(phase)
                    vvsincosf(i.baseAddress!, r.baseAddress!, phase, &count)
                    vDSP_vmul(r.baseAddress!, 1, amplitude.baseAddress!, 1, r.baseAddress!, 1, vDSP_Length(bins))
                    vDSP_vmul(i.baseAddress!, 1, amplitude.baseAddress!, 1, i.baseAddress!, 1, vDSP_Length(bins))
                }
            }
        }
        real[0] = dc
        imag[0] = nyquist

        // 4. Back to time: the filter's response. Keep the first `taps` samples and fade the last eighth.
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                time.withUnsafeMutableBufferPointer { t in
                    big.inverse(r.baseAddress!, i.baseAddress!, t.baseAddress!)
                }
            }
        }
        let fade = taps / 8
        for j in 0 ..< n {
            if j < taps - fade {
                smallTime[j] = time[j]
            } else if j < taps {
                let x = Float(j - (taps - fade)) / Float(fade)
                smallTime[j] = time[j] * (0.5 + 0.5 * cos(.pi * x))
            } else {
                smallTime[j] = 0
            }
        }

        // 5. The kernel's spectrum of that response.
        let half = n / 2
        var out = PackedFilter(real: [Float](repeating: 0, count: half), imag: [Float](repeating: 0, count: half))
        smallTime.withUnsafeBufferPointer { t in
            out.real.withUnsafeMutableBufferPointer { r in
                out.imag.withUnsafeMutableBufferPointer { i in
                    small.forward(t.baseAddress!, r.baseAddress!, i.baseAddress!)
                }
            }
        }

        // 6. Scale to unit power, counting what the resonance adds. (Any constant scale so far cancels here.)
        let kernelBin = sampleRate / Double(n)
        var power = Double(out.real[0] * out.real[0]) * (peak?.power(0) ?? 1)
        power += Double(out.imag[0] * out.imag[0]) * (peak?.power(sampleRate / 2) ?? 1)
        for k in 1 ..< half {
            let p = Double(out.real[k] * out.real[k] + out.imag[k] * out.imag[k])
            power += 2 * p * (peak?.power(Double(k) * kernelBin) ?? 1)
        }
        // `power` is n × forwardScale² × the filter's true power (Parseval, and vDSP's forward scale).
        let truePower = power / (Double(n) * Double(small.forwardScale * small.forwardScale))
        // The kernel wants the textbook spectrum divided by the round-trip scale, so its inverse needs no scaling.
        var scale = Float(1 / (truePower.squareRoot() * Double(small.forwardScale) * Double(small.roundTripScale)))
        out.real.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, vDSP_Length(half)) }
        out.imag.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, vDSP_Length(half)) }
        return out
    }
}
