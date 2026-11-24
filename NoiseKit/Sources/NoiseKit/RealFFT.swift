import Accelerate

/// A real FFT of a fixed power-of-two size.
///
/// Spectra use vDSP's packed layout: two arrays of `half` values, where `real[0]` is the DC bin and
/// `imag[0]` is the Nyquist bin (both are real numbers), and bins 1 ..< half are ordinary complex numbers.
final class RealFFT {
    let n: Int
    let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    /// vDSP's forward transform returns the textbook DFT times this.
    private(set) var forwardScale: Float = 1
    /// Forward then inverse returns the input times this.
    private(set) var roundTripScale: Float = 1

    init(size: Int) {
        precondition(size >= 4 && size.nonzeroBitCount == 1, "size must be a power of two")
        n = size
        half = size / 2
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Measure vDSP's scale factors with a unit impulse instead of trusting a remembered constant.
        var time = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        time[0] = 1
        forward(&time, &real, &imag)
        forwardScale = real[1]
        inverse(&real, &imag, &time)
        roundTripScale = time[0]
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// `time` holds n samples; the spectrum is written to `real` and `imag` (half values each).
    func forward(_ time: UnsafePointer<Float>, _ real: UnsafeMutablePointer<Float>, _ imag: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        time.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    /// Transforms the spectrum in place and writes n samples to `time`.
    func inverse(_ real: UnsafeMutablePointer<Float>, _ imag: UnsafeMutablePointer<Float>, _ time: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: real, imagp: imag)
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        time.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
        }
    }

    /// out = a × b for two packed spectra. `out` must not overlap the inputs.
    static func multiply(
        _ aReal: UnsafeMutablePointer<Float>, _ aImag: UnsafeMutablePointer<Float>,
        _ bReal: UnsafeMutablePointer<Float>, _ bImag: UnsafeMutablePointer<Float>,
        _ outReal: UnsafeMutablePointer<Float>, _ outImag: UnsafeMutablePointer<Float>,
        half: Int
    ) {
        // The first slot holds two real numbers (DC and Nyquist), not one complex number.
        let dc = aReal[0] * bReal[0]
        let nyquist = aImag[0] * bImag[0]
        var a = DSPSplitComplex(realp: aReal, imagp: aImag)
        var b = DSPSplitComplex(realp: bReal, imagp: bImag)
        var out = DSPSplitComplex(realp: outReal, imagp: outImag)
        vDSP_zvmul(&a, 1, &b, 1, &out, 1, vDSP_Length(half), 1)
        outReal[0] = dc
        outImag[0] = nyquist
    }
}
