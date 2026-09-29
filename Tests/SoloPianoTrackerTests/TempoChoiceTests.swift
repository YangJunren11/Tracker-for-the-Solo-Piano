import XCTest
@testable import SoloPianoTracker

/// Followers at 2, 1, ½ and ¼ of the score's tempo, built as the README builds them: each reference
/// rendered and analysed a piece at a time.
func tempoChoice(_ score: Fixture, rates: [Double] = [2, 1, 0.5, 0.25], openingBars: Double = 6) -> TempoChoice {
    let extractor = ChromaExtractor(sampleRate: Fixture.sampleRate, hopLength: 1024, fftLength: 2048)
    let members = rates.map { rate in
        let notes = score.notes.map {
            ReferenceNote(onset: $0.onset / rate, duration: $0.duration / rate, pitch: $0.pitch, velocity: $0.velocity)
        }
        let reference = SynthReference(sampleRate: Fixture.sampleRate).analyse(notes, extractor: extractor)
        return TempoChoice.Member(rate: rate, follower: ScoreFollower(
            referenceFeatures: reference.features, referenceLevels: reference.levels,
            lastOnset: score.lastOnset / rate, extractor: extractor, options: trackerOptions(),
            barStarts: score.barStarts.map { $0 / rate }, backStep: 1))
    }
    let choice = TempoChoice(members: members, barStarts: score.barStarts)
    choice.openingBars = openingBars
    return choice
}

func follow(_ choice: TempoChoice, _ audio: [Float],
            tell: [(at: Double, seconds: Double)] = []) -> [ScoreFollower.Position] {
    var positions: [ScoreFollower.Position] = []
    var told = tell
    let hop = choice.extractor.hopLength
    var offset = 0
    while offset + hop <= audio.count, !choice.isFinished {
        if let next = told.first, Double(offset) / Fixture.sampleRate >= next.at {
            choice.begin(atReferenceSeconds: next.seconds)
            told.removeFirst()
        }
        if let position = choice.process(audio[offset..<(offset + hop)]) { positions.append(position) }
        offset += hop
    }
    return positions
}

final class TempoChoiceTests: XCTestCase {
    /// The pianist plays at twice, the same as, half and a quarter of the tempo the reference was
    /// rendered at. Each time the member at that tempo is kept, and the display is with the music
    /// from then on. At a quarter speed the 2× member runs out of music long before the choice,
    /// which must not end it.
    func testChoosesTheTempoBeingPlayed() {
        let score = Fixture(bars: 24, seed: 11)
        for (tempo, bars) in [(2.0, 24), (1, 14), (0.5, 10), (0.25, 8)] {
            let take = Performance(score.play(0..<bars), tempo: tempo)
            let choice = tempoChoice(score, openingBars: tempo < 0.3 ? 4 : 6)
            let positions = follow(choice, take.audio)
            XCTAssertEqual(choice.chosen.map { choice.members[$0].rate }, tempo, "at \(tempo)×")
            let after = positions.filter { $0.time >= (choice.chosenAt ?? .infinity) && !$0.silent }
            XCTAssertFalse(after.isEmpty, "at \(tempo)×: never chose")
            for position in after where position.time < take.time(ofSegment: bars - 1) {
                XCTAssertEqual(position.shownBar, take.truth(at: position.time)!, accuracy: 1,
                               "at \(tempo)×, \(position.time) s")
            }
        }
    }

    /// Choosing a member is choosing a tempo, not a place: whatever the member shown before the
    /// choice had come to, the move to the chosen one lands on the music.
    func testChoosingDoesNotJumpAway() {
        let score = Fixture(bars: 24, seed: 12)
        let take = Performance(score.play(0..<10), tempo: 0.5)
        let positions = follow(tempoChoice(score), take.audio)
        for position in positions where position.relocation == .structural {
            XCTAssertEqual(position.shownBar, take.truth(at: position.time)!, accuracy: 1.5)
        }
        XCTAssertLessThan(positions.map(\.shownBar).max()!, 11, "the display ran ahead of the playing")
    }

    /// A restart chooses again: a passage worked on slowly, then the piece from a few bars back
    /// at tempo.
    func testRestartChoosesAgain() {
        let score = Fixture(bars: 30, seed: 13)
        let slow = Performance(score.play(0..<10), tempo: 0.5)
        let fast = Performance(score.play(4..<20))
        let restart = Double(slow.audio.count) / Fixture.sampleRate
        let choice = tempoChoice(score)
        var positions = follow(choice, slow.audio)
        XCTAssertEqual(choice.chosen.map { choice.members[$0].rate }, 0.5)
        positions = follow(choice, fast.audio, tell: [(at: 0, seconds: 4 * Fixture.secondsPerBar)])
        XCTAssertEqual(choice.chosen.map { choice.members[$0].rate }, 1, "kept the first run's tempo")
        let last = positions.last { !$0.silent }!
        XCTAssertEqual(last.shownBar, 4 + fast.truth(at: last.time - restart + restart)! - 4, accuracy: 1.5)
    }

    /// The reference analysed a piece at a time is the reference analysed whole.
    func testAnalysingInPiecesMatchesRenderingWhole() {
        let score = Fixture(bars: 12, seed: 14)
        let extractor = ChromaExtractor(sampleRate: Fixture.sampleRate, hopLength: 1024, fftLength: 2048)
        let synth = SynthReference(sampleRate: Fixture.sampleRate)
        let audio = synth.render(score.notes)
        let whole = extractor.chromagram(of: audio)
        let levels = ScoreFollower.frameLevels(of: audio, fftLength: 2048, hopLength: 1024)
        let pieces = synth.analyse(score.notes, extractor: extractor, chunkSeconds: 1.3)
        XCTAssertEqual(pieces.features.count, whole.count)
        XCTAssertEqual(pieces.levels.count, levels.count)
        for (a, b) in zip(pieces.features, whole) {
            for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-4) }
        }
        // Unnormalised, so the levels differ from the whole rendering's by one factor throughout
        let scale = pieces.levels.max()! / levels.max()!
        for (a, b) in zip(pieces.levels, levels) { XCTAssertEqual(a, b * scale, accuracy: 1e-4 * scale) }
    }
}
