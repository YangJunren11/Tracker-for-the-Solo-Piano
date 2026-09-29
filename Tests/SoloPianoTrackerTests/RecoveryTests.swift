import XCTest
@testable import SoloPianoTracker

/// A made-up score: one triad a bar, four beats of half a second each, so a bar lasts two seconds
/// and bar numbers and reference seconds convert by halving.
///
/// Recordings do not isolate the cases recovery has to get right — a similar passage pages away, a
/// restart, the last bars — so these build them. The performance is rendered with a different
/// instrument from the reference and a little noise, so nothing matches exactly by accident.
struct Fixture {
    static let sampleRate = 44100.0
    static let secondsPerBar = 2.0
    static let leadIn = 1.0

    /// One chord per bar: a root (0-11), plus 12 for minor.
    let chords: [Int]

    init(bars: Int, seed: UInt64) {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var chords: [Int] = []
        while chords.count < bars {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let chord = Int((state >> 33) % 24)
            if chord != chords.last { chords.append(chord) }
        }
        self.chords = chords
    }

    static func notes(of chord: Int, at start: Double, beat: Double = 0.5, velocity: UInt8 = 80) -> [ReferenceNote] {
        let root = chord % 12, third = chord >= 12 ? 3 : 4
        var out = [48 + root, 60 + root, 60 + root + third, 67 + root].map {
            ReferenceNote(onset: start, duration: beat, pitch: UInt8($0), velocity: velocity)
        }
        for (i, pitch) in [60 + root + third, 67 + root, 72 + root].enumerated() {
            out.append(ReferenceNote(onset: start + beat * Double(i + 1), duration: beat, pitch: UInt8(pitch),
                                     velocity: velocity))
        }
        return out
    }

    /// The score's notes at its own tempo, and rendered as a reference.
    var notes: [ReferenceNote] {
        chords.enumerated().flatMap { Self.notes(of: $1, at: Double($0) * Self.secondsPerBar) }
    }

    func reference() -> [Float] {
        SynthReference(sampleRate: Self.sampleRate).render(notes)
    }

    var lastOnset: Double { Double(chords.count - 1) * Self.secondsPerBar + 1.5 }
    var barStarts: [Double] { (0...chords.count).map { Double($0) * Self.secondsPerBar } }

    /// What the pianist plays, bar by bar: the score's own bars.
    func play(_ bars: Range<Int>) -> [Performance.Bar] {
        bars.map { .init(chord: chords[$0], truth: $0) }
    }

    /// Wrong notes: the chords of `from`, played while the pianist is really at `at`.
    func wrong(_ from: Range<Int>, at: Int) -> [Performance.Bar] {
        from.enumerated().map { .init(chord: chords[$1], truth: at + $0) }
    }
}

struct Performance {
    struct Bar {
        let chord: Int
        let truth: Int
        var silence = false
    }

    let audio: [Float]
    /// (start time, the bar the pianist is at) per performed bar.
    let segments: [(start: Double, bar: Int)]
    let secondsPerBar: Double

    init(_ bars: [Bar], tempo: Double = 1) {
        secondsPerBar = Fixture.secondsPerBar / tempo
        var notes: [ReferenceNote] = []
        var segments: [(Double, Int)] = []
        var t = Fixture.leadIn
        for bar in bars {
            segments.append((t, bar.truth))
            if !bar.silence { notes += Fixture.notes(of: bar.chord, at: t, beat: 0.5 / tempo, velocity: 90) }
            t += secondsPerBar
        }
        self.segments = segments
        var synth = SynthReference(sampleRate: Fixture.sampleRate)
        synth.harmonics = [1, 0.7, 0.2, 0.35, 0.1]  // another instrument
        synth.decay = 0.9
        var audio = synth.render(notes)
        audio += [Float](repeating: 0, count: Int(Fixture.sampleRate * 2))  // let the last bar finish
        var noise: UInt64 = 12345
        for i in audio.indices {
            noise = noise &* 6364136223846793005 &+ 1442695040888963407
            audio[i] = audio[i] * 0.5 + (Float(noise >> 40) / Float(1 << 24) - 0.5) * 0.004
        }
        self.audio = audio
    }

    static func silence(_ bars: Int, at truth: Int) -> [Bar] {
        (0..<bars).map { _ in Bar(chord: 0, truth: truth, silence: true) }
    }

    /// The bar the pianist is at, fractionally, at time t.
    func truth(at t: Double) -> Double? {
        guard let k = segments.lastIndex(where: { $0.start <= t }) else { return nil }
        return Double(segments[k].bar) + min((t - segments[k].start) / secondsPerBar, 1)
    }

    func time(ofSegment index: Int) -> Double { segments[index].start }
}

/// The settings the README's figures use (see "Using it"). The legacy comparisons turn the
/// immediate whole-piece recovery back on, and the re-anchor's pace gate off.
func trackerOptions() -> FollowerOptions {
    var options = FollowerOptions()
    options.calibrateSeconds = 0
    options.localReanchor = true
    options.localReachSeconds = 1.5
    options.localImprovement = 0.7
    options.localEverySeconds = 2
    return options
}

func trackerFollower(_ reference: [Float], lastOnset: Double, barStarts: [Double], movementStarts: [Double] = [],
                 configure: (inout FollowerOptions) -> Void = { _ in }) -> ScoreFollower {
    var options = trackerOptions()
    configure(&options)
    let extractor = ChromaExtractor(sampleRate: Fixture.sampleRate, hopLength: 1024, fftLength: 2048)
    return ScoreFollower(referenceAudio: reference, lastOnset: lastOnset, extractor: extractor, options: options,
                         movementStarts: movementStarts, barStarts: barStarts, backStep: 1)
}

func follow(_ follower: ScoreFollower, _ audio: [Float],
            tell: [(at: Double, seconds: Double)] = []) -> [ScoreFollower.Position] {
    var positions: [ScoreFollower.Position] = []
    var told = tell
    let hop = follower.extractor.hopLength
    var offset = 0
    while offset + hop <= audio.count, !follower.isFinished {
        if let next = told.first, Double(offset) / Fixture.sampleRate >= next.at {
            follower.begin(atReferenceSeconds: next.seconds)
            told.removeFirst()
        }
        if let position = follower.process(audio[offset..<(offset + hop)]) { positions.append(position) }
        offset += hop
    }
    return positions
}

extension ScoreFollower.Position {
    /// The bar the display shows (two-second bars).
    var shownBar: Double { accepted / Fixture.secondsPerBar }
    var anchorBar: Double { anchor / Fixture.secondsPerBar }
}

final class RecoveryTests: XCTestCase {
    /// The pianist plays four wrong bars that happen to be exactly bars 70-73, fifty bars (three
    /// pages of sixteen) ahead, then carries on from where they were. The old recovery found those
    /// bars clearly better than anywhere else and moved there at once. Now the place is outside the
    /// bounded region, and the search of the whole piece, which may run after a long doubt, has to
    /// go on fitting the playing that follows — which it does not.
    func testSimilarPassagePagesAheadIsNotTaken() {
        let score = Fixture(bars: 80, seed: 1)
        let take = Performance(score.play(0..<20) + score.wrong(70..<74, at: 20) + score.play(24..<44))
        let reference = score.reference()

        let bounded = follow(trackerFollower(reference, lastOnset: score.lastOnset, barStarts: score.barStarts), take.audio)
        XCTAssertLessThan(bounded.map(\.shownBar).max() ?? 0, 50, "the display went to the far passage")
        XCTAssertFalse(bounded.contains { $0.relocation == .structural && $0.shownBar >= 50 })
        let last = bounded.last!
        XCTAssertEqual(last.shownBar, take.truth(at: last.time)!, accuracy: 1.5, "did not get back to the music")

        // The fixture reproduces the failure it is here for
        let legacy = follow(trackerFollower(reference, lastOnset: score.lastOnset, barStarts: score.barStarts) {
            $0.boundedRecovery = false
            $0.localPaceRange = nil
        }, take.audio)
        XCTAssertGreaterThanOrEqual(legacy.map(\.shownBar).max() ?? 0, 60, "the old recovery did not jump: fixture too easy")
    }

    /// Ten bars of playing that belongs nowhere in the score. Search after search finds nothing, and
    /// none of them may move the place the follower trusts: that place is what bounds the next one.
    func testFailedSearchesDoNotMoveTheTrustedPlace() {
        let score = Fixture(bars: 60, seed: 2)
        let stranger = Fixture(bars: 10, seed: 99)
        let lost = stranger.chords.enumerated().map { Performance.Bar(chord: $1, truth: 16 + $0) }
        let take = Performance(score.play(0..<16) + lost + score.play(26..<40))
        let follower = trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts)
        let positions = follow(follower, take.audio)

        XCTAssertGreaterThan(follower.searches, 0, "never lost: fixture too easy")
        var runAnchor: Double?
        for position in positions {
            if position.state == .tracking {
                runAnchor = nil
            } else if let anchor = runAnchor {
                XCTAssertEqual(position.anchor, anchor, "the trusted place moved while lost, at \(position.time) s")
            } else {
                runAnchor = position.anchor
            }
        }
        // Once the playing is back in the score, the follower is too
        let end = positions.last!
        XCTAssertEqual(end.shownBar, take.truth(at: end.time)!, accuracy: 1.5)
    }

    /// Going back six bars to practise a phrase, without saying so.
    func testNearbyRestartIsFound() {
        let score = Fixture(bars: 60, seed: 3)
        let take = Performance(score.play(0..<16) + score.play(10..<32))
        let positions = follow(trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts),
                               take.audio)
        let restart = take.time(ofSegment: 16)
        let found = positions.first { $0.time > restart && abs($0.shownBar - take.truth(at: $0.time)!) <= 1 }
        XCTAssertNotNil(found, "never found the restart")
        XCTAssertLessThan((found?.time ?? .infinity) - restart, 15)
        let end = positions.last!
        XCTAssertEqual(end.shownBar, take.truth(at: end.time)!, accuracy: 1)
    }

    /// Told "I am starting at bar 50" part way through: the new place is trusted at once and the
    /// follower tracks from there, however far it is from where it was.
    func testToldPlaceBecomesTrustedAtOnce() {
        let score = Fixture(bars: 80, seed: 4)
        let take = Performance(score.play(0..<10) + score.play(50..<62))
        let restart = take.time(ofSegment: 10)
        let positions = follow(trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts),
                               take.audio, tell: [(restart, 50 * Fixture.secondsPerBar)])
        let first = positions.first { $0.time >= restart }!
        XCTAssertEqual(first.shownBar, 50, accuracy: 0.1)
        XCTAssertEqual(first.anchorBar, 50, accuracy: 0.1)
        XCTAssertEqual(first.state, .tracking)
        let stopped = take.time(ofSegment: take.segments.count - 1) + take.secondsPerBar
        for position in positions where position.time > restart + 4 && position.time < stopped {
            XCTAssertEqual(position.shownBar, take.truth(at: position.time)!, accuracy: 1)
        }
        XCTAssertFalse(positions.contains { $0.time > restart && $0.relocation == .structural })
    }

    /// Lost in four bars that belong nowhere, the pianist then plays two bars that are exactly bars
    /// 30-31 — ten bars ahead, within reach — before carrying on from bar 26. A search made at that
    /// moment proposes bars 30-31, and the playing that comes after does not fit their continuation,
    /// so the candidate is turned down and the display never goes there.
    func testCandidateThatFailsOnNewPlayingIsTurnedDown() {
        let score = Fixture(bars: 60, seed: 5)
        let stranger = Fixture(bars: 4, seed: 77)
        let lost = stranger.chords.enumerated().map { Performance.Bar(chord: $1, truth: 20 + $0) }
        let take = Performance(score.play(0..<20) + lost + score.wrong(30..<32, at: 24) + score.play(26..<44))
        let follower = trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts)
        let positions = follow(follower, take.audio)
        if ProcessInfo.processInfo.environment["PT_TRACE"] != nil {
            for p in positions where Int(p.time * 10) % 5 == 0 {
                print(String(format: "TRACE t=%.1f shown %.2f truth %.2f state %d conf %.2f anchor %.1f", p.time, p.shownBar,
                             take.truth(at: p.time) ?? -1, p.state.rawValue, p.confidence, p.anchorBar))
            }
        }
        XCTAssertGreaterThan(follower.candidates, 0, "nothing was proposed: fixture too easy")
        XCTAssertGreaterThan(follower.rejections, 0)
        let reached = take.time(ofSegment: 28)  // when the pianist really gets to bar 28
        for position in positions where position.time < reached {
            XCTAssertLessThan(position.shownBar, 28, "showed the candidate at \(position.time) s")
        }
        let end = positions.last!
        XCTAssertEqual(end.shownBar, take.truth(at: end.time)!, accuracy: 1)
    }

    /// Wrong notes that are the last four bars. The old recovery moved there, and following stopped
    /// for good because the last note had been reached. Now it may only end on the accepted path.
    func testFalseCandidateAtTheEndDoesNotFinish() {
        let score = Fixture(bars: 40, seed: 6)
        let take = Performance(score.play(0..<16) + score.wrong(36..<40, at: 16) + score.play(20..<30))
        let follower = trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts)
        let positions = follow(follower, take.audio)
        XCTAssertFalse(follower.isFinished, "stopped following at \(positions.last!.time) s")
        XCTAssertGreaterThan(positions.last!.time, take.time(ofSegment: 28))

        let legacy = trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts) {
            $0.boundedRecovery = false
            $0.localPaceRange = nil
        }
        _ = follow(legacy, take.audio)
        XCTAssertTrue(legacy.isFinished, "the old recovery did not stop: fixture too easy")
    }

    /// A start a few bars from the end, which is legitimate, still finishes.
    func testShortStartNearTheEndFinishes() {
        let score = Fixture(bars: 40, seed: 7)
        let take = Performance(score.play(36..<40))
        let follower = trackerFollower(score.reference(), lastOnset: score.lastOnset, barStarts: score.barStarts)
        _ = follow(follower, take.audio, tell: [(0, 36 * Fixture.secondsPerBar)])
        XCTAssertTrue(follower.isFinished)
    }

    /// A work in two movements, the first with a repeat. The unfolded plan goes forwards through the
    /// repeat, which is backwards on the page, and into the second movement after a pause: both are
    /// legal, and neither may be mistaken for something recovery must stop.
    func testRepeatAndMovementAreFollowed() throws {
        let score = Fixture(bars: 24, seed: 8)
        let bars = (0..<24).map { i -> [String: Any] in
            let number: Int = i < 12 ? i + 1 : i - 11
            let start: Double = Double(i) * 4
            return ["label": String(number), "number": number, "start": start, "duration": 4.0]
        }
        let notes = score.chords.enumerated().flatMap { bar, chord in
            Fixture.notes(of: chord, at: Double(bar) * 4, beat: 1).map {
                ["onset": $0.onset, "duration": $0.duration, "pitch": Int($0.pitch), "bar": bar] as [String: Any]
            }
        }
        let json: [String: Any] = [
            "title": "Fixture", "composer": "", "bars": bars, "notes": notes, "jumps": [[String: Any]](),
            "repeats": [["start": 0, "end": 3, "endings": [[Int]](), "times": 2]],
            "tempos": [[0.0, 120.0]],
            "parts": [["name": "I", "firstBar": 0], ["name": "II", "firstBar": 12]],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let plan = Plan(score: try JSONDecoder().decode(ScoreData.self, from: data), setup: Setup())
        XCTAssertEqual(plan.played.map(\.bar), [0, 1, 2, 3, 0, 1, 2, 3] + Array(4..<24))

        let reference = SynthReference(sampleRate: Fixture.sampleRate).render(plan.referenceNotes)
        let order = plan.played.map(\.bar)
        var performed = order[..<16].enumerated().map { Performance.Bar(chord: score.chords[$1], truth: $0) }
        performed += Performance.silence(2, at: 16)
        performed += order[16...].enumerated().map { Performance.Bar(chord: score.chords[$1], truth: 16 + $0) }
        let take = Performance(performed)
        let follower = trackerFollower(reference, lastOnset: plan.referenceNotes.map(\.onset).max()!,
                                   barStarts: plan.barStarts, movementStarts: plan.movementStarts)
        let positions = follow(follower, take.audio)

        // Into the repeat's second pass rather than back to the first, and on into movement II
        let secondPass = take.time(ofSegment: 7)
        let during = positions.first { $0.time >= secondPass }!
        XCTAssertEqual(during.shownBar, 7, accuracy: 1)
        XCTAssertGreaterThan(positions.last!.shownBar, 26)

        // The region a lost follower may search: across into the next movement's opening bars, and
        // never back into the previous movement
        let atEndOfI = trackerFollower(reference, lastOnset: plan.referenceNotes.map(\.onset).max()!,
                                   barStarts: plan.barStarts, movementStarts: plan.movementStarts)
        atEndOfI.begin(atReferenceSeconds: 15 * Fixture.secondsPerBar)
        let rate = atEndOfI.extractor.frameRate
        let region = atEndOfI.recoveryRange(at: 0)
        XCTAssertGreaterThan(Double(region.upperBound) / rate, 16 * Fixture.secondsPerBar, "cannot reach movement II")
        XCTAssertLessThanOrEqual(Double(region.upperBound) / rate, 24.5 * Fixture.secondsPerBar)
        atEndOfI.begin(atReferenceSeconds: 18 * Fixture.secondsPerBar)
        XCTAssertGreaterThanOrEqual(Double(atEndOfI.recoveryRange(at: 0).lowerBound) / rate,
                                    16 * Fixture.secondsPerBar - 0.05, "reaches back into movement I")
    }
}

final class SearchTests: XCTestCase {
    private func randomFrames(_ count: Int, seed: UInt64) -> [[Float]] {
        var state = seed
        return (0..<count).map { _ in
            (0..<12).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(state >> 40) / Float(1 << 24)
            }
        }
    }

    /// Restricting where the answer may be must not make it look distinctive by leaving nothing to
    /// compare it with: a region too short to hold a rival reports none, and the caller turns that
    /// down rather than taking it.
    func testRegionWithoutRivalsReportsNone() {
        let frames = randomFrames(400, seed: 1)
        let warping = OnlineTimeWarping(reference: frames, frameRate: 43)
        let block = Array(frames[50..<60])
        let narrow = warping.search(recent: block, candidates: 55...62, context: 55...62, keepAway: 20)!
        XCTAssertEqual(narrow.frame, 59)
        XCTAssertNil(narrow.runnerUp)
        let wide = warping.search(recent: block, candidates: 55...62, context: 0...399, keepAway: 20)!
        XCTAssertNotNil(wide.runnerUp)
        XCTAssertLessThan(wide.cost * 1.15, wide.runnerUp!)
    }

    /// Two identical passages: the best place is no better than its rival, so no margin is met.
    func testIdenticalPassagesAreAmbiguous() {
        var frames = randomFrames(400, seed: 2)
        for i in 0..<30 { frames[200 + i] = frames[50 + i] }
        let warping = OnlineTimeWarping(reference: frames, frameRate: 43)
        let found = warping.search(recent: Array(frames[50..<80]), candidates: 0...399, context: 0...399, keepAway: 20)!
        XCTAssertGreaterThanOrEqual(found.cost * 1.15, found.runnerUp!)
    }

    /// A block played at half speed is found at its place when the search allows for it.
    func testHalfSpeedBlockIsFoundWithRates() {
        let frames = randomFrames(400, seed: 3)
        let warping = OnlineTimeWarping(reference: frames, frameRate: 43)
        let slow = (0..<60).map { frames[100 + $0 / 2] }  // each reference frame heard twice
        let plain = warping.search(recent: slow, candidates: 0...399, context: 0...399, keepAway: 20)!
        let tempo = warping.search(recent: slow, candidates: 0...399, context: 0...399, keepAway: 20, rates: [1, 0.5])!
        XCTAssertEqual(tempo.frame, 129, accuracy: 1)
        XCTAssertEqual(tempo.rate, 0.5)
        XCTAssertLessThan(tempo.cost, plain.cost)
    }
}
