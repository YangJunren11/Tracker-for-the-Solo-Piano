import Foundation

/// Renders the reference without a SoundFont: a few harmonics with a struck-string envelope.
///
/// Far behind a sampled piano as a reference (see the README), and used by the tests, which play
/// the performance on another setting of it so that nothing matches exactly by accident. One
/// waveform is built per pitch and then mixed, rather than synthesising every note sample by sample.
public struct SynthReference {
    public let sampleRate: Double
    /// Relative strengths of the harmonics above each note's pitch.
    public var harmonics: [Float] = [1, 0.5, 0.25, 0.12, 0.06]
    /// Seconds for a note to fall to about a third of its level.
    public var decay: Double = 1.2
    /// Longest a single note sounds.
    public var maximumRing: Double = 2.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public func render(_ notes: [ReferenceNote]) -> [Float] {
        guard let last = notes.map({ $0.onset }).max() else { return [] }
        var output = mix(notes, from: 0, count: Int((last + 0.1) * sampleRate), waveforms: waveforms(for: notes))
        var peak: Float = 0
        for sample in output { peak = max(peak, abs(sample)) }
        if peak > 0 {
            let scale = 1 / peak
            for i in output.indices { output[i] *= scale }
        }
        return output
    }

    /// The chroma of every frame of `render(notes)` and the level of each, rendered and analysed a
    /// few seconds at a time, so the whole rendering never exists at once.
    ///
    /// A reference rendered at a quarter of the tempo is four times as long: for the longest piece
    /// measured, 670 MB of audio held whole against about 10 MB of chroma. Chroma is scaled to each
    /// frame's loudest class and the levels are only ever compared with each other, so the missing
    /// normalisation to the peak changes nothing but rounding.
    public func analyse(_ notes: [ReferenceNote], extractor: ChromaExtractor,
                        chunkSeconds: Double = 20) -> (features: [[Float]], levels: [Float]) {
        guard let last = notes.map({ $0.onset }).max() else { return ([], []) }
        let total = Int((last + 0.1) * sampleRate)
        let hop = extractor.hopLength, fft = extractor.fftLength
        guard total >= fft else { return ([], []) }
        let frameCount = 1 + (total - fft) / hop
        let perChunk = max(Int(chunkSeconds * sampleRate) / hop, 1)
        let shapes = waveforms(for: notes)
        var features: [[Float]] = [], levels: [Float] = []
        features.reserveCapacity(frameCount)
        levels.reserveCapacity(frameCount)
        var first = 0
        while first < frameCount {
            let frames = min(perChunk, frameCount - first)
            let audio = mix(notes, from: first * hop, count: (frames - 1) * hop + fft, waveforms: shapes)
            features += extractor.chromagram(of: audio)
            levels += ScoreFollower.frameLevels(of: audio, fftLength: fft, hopLength: hop)
            first += frames
        }
        return (features, levels)
    }

    /// Samples `start ..< start + count` of every note mixed, unnormalised.
    private func mix(_ notes: [ReferenceNote], from start: Int, count: Int, waveforms: [UInt8: [Float]]) -> [Float] {
        var output = [Float](repeating: 0, count: max(count, 0))
        guard count > 0 else { return output }
        let end = start + count
        for note in notes {
            guard let wave = waveforms[note.pitch] else { continue }
            let onset = Int(note.onset * sampleRate)
            // A note keeps ringing past its written end, as a piano does
            let length = min(Int((note.duration + decay) * sampleRate), wave.count)
            let from = max(onset, start), to = min(onset + length, end)
            guard from < to else { continue }
            let level = Float(note.velocity) / 127
            output.withUnsafeMutableBufferPointer { out in
                wave.withUnsafeBufferPointer { source in
                    let target = out.baseAddress! + (from - start)
                    for i in 0..<(to - from) { target[i] += source[from - onset + i] * level }
                }
            }
        }
        return output
    }

    private func waveforms(for notes: [ReferenceNote]) -> [UInt8: [Float]] {
        let ringSamples = Int(maximumRing * sampleRate)
        var shapes: [UInt8: [Float]] = [:]
        for pitch in Set(notes.map(\.pitch)) {
            shapes[pitch] = waveform(pitch: pitch, count: ringSamples)
        }
        return shapes
    }

    /// One note: harmonics from a shared sine table, faded out by a struck-string envelope.
    private func waveform(pitch: UInt8, count: Int) -> [Float] {
        let tableSize = 4096
        let table = (0..<tableSize).map { Float(sin(2 * Double.pi * Double($0) / Double(tableSize))) }
        let frequency = 440 * pow(2, (Double(pitch) - 69) / 12)
        var wave = [Float](repeating: 0, count: count)
        for (index, strength) in harmonics.enumerated() {
            let partial = frequency * Double(index + 1)
            guard partial < sampleRate / 2 else { break }
            let phaseStep = partial / sampleRate * Double(tableSize)
            var phase = 0.0
            for i in 0..<count {
                wave[i] += strength * table[Int(phase) & (tableSize - 1)]
                phase += phaseStep
            }
        }
        var envelope = [Float](repeating: 0, count: count)
        for i in 0..<count {
            envelope[i] = Float(exp(-Double(i) / (decay * sampleRate)))
        }
        for i in 0..<count { wave[i] *= envelope[i] }
        return wave
    }
}
