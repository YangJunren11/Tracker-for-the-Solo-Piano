import Foundation

/// Chroma features: how strongly each of the 12 pitch classes sounds in a frame.
///
/// Matches `librosa.feature.chroma_stft(center=False, norm=inf, tuning=<fixed>)`, which is what
/// Matchmaker's ChromagramProcessor computes, with the tuning fixed instead of re-estimated by
/// librosa on every frame. Frames are `fftLength` samples, Hann-windowed.
public struct ChromaExtractor {
    public static let dimension = 12

    public let sampleRate: Double
    public let hopLength: Int
    public let fftLength: Int
    public let tuning: Double  // deviation from A440 in fractions of a semitone
    /// Frequencies below this are left out of the chroma. A noisy room is mostly rumble — hum,
    /// traffic, machinery — and dropping it costs the piano little, because the chroma weights
    /// octaves around C5 anyway. 0 keeps everything.
    public let lowestHz: Double

    private let window: [Double]
    private let filterBank: [Float]  // dimension x bins, row-major
    private let bins: Int
    private let fft: FFT

    public var frameRate: Double { sampleRate / Double(hopLength) }

    public init(sampleRate: Double, hopLength: Int, fftLength: Int, tuning: Double = 0,
                lowestHz: Double = 0) {
        precondition(fftLength > 0 && fftLength.nonzeroBitCount == 1, "fftLength must be a power of two")
        precondition(fftLength >= hopLength, "fftLength must be at least hopLength")
        self.sampleRate = sampleRate
        self.hopLength = hopLength
        self.fftLength = fftLength
        self.tuning = tuning
        self.lowestHz = lowestHz
        bins = fftLength / 2 + 1
        // Periodic Hann window, as scipy.signal.get_window("hann", n, fftbins=True)
        window = (0..<fftLength).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftLength)) }
        filterBank = Self.filterBank(sampleRate: sampleRate, fftLength: fftLength, tuning: tuning,
                                     lowestHz: lowestHz)
        fft = FFT(count: fftLength)
    }

    /// What one frame of audio looks like.
    public struct Analysis {
        public let chroma: [Float]
        /// How much the frame looks like notes rather than noise: 0 when all twelve pitch classes
        /// sound equally loud, which is what hum and rumble come out as, and approaching 1 for a
        /// single class. Unlike level it does not depend on how loud the room or the mic is.
        public let peakiness: Float
    }

    /// Chroma of one frame; `samples` must hold exactly `fftLength` values.
    public func chroma(of samples: ArraySlice<Float>) -> [Float] {
        analyse(samples).chroma
    }

    /// Chroma of one frame, with the room's own spectrum taken out of it if one is given.
    ///
    /// `noise` is a mean power spectrum (see `RoomNoise`); `times` scales it, above 1 to subtract
    /// more than was measured, which leaves less of the noise but eats into quiet playing.
    public func analyse(_ samples: ArraySlice<Float>, subtracting noise: [Float]? = nil,
                        times factor: Float = 1) -> Analysis {
        precondition(samples.count == fftLength)
        var power = self.power(of: samples)

        if let noise, noise.count == bins, factor > 0 {
            for k in 0..<bins { power[k] = max(0, power[k] - factor * noise[k]) }
        }

        var raw = [Float](repeating: 0, count: Self.dimension)
        for c in 0..<Self.dimension {
            var sum: Float = 0
            for k in 0..<bins { sum += filterBank[c * bins + k] * power[k] }
            raw[c] = sum
        }

        // Normalize by the largest value; frames with no energy are left as they are
        let loudest = Double(raw.map { abs($0) }.max() ?? 0)
        var length = loudest
        if length < Double(Float.leastNormalMagnitude) {
            length = 1
        }
        let chroma = raw.map { Float(Double($0) / length) }
        // An empty frame normalizes to nothing rather than to a peak, so it counts as noise
        let peakiness = loudest < Double(Float.leastNormalMagnitude)
            ? 0 : 1 - chroma.reduce(0, +) / Float(Self.dimension)
        return Analysis(chroma: chroma, peakiness: peakiness)
    }

    /// Power spectrum of one Hann-windowed frame.
    ///
    /// librosa keeps the STFT as complex32, then squares its magnitude in float32.
    private func power(of samples: ArraySlice<Float>) -> [Float] {
        var inputReal = [Double](repeating: 0, count: fftLength)
        var i = 0
        for sample in samples {
            inputReal[i] = Double(sample) * window[i]
            i += 1
        }
        let inputImaginary = [Double](repeating: 0, count: fftLength)
        var outputReal = [Double](repeating: 0, count: fftLength)
        var outputImaginary = [Double](repeating: 0, count: fftLength)
        fft.transform(real: inputReal, imaginary: inputImaginary,
                      outputReal: &outputReal, outputImaginary: &outputImaginary)
        var power = [Float](repeating: 0, count: bins)
        for k in 0..<bins {
            let magnitude = hypotf(Float(outputReal[k]), Float(outputImaginary[k]))
            power[k] = magnitude * magnitude
        }
        return power
    }

    /// Mean power per frequency bin over a whole recording: what the room sounds like.
    public func meanSpectrum(of signal: [Float]) -> [Float] {
        guard signal.count >= fftLength else { return [Float](repeating: 0, count: bins) }
        var total = [Float](repeating: 0, count: bins)
        var frames = 0
        var offset = 0
        while offset + fftLength <= signal.count {
            let power = self.power(of: signal[offset..<(offset + fftLength)])
            for k in 0..<bins { total[k] += power[k] }
            frames += 1
            offset += hopLength
        }
        guard frames > 0 else { return total }
        return total.map { $0 / Float(frames) }
    }

    /// Chroma of every frame of a whole signal, frames starting at multiples of `hopLength`.
    public func chromagram(of signal: [Float]) -> [[Float]] {
        guard signal.count >= fftLength else { return [] }
        let count = 1 + (signal.count - fftLength) / hopLength
        return (0..<count).map { chroma(of: signal[($0 * hopLength)..<($0 * hopLength + fftLength)]) }
    }

    /// librosa.filters.chroma(sr, n_fft, tuning, n_chroma=12, ctroct=5, octwidth=2, norm=2, base_c=True)
    static func filterBank(sampleRate: Double, fftLength n: Int, tuning: Double,
                           lowestHz: Double = 0) -> [Float] {
        let nChroma = Double(dimension)
        let a440 = 440.0 * pow(2.0, tuning / nChroma)
        let step = sampleRate / Double(n)

        var frequencyBins = [Double](repeating: 0, count: n)
        for k in 1..<n {
            frequencyBins[k] = nChroma * log2(Double(k) * step / (a440 / 16))
        }
        // A made-up value for the 0 Hz bin, 1.5 octaves below bin 1
        frequencyBins[0] = frequencyBins[1] - 1.5 * nChroma

        var binWidth = [Double](repeating: 1, count: n)
        for k in 0..<(n - 1) {
            binWidth[k] = max(frequencyBins[k + 1] - frequencyBins[k], 1)
        }

        var weights = [Double](repeating: 0, count: dimension * n)
        for c in 0..<dimension {
            for k in 0..<n {
                // Distance to pitch class c, wrapped into -6..6
                let d = fmod(frequencyBins[k] - Double(c) + 6 + 10 * nChroma, nChroma) - 6
                let x = 2 * d / binWidth[k]
                weights[c * n + k] = exp(-0.5 * x * x)
            }
        }
        for k in 0..<n {
            var sum = 0.0
            for c in 0..<dimension { sum += weights[c * n + k] * weights[c * n + k] }
            var norm = sum.squareRoot()
            if norm < Double.leastNormalMagnitude { norm = 1 }
            let octave = (frequencyBins[k] / nChroma - 5) / 2
            let octaveWeight = exp(-0.5 * octave * octave)
            for c in 0..<dimension {
                weights[c * n + k] = weights[c * n + k] / norm * octaveWeight
            }
        }

        // Start at C instead of A, and keep the non-negative frequencies
        let bins = n / 2 + 1
        // Bins below lowestHz are zeroed here rather than filtered out of the audio: the chroma
        // only ever looks at magnitudes, so dropping the columns is the same thing and costs nothing
        let lowest = Int((lowestHz * Double(n) / sampleRate).rounded(.up))
        var bank = [Float](repeating: 0, count: dimension * bins)
        for c in 0..<dimension {
            let source = (c + 3) % dimension
            for k in 0..<bins {
                bank[c * bins + k] = k < lowest ? 0 : Float(weights[source * n + k])
            }
        }
        return bank
    }
}
