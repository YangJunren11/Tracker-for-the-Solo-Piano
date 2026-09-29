import Foundation

/// A complex FFT of a power-of-two length in plain Swift (radix 2), for `ChromaExtractor`. The tests
/// check it against a direct DFT.
struct FFT {
    let count: Int
    private let cosines: [Double]
    private let sines: [Double]
    private let reversed: [Int]

    init(count: Int) {
        precondition(count > 0 && count.nonzeroBitCount == 1, "count must be a power of two")
        self.count = count
        let half = count / 2
        cosines = (0..<half).map { cos(-2 * Double.pi * Double($0) / Double(count)) }
        sines = (0..<half).map { sin(-2 * Double.pi * Double($0) / Double(count)) }
        let bits = count.trailingZeroBitCount
        reversed = (0..<count).map { index in
            var value = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { value |= 1 << (bits - 1 - bit) }
            return value
        }
    }

    /// The forward transform, e^(-2πi nk/N), unscaled, as numpy.fft.fft computes it.
    func transform(real: [Double], imaginary: [Double], outputReal: inout [Double], outputImaginary: inout [Double]) {
        for i in 0..<count {
            outputReal[reversed[i]] = real[i]
            outputImaginary[reversed[i]] = imaginary[i]
        }
        var size = 2
        while size <= count {
            let half = size / 2, stride = count / size
            var start = 0
            while start < count {
                for j in 0..<half {
                    let wr = cosines[j * stride], wi = sines[j * stride]
                    let a = start + j, b = a + half
                    let tr = outputReal[b] * wr - outputImaginary[b] * wi
                    let ti = outputReal[b] * wi + outputImaginary[b] * wr
                    outputReal[b] = outputReal[a] - tr
                    outputImaginary[b] = outputImaginary[a] - ti
                    outputReal[a] += tr
                    outputImaginary[a] += ti
                }
                start += size
            }
            size *= 2
        }
    }
}
