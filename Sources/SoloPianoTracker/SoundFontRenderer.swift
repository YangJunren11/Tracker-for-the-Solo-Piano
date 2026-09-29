import CTinySoundFont
import Foundation

/// Renders the reference: the score's notes played on a piano SoundFont by TinySoundFont.
///
/// The reference's sound moves how well the follower follows by several points, and TinySoundFont
/// does not implement SoundFont modulators, so give it a SoundFont that needs none: `Piano/piano.sf2`
/// is one, with every modulator worked out in advance (see the README).
public final class SoundFontRenderer {
    public let sampleRate: Double
    private let soundBank: URL
    private let program: Int32
    /// Loading and copying a SoundFont, and letting a copy go, touch what the copies share, so they
    /// happen under this lock; rendering does not, so copies render side by side.
    private static let shared = NSLock()

    public enum Failure: Error, LocalizedError {
        case unreadable(URL)
        case noPreset(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "could not read the SoundFont at \(url.path)"
            case .noPreset(let program): return "the SoundFont has no preset \(program) in bank 0"
            }
        }
    }

    public init(soundBank: URL, program: UInt8 = 0, sampleRate: Double) {
        self.soundBank = soundBank
        self.program = Int32(program)
        self.sampleRate = sampleRate
    }

    public func render(_ notes: [ReferenceNote]) throws -> [Float] {
        var output = [Float]()
        output.reserveCapacity(frames(of: notes))
        try withPlayers(1) { players in
            play(notes, on: players[0]) { output.append(contentsOf: $0) }
        }
        return output
    }

    /// The chroma of every frame of `render(notes)` and the level of each, analysed as it plays.
    public func analyse(_ notes: [ReferenceNote],
                        extractor: ChromaExtractor) throws -> (features: [[Float]], levels: [Float]) {
        try analyse([notes], extractor: extractor)[0]
    }

    /// `analyse` for several references at once, rendered side by side, with `progress` told the
    /// fraction of all their audio done, in order, each time it passes another hundredth.
    public func analyse(_ references: [[ReferenceNote]], extractor: ChromaExtractor,
                        progress: ((Double) -> Void)? = nil) throws -> [(features: [[Float]], levels: [Float])] {
        let counter = progress.map { Progress(total: references.map(frames(of:)).reduce(0, +), report: $0) }
        var results = [(features: [[Float]], levels: [Float])](repeating: ([], []), count: references.count)
        try withPlayers(references.count) { players in
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: references.count) { k in
                    out[k] = analyse(references[k], on: players[k], extractor: extractor, progress: counter)
                }
            }
        }
        return results
    }

    /// Samples done across references rendered side by side.
    private final class Progress {
        private let lock = NSLock()
        private let total: Int
        private let report: (Double) -> Void
        private var done = 0
        private var reported = -1

        init(total: Int, report: @escaping (Double) -> Void) {
            self.total = total
            self.report = report
        }

        func add(_ samples: Int) {
            lock.lock()
            defer { lock.unlock() }
            done += samples
            let hundredths = total > 0 ? min(done * 100 / total, 100) : 100
            guard hundredths > reported else { return }
            reported = hundredths
            report(Double(hundredths) / 100)  // inside the lock, so the fractions arrive in order
        }
    }

    /// A player per reference, each its own copy of the one SoundFont, closed after `body` returns.
    private struct Player {
        let tsf: OpaquePointer
        let preset: Int32
    }

    private func withPlayers(_ count: Int, _ body: ([Player]) throws -> Void) throws {
        Self.shared.lock()
        guard let original = tsf_load_filename(soundBank.path) else {
            Self.shared.unlock()
            throw Failure.unreadable(soundBank)
        }
        let preset = tsf_get_presetindex(original, 0, program)
        guard preset >= 0 else {
            tsf_close(original)
            Self.shared.unlock()
            throw Failure.noPreset(Int(program))
        }
        var players = [Player(tsf: original, preset: preset)]
        while players.count < count, let copy = tsf_copy(original) { players.append(Player(tsf: copy, preset: preset)) }
        for player in players { tsf_set_output(player.tsf, TSF_MONO, Int32(sampleRate), 0) }
        Self.shared.unlock()
        defer {
            Self.shared.lock()
            for player in players.reversed() { tsf_close(player.tsf) }
            Self.shared.unlock()
        }
        guard players.count == count else { throw Failure.unreadable(soundBank) }
        try body(players)
    }

    /// How many samples `render(notes)` makes: to 0.1 s after the last onset.
    private func frames(of notes: [ReferenceNote]) -> Int {
        guard let lastOnset = notes.map(\.onset).max() else { return 0 }
        return Int(((lastOnset + 0.1) * sampleRate).rounded())
    }

    private func analyse(_ notes: [ReferenceNote], on player: Player, extractor: ChromaExtractor,
                         progress: Progress?) -> (features: [[Float]], levels: [Float]) {
        let hop = extractor.hopLength, fft = extractor.fftLength
        var features: [[Float]] = [], levels: [Float] = []
        var pending: [Float] = []  // from where the next frame starts
        play(notes, on: player) { chunk in
            pending.append(contentsOf: chunk)
            var offset = 0
            while pending.count - offset >= fft {
                let frame = pending[offset..<(offset + fft)]
                features.append(extractor.chroma(of: frame))
                var sum: Float = 0
                for sample in frame { sum += sample * sample }
                levels.append((sum / Float(fft)).squareRoot())
                offset += hop
            }
            if offset > 0 { pending.removeFirst(offset) }
            progress?.add(chunk.count)
        }
        return (features, levels)
    }

    /// Plays the notes, handing over the audio a buffer at a time; notes start on their exact sample,
    /// note-offs first at equal times.
    private func play(_ notes: [ReferenceNote], on player: Player, into sink: (UnsafeBufferPointer<Float>) -> Void) {
        guard !notes.isEmpty else { return }
        let totalFrames = frames(of: notes)
        var events: [(Int, Bool, UInt8, UInt8)] = []
        for note in notes {
            let on = Int((note.onset * sampleRate).rounded())
            let off = max(on + 1, Int(((note.onset + note.duration) * sampleRate).rounded()))
            events.append((on, true, note.pitch, note.velocity))
            events.append((off, false, note.pitch, 0))
        }
        events.sort { ($0.0, $0.1 ? 1 : 0) < ($1.0, $1.1 ? 1 : 0) }

        let maxFrames = 1024
        var buffer = [Float](repeating: 0, count: maxFrames)
        var rendered = 0
        var next = 0
        while rendered < totalFrames {
            while next < events.count && events[next].0 <= rendered {
                let (_, isOn, pitch, velocity) = events[next]
                if isOn {
                    tsf_note_on(player.tsf, player.preset, Int32(pitch), Float(velocity) / 127)
                } else {
                    tsf_note_off(player.tsf, player.preset, Int32(pitch))
                }
                next += 1
            }
            var frames = min(maxFrames, totalFrames - rendered)
            if next < events.count { frames = min(frames, max(events[next].0 - rendered, 1)) }
            buffer.withUnsafeMutableBufferPointer { out in
                tsf_render_float(player.tsf, out.baseAddress, Int32(frames), 0)
                sink(UnsafeBufferPointer(rebasing: out[0..<frames]))
            }
            rendered += frames
        }
    }
}
