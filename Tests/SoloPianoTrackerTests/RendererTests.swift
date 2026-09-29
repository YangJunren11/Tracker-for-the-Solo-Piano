import Foundation
import XCTest
@testable import SoloPianoTracker

/// The FFT under the chroma, and the reference piano played by TinySoundFont.
final class RendererTests: XCTestCase {
    /// The FFT agrees with a direct discrete Fourier transform to rounding.
    func testFFTMatchesDirectTransform() {
        let n = 512
        var generator = SystemRandomNumberGenerator()
        let real = (0..<n).map { _ in Double.random(in: -1...1, using: &generator) }
        let imaginary = [Double](repeating: 0, count: n)
        var gotReal = [Double](repeating: 0, count: n), gotImaginary = gotReal
        FFT(count: n).transform(real: real, imaginary: imaginary, outputReal: &gotReal, outputImaginary: &gotImaginary)
        for k in 0..<n {
            var wantReal = 0.0, wantImaginary = 0.0
            for t in 0..<n {
                let angle = -2 * Double.pi * Double(k * t % n) / Double(n)
                wantReal += real[t] * cos(angle)
                wantImaginary += real[t] * sin(angle)
            }
            XCTAssertEqual(gotReal[k], wantReal, accuracy: 1e-9, "bin \(k) real")
            XCTAssertEqual(gotImaginary[k], wantImaginary, accuracy: 1e-9, "bin \(k) imaginary")
        }
    }

    private var piano: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Piano/piano.sf2").standardized
    }

    /// The bundled piano: each note's strongest pitch class is its own.
    func testPianoPlaysTheRightNotes() throws {
        let renderer = SoundFontRenderer(soundBank: piano, sampleRate: 44100)
        let extractor = ChromaExtractor(sampleRate: 44100, hopLength: 1024, fftLength: 2048)
        for pitch in [48, 55, 60, 64, 67, 72, 79, 84] as [UInt8] {
            let notes = [ReferenceNote(onset: 0, duration: 1, pitch: pitch),
                         ReferenceNote(onset: 1, duration: 0.1, pitch: pitch)]
            let audio = try renderer.render(notes)
            XCTAssertEqual(Double(audio.count) / 44100, 1.1, accuracy: 0.01)
            let frame = extractor.chroma(of: audio[Int(0.3 * 44100)..<(Int(0.3 * 44100) + 2048)])
            let strongest = frame.indices.max { frame[$0] < frame[$1] }!
            XCTAssertEqual(strongest, Int(pitch) % 12, "note \(pitch): \(frame)")
        }
    }

    /// Several tempos rendered side by side are exactly what each gives alone, frame for frame, and
    /// analysing as it plays is exactly the chromagram of the whole rendering.
    func testSideBySideMatchesAlone() throws {
        let renderer = SoundFontRenderer(soundBank: piano, sampleRate: 44100)
        let extractor = ChromaExtractor(sampleRate: 44100, hopLength: 1024, fftLength: 2048)
        let notes = Fixture(bars: 4, seed: 5).notes
        let scaled = [2, 1, 0.5, 0.25].map { rate in
            notes.map { ReferenceNote(onset: $0.onset / rate, duration: $0.duration / rate, pitch: $0.pitch) }
        }
        let alone = try scaled.map { try renderer.analyse($0, extractor: extractor) }
        for round in 0..<3 {
            var seen: [Double] = []
            let together = try renderer.analyse(scaled, extractor: extractor) { seen.append($0) }
            for k in scaled.indices {
                XCTAssertEqual(together[k].features, alone[k].features, "round \(round), tempo \(k)")
                XCTAssertEqual(together[k].levels, alone[k].levels, "round \(round), tempo \(k)")
            }
            XCTAssertEqual(seen, seen.sorted())
            XCTAssertEqual(seen.last, 1)
        }
        XCTAssertEqual(alone[1].features, extractor.chromagram(of: try renderer.render(scaled[1])))
    }
}
