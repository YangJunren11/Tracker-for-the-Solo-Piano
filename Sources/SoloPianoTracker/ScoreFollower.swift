import Foundation

/// How the follower behaves beyond plain online time warping.
public struct FollowerOptions {
    /// Hold the position while nothing is being played, instead of drifting through the reference.
    public var silenceGate = true
    /// Apply the gate only before the first note. Holding the position during quiet passages later on
    /// costs more than it gains, because soft playing then stalls the follower.
    public var gateOnlyBeforeFirstNote = true
    /// Put that gate back on as each movement ends, so the wait before a movement's first note is
    /// treated like the wait before the first note of the piece.
    ///
    /// A work in movements is one score here: the fugue's bar 1 follows the prelude's last bar with
    /// nothing in between, because the gap belongs to the pianist and not to the music. Without
    /// this, the room's own noise pushes the position through the fugue's opening bars while the
    /// pianist is still settling — the very thing the gate exists to prevent, switched off because
    /// the first note of the *piece* is long past.
    public var gateBetweenMovements = true
    /// How near a movement's end the position must come for that gate to be put back on.
    ///
    /// The follower reads a fraction of a second behind the playing, so waiting for the position to
    /// reach the boundary exactly would miss it: a pianist who stops on the last chord leaves the
    /// position just short of it.
    public var movementGateSeconds: Double = 1.5
    /// Search the whole piece for the current position when confidence stays low.
    public var recovery = true
    /// Quieter than this fraction of the recent loudest level counts as not playing (0.005 is about -46 dB).
    /// Soft playing must not be mistaken for silence, so this is deliberately low.
    public var relativeSilence: Float = 0.005
    /// ... and quieter than this absolute level always counts as not playing, which covers the wait before
    /// the first note, when there is no recent level to compare with.
    ///
    /// A noisy room easily sits above any level chosen in advance — the one measured for this project
    /// runs at -33 dB, twenty times this — so pass a `RoomNoise` and the floor is taken from the room
    /// instead of from here.
    public var absoluteSilence: Float = 1e-3
    /// How far above the room's own level counts as playing, when the room has been measured.
    public var floorMargin: Float = 2
    /// Frames in a row above the floor before the follower accepts that the pianist has started.
    /// One frame is a chair, a cough, a door: it should not be enough to let the piece begin.
    public var startFrames = 5
    /// Frames flatter than this across the twelve pitch classes are noise rather than notes, however
    /// loud they are (0 = judge by level alone). Hum and rumble come out near 0.34, playing near 0.74,
    /// and the softest playing stays near 0.73, so this holds where a level threshold cannot.
    ///
    /// Measured against a recording of a noisy room (tools/evaluate_noise.py): the room alone used to
    /// carry the follower to bar 94 in ten seconds, and with this it stays at bar 1 in all seven test
    /// recordings, while accuracy on clean performances goes up rather than down. Anything from 0.62
    /// to 0.7 measured the same; the room's worst frame reaches 0.61 and the quietest playing 0.73.
    public var minPeakiness: Float = 0.62
    /// How much of the measured room spectrum to take out of each frame before the chroma (0 = none).
    public var subtractNoise: Float = 0
    /// Listen to the room for this long before trusting the gate, and raise the gate to clear it.
    ///
    /// No step is asked of the pianist: the seconds between starting the follower and the first note
    /// are a recording of the room by definition, and the follower was not going to move during them
    /// anyway. Measured on a real room, 1.5 s is enough for the estimate to settle (the spread
    /// between windows falls to 0.07 peakiness and 1.2 dB, against 0.15 at half a second). 0 = off.
    public var calibrateSeconds: Double = 2
    /// How far above the room's own worst frames the gate is set.
    public var calibrationMargin: Float = 0.05
    /// ... but never above this. Rooms that need more than this cannot be separated from the piano by
    /// any threshold — a voice reaches 0.78 where playing sits at 0.78 — so the honest answer there is
    /// to say the room is too noisy rather than to gate the playing as well.
    public var maxPeakiness: Float = 0.7
    /// The room is judged from the last this-many seconds of it, so a fan starting up is noticed.
    public var calibrationWindowSeconds: Double = 10
    /// Hold the position through a written rest instead of letting the warping wander through it.
    ///
    /// A rest is the one place where the follower has nothing to align against: the reference is
    /// silent too, so silence matches silence anywhere inside it, and a noisy room supplies a
    /// confident-looking flat chroma to slide along. The score knows where these are.
    public var freezeInRests = true
    /// A reference frame quieter than this fraction of a typical one counts as a rest.
    public var restLevel: Float = 0.01
    /// Inside a rest, frames flatter than this are taken as nothing being played. Stricter than
    /// `minPeakiness`, because freezing while the pianist is in fact playing is expensive: a tenth
    /// of real playing sits below 0.62, so that threshold cannot be reused here.
    public var restPeakiness: Float = 0.5
    /// How long the input must look like nothing before the position is held.
    public var restHoldSeconds: Double = 0.3
    /// When the playing comes back, pick up at the rest's first note rather than where the warping
    /// had reached. The score says what comes after a rest, so there is no need to re-earn it.
    ///
    /// Only when the pianist waited this much longer than the rest is written. Taking a rest a little
    /// longer than written is ordinary playing, and the warping catches that up by itself within a
    /// second; relocating discards the path it has built, which costs more than it saves. Waiting
    /// several seconds is a different thing, and there the held position is stale.
    public var reanchorAfterRest = true
    public var reanchorAfterSeconds: Double = 2
    /// Frames of playing in a row before a hold is released, so that a noisy frame cannot do it.
    ///
    /// Releasing also moves the position to the end of the rest, so it has to be sure. The test is
    /// `minPeakiness` rather than `restPeakiness`: the measured room never once reaches 0.62, while
    /// it crosses 0.5 in bursts of up to three frames — which is exactly how long this used to be.
    public var resumeFrames = 3
    /// How long the "recent loudest level" remembers a peak.
    public var loudnessMemorySeconds: Double = 10
    /// Frames in a row that must be quiet before the gate holds the position.
    public var silenceFrames = 3
    /// Confidence is averaged over this long before being used, because single frames are too noisy.
    public var confidenceSeconds: Double = 1
    /// Recovery uses a longer average, to be sure the follower really is lost.
    public var lostConfidenceSeconds: Double = 2
    /// Seconds of performance kept for a recovery search.
    public var recoverySeconds: Double = 3
    /// Confidence below this counts as lost (0 = matched no better than an average reference frame).
    public var lostBelow: Float = 0.15
    /// A search only moves the position if it is at least this far away, in seconds of reference.
    public var minJumpSeconds: Double = 2
    /// ... and if the position it found matches the recent performance at least this much better than
    /// where the follower currently thinks it is.
    public var improvement: Float = 0.8
    /// How long confidence must stay low before searching.
    public var lostForSeconds: Double = 2
    /// A recovery search answers only if the best position beats the rest by this factor.
    public var searchMargin: Float = 1.15
    /// Positions this close to the current one are not counted as rivals in a search.
    public var searchKeepAwaySeconds: Double = 5
    /// Shortest gap between two recovery searches.
    public var searchEverySeconds: Double = 1
    /// Correct a small error without waiting to be completely lost.
    ///
    /// Recovery answers "where am I in the piece?", and is guarded for it: two seconds of low
    /// confidence, a jump of at least two seconds, and a margin over every rival far away. A
    /// follower that is one bar out satisfies none of those, so nothing corrected it — measured on
    /// eleven recordings, recovery relocated zero times while the position sat still for seconds at
    /// a stretch. This asks the smaller question instead, near where the follower already is, and
    /// is allowed to move it by less than a bar.
    public var localReanchor = false
    /// How much of the recent performance the local search matches. Never more than
    /// `recoverySeconds`, which is what the kept history is sized for.
    public var localSeconds: Double = 2
    /// How far either side of the current position it looks.
    public var localReachSeconds: Double = 4
    /// How often it runs. It costs a few hundred thousand operations, so this is not about the cost
    /// — it is that moving the position discards the path the warping has built.
    public var localEverySeconds: Double = 1
    /// It moves only if the place it found fits the recent playing this much better than where the
    /// follower already is. The test guards itself: when the position is right, the best block near
    /// it is the one it is already on.
    public var localImprovement: Float = 0.9
    /// Run the local re-anchor only while the accepted path has been moving at about the rendered
    /// tempo: this many reference frames per input frame, over the last `localPaceSeconds`. The
    /// re-anchor compares two seconds of playing with two seconds of reference, which is right at
    /// the marked tempo and wrong away from it — at half speed it took the follower from 94% of the
    /// time within a quarter note to 84%. Nil runs it whatever the pace.
    public var localPaceRange: ClosedRange<Double>? = 0.8...1.25
    public var localPaceSeconds: Double = 8
    /// Tempos, in reference frames per input frame, at which recovery and the local re-anchor lay
    /// the recent playing against the reference. [1] compares second for second, which is what
    /// both did before; practice well below the rendered tempo matches a wrong place better than
    /// the right one at 1:1, and a slower rate lets the right one be recognised.
    public var searchRates: [Double] = [1]

    // MARK: Bounded, provisional recovery
    //
    // Recovery used to search the whole piece and move the moment one place fitted the last three
    // seconds better than everywhere else. Across 436 ASAP takes that sent the score more than eight
    // bars from the truth 46 times, 21 of them over a page ahead. Now a place found while lost is
    // only a candidate: it must lie near where the follower last knew it was, and it must go on
    // fitting the playing that comes *after* it was found before anything moves.

    /// Look for a lost place only near the last trusted one, and try a candidate on new playing
    /// before moving to it. False restores the old behaviour: search everywhere, move at once.
    public var boundedRecovery = true
    /// How far back from the trusted place a candidate may lie, in bars: a pianist going back to
    /// practise a passage usually goes back a phrase or two.
    public var recoveryBarsBack: Double = 8
    /// How far ahead, in bars, before counting time: see `recoveryProgressRate`.
    public var recoveryBarsAhead: Double = 8
    /// The music moves on while the follower is lost, so the reach ahead grows by this many
    /// reference seconds for every second since the trusted place. Above 1 allows for playing
    /// faster than the reference; it is what keeps a long doubt from leaving the pianist behind,
    /// and what a jump pages ahead would need, and not get, if it were larger.
    public var recoveryProgressRate: Double = 1.5
    /// Rivals for a candidate are drawn from this far either side of the bounded region as well,
    /// so a narrow region cannot make an answer look distinctive by leaving nothing to compare.
    public var recoveryContextSeconds: Double = 10
    /// A candidate must fit at least this much better than a typical place in that context.
    public var candidateFit: Float = 0.8
    /// How much new playing a candidate is tried against before the position moves there. Longer
    /// is safer and slower: the display waits this long after the follower has found its place.
    public var confirmSeconds: Double = 1.5
    /// The candidate's path must fit that new playing this much better than the accepted path does.
    public var confirmImprovement: Float = 0.9
    /// ... and match at least this well on its own terms (the confidence measure, averaged).
    public var confirmConfidence: Float = 0.1
    /// ... and have moved at a believable pace, in reference frames per input frame: a path that
    /// stands still or races is matching something other than the music being played.
    public var confirmMinRate: Double = 0.15
    public var confirmMaxRate: Double = 2.8
    /// ... and, for a candidate further away than `recoveryBarsAhead`, a second search made with
    /// only the playing heard during the trial must find the candidate's path again, clear of every
    /// rival by `agreeMargin`. Asked of every candidate it turned down two in three good ones as
    /// well, which left a follower that had fallen behind stuck there; asked of the far ones only,
    /// it is the price of a longer move. True asks it of near candidates too.
    public var confirmBySearch = false
    public var agreeMargin: Float = 1
    /// When nothing is found near the trusted place, look this many bars ahead of it (plus the
    /// progress allowance), for a follower that has fallen behind a pianist playing much faster than
    /// the reference. Such a candidate must beat its rivals by `catchUpMargin` and survive a trial of
    /// `catchUpConfirmSeconds` that includes the second search. 0 turns it off. Five seconds rather
    /// than three: the one catch-up measured to land wrong (22 bars ahead, in 100 takes) was
    /// confirmed on three and not on five, at no cost anywhere else.
    public var catchUpBarsAhead: Double = 32
    public var catchUpMargin: Float = 1.3
    public var catchUpConfirmSeconds: Double = 5
    /// A catch-up search that finds a place without the margin still leaves a hit. Two hits from
    /// blocks that share no playing, `recoverySeconds` or more apart and on one path at a believable
    /// pace, make a candidate as well: in a piece whose three-second blocks all sound somewhat alike
    /// no single search wins clearly, but wrong places scatter while the right one keeps moving on.
    /// Hits are forgotten after this long.
    public var catchUpMemorySeconds: Double = 12
    /// The accepted place becomes trusted after this long following with at least this confidence,
    /// without a relocation. Only a trusted place bounds recovery, so a wrong match that looks
    /// confident for a moment cannot drag the region after it.
    public var trustSeconds: Double = 2
    public var trustConfidence: Float = 0.3
    /// After this long lost with nothing found nearby, search the whole piece as well — but a place
    /// found far away has to beat its rivals by `distantMargin` and survive `distantConfirmSeconds`
    /// of new playing, the second search included. It is what finds a pianist who went back several
    /// pages without saying so (found in 72 of 100 practice takes, against 65 without it), and it
    /// cost nothing measurable on ordinary run-throughs. Being told is still far better: 100 of 100.
    public var distantRecovery = true
    public var distantAfterSeconds: Double = 5
    public var distantMargin: Float = 1.3
    public var distantConfirmSeconds: Double = 4
    /// Following ends only after the accepted position has stood at the last note this long while
    /// tracking, so a stray correction to the end cannot stop it for good.
    public var finishHoldSeconds: Double = 0.25
    /// Report, as the position to show, the one from before the doubt began for as long as the
    /// follower is unsure, instead of the accepted path as it goes on.
    ///
    /// False by default, because it measured worse on every count. The accepted path cannot jump —
    /// only a confirmed candidate moves it — so following it while unsure shows the music at worst
    /// a little off; holding shows it further and further off, and then jumps when the doubt ends,
    /// which is the very thing a pianist notices. On 100 takes holding lost 0.2 points of time on
    /// screen, and on blind restarts it made five times as many wrong jumps of the display.
    public var holdWhileUncertain = false

    public init() {}
}

/// What a short recording of the room, with nobody playing, says about it.
///
/// Both numbers are needed: the level sets a floor the gate can trust, and the spectrum can be taken
/// out of each frame so that what is left looks more like the piano and less like the room.
public struct RoomNoise {
    /// RMS level of the recording.
    public let level: Float
    /// Mean power per frequency bin.
    public let spectrum: [Float]
    /// How note-like the room's own worst frames look (99th percentile), which is what the gate has
    /// to clear. Hum measures about 0.60; a room with voices or music in it measures far higher, and
    /// no threshold then separates it from the piano.
    public let peakiness: Float

    public init(recording: [Float], extractor: ChromaExtractor) {
        var sum: Float = 0
        for sample in recording { sum += sample * sample }
        level = recording.isEmpty ? 0 : (sum / Float(recording.count)).squareRoot()
        spectrum = extractor.meanSpectrum(of: recording)
        var values: [Float] = []
        var offset = 0
        while offset + extractor.fftLength <= recording.count {
            values.append(extractor.analyse(recording[offset..<(offset + extractor.fftLength)]).peakiness)
            offset += extractor.hopLength
        }
        peakiness = Self.highWaterMark(of: values)
    }

    public init(level: Float, spectrum: [Float], peakiness: Float = 0) {
        self.level = level
        self.spectrum = spectrum
        self.peakiness = peakiness
    }

    /// 99th percentile: the worst the room does, without letting one frame speak for it.
    static func highWaterMark(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(Int(Double(sorted.count) * 0.99), sorted.count - 1)]
    }
}

/// What listening to the room came to, to show and for the gate to use.
public struct RoomCalibration {
    /// Seconds of room heard so far.
    public let seconds: Double
    /// RMS level of the room.
    public let level: Float
    /// How note-like its worst frames look (99th percentile).
    public let peakiness: Float
    /// The gate this produced.
    public let gate: Float
    /// The room needs a gate that would swallow the playing too, so following it will be unreliable.
    public let tooNoisy: Bool
}

/// Where the follower stands with the music, for the display to decide whether to act on it.
public enum FollowState: Int {
    /// Following normally: positions can be shown as they come.
    case tracking = 0
    /// The match has been poor for a while. The follower keeps listening and looks for its place
    /// near the last one it trusted; the display should stay where it is.
    case uncertain = 1
    /// A place has been found and is being tried against the playing that comes after it, before
    /// anything is moved there.
    case confirming = 2
}

/// How the position was moved on a frame, other than by following.
public enum Relocation: Int {
    case none = 0
    /// A correction of a second or two: the local re-anchor, or picking up after a rest.
    case local = 1
    /// The follower was lost and has found its place somewhere else: the display should go
    /// straight there, and page turns between the old place and the new one are no longer due.
    case structural = 2
}

/// Follows a live performance against a reference rendering of the score.
///
/// Feed audio in chunks of exactly `hopLength` samples (use `HopChunker` for arbitrary buffers).
/// Mirrors Matchmaker's AudioStream: each analysis frame is the previous `fftLength - hopLength`
/// samples plus the new chunk, and the very first chunk only primes that history.
public final class ScoreFollower {
    public struct Position {
        /// Seconds into the performance.
        public let time: Double
        /// Seconds into the reference rendering (map to bars with `ReferenceTimeline`): where the
        /// accepted path is, which is where the warping stands even while its match is doubtful.
        public let reference: Double
        public let referenceFrame: Int
        public let features: [Float]
        /// How much better the matched reference frame is than an average one: 1 is perfect, 0 is no better.
        public let confidence: Float
        /// True while the gate judges that nothing is being played.
        public let silent: Bool
        /// RMS level of the frame, and how much it looks like notes rather than noise. Both are what
        /// the gate judged on, and both are worth showing a pianist whose room is too loud to follow.
        public let level: Float
        public let peakiness: Float
        /// How the position was moved on this frame, if it was.
        public let relocation: Relocation
        /// Tracking, or looking for its place; see `FollowState`.
        public let state: FollowState
        /// Reference seconds of the last place the follower trusted, which bounds where it looks
        /// when it is lost.
        public let anchor: Double
        /// Distance between this frame and the reference frame it was matched to (0 on held frames):
        /// raw, unlike `confidence`, so followers of different references can be compared on it.
        public let cost: Float
        /// Reference seconds the display should show: the accepted path, which only a confirmed
        /// relocation can move by more than the warping's own steps (or, with `holdWhileUncertain`,
        /// the last place shown before the doubt began).
        public let accepted: Double
        /// The tempo of the reference this position was followed on, over the score's own: 1 for a
        /// single follower, a `TempoChoice` member's rate otherwise.
        public internal(set) var tempo: Double = 1
        /// True while a `TempoChoice` is still deciding which tempo to keep.
        public internal(set) var choosingTempo = false

        /// True on the frame where the position was moved rather than followed.
        public var relocated: Bool { relocation != .none }
    }

    public let extractor: ChromaExtractor
    /// The accepted path. Replaced by the candidate's path when a relocation is confirmed, so the
    /// path the candidate built while it was being tried is kept rather than thrown away.
    public private(set) var warping: OnlineTimeWarping
    public var options: FollowerOptions
    /// Reference time of the last note onset; following stops once it is reached.
    public let lastOnset: Double
    public private(set) var isFinished = false
    public private(set) var searches = 0
    public private(set) var relocations = 0
    /// Small corrections made near the current position, which recovery is not allowed to make.
    public private(set) var localMoves = 0
    /// Frames held inside a rest, and times the position was picked up again at a rest's first note.
    public private(set) var frozenFrames = 0
    public private(set) var reanchors = 0
    /// Candidates put on trial while lost, and how many of them were turned down on the playing
    /// that followed. Relocations counts the ones that were confirmed.
    public private(set) var candidates = 0
    public private(set) var rejections = 0
    public private(set) var state: FollowState = .tracking

    /// What the room sounds like with nobody playing, if a recording of it was supplied.
    public var room: RoomNoise?
    /// What listening to the room during the wait before the first note came to.
    public private(set) var calibration: RoomCalibration?

    private var history: [Float]?
    private var emitted = 0
    private var loudest: Float = 0
    private var quietRun = 0
    private var playingRun = 0
    private var playing = false
    private var roomPeakinessHeard: [Float] = []
    private var roomLevelsHeard: [Float] = []
    private var sinceCalibrated = 0
    private var restRun = 0
    private var playingAgainRun = 0
    private var holding = false
    /// When the hold began, and how much of the rest was still to come at that moment.
    private var holdingSince: Double?
    private var restLeftAtHold: Double = 0
    /// Level of each reference frame, and what a sounding one is like, for finding the rests.
    private let referenceLevels: [Float]
    private let typicalReferenceLevel: Float
    /// Where each movement after the first begins, in reference frames.
    private let movementFrames: [Int]
    private var recent: [[Float]] = []
    private var confidences: [Float] = []
    private var lowConfidenceSince: Double?
    private var lastSearch = -Double.infinity
    private var lastLocal = -Double.infinity
    private var lastConfidence: Float = 0

    /// Where each played bar starts, in reference frames, with the end of the last one after it:
    /// how recovery counts bars without knowing anything about pages. Empty when not given.
    private let barFrames: [Double]
    /// The last place followed with confidence, and when. Recovery looks near here.
    private var anchorFrame = 0
    private var anchorTime = 0.0
    /// The position the display was last told to show, held while the follower is not tracking.
    private var acceptedFrame = 0
    /// When the position was last moved by a confirmed relocation or a restart; trust has to be
    /// earned again after either.
    private var settledSince = 0.0
    /// The place on trial while confirming, on a path of its own.
    private var probe: OnlineTimeWarping?
    private var trial = Trial()
    /// Frames heard since becoming uncertain; a search needs a block of them that no earlier
    /// search has already judged, so one stretch of playing is never counted twice.
    private var freshFrames = 0
    private var uncertainSince: Double?
    private var finishRun = 0
    /// Catch-up hits that did not clear the margin on their own: (time, reference frame).
    private var aheadHits: [(time: Double, frame: Int)] = []
    /// The accepted path's frame at each frame followed, for its pace; cleared whenever it is moved.
    private var paceHistory: [Int] = []

    /// What a candidate has shown so far, measured on the playing since it was proposed.
    private struct Trial {
        var start = 0
        var frames = 0
        var needed = 0
        var candidateCost: Float = 0
        var acceptedCost: Float = 0
        var confidence: Float = 0
        /// Found by the search of the whole piece rather than near the trusted place.
        var distant = false
        /// Far enough away that the second search is asked of it whatever `confirmBySearch` says.
        var strict = false
    }

    /// `movementStarts` is where each movement after the first begins, in reference seconds —
    /// `Plan.movementStarts`. Empty for a piece all in one movement, which is most of them.
    /// `barStarts` is where each played bar starts, in reference seconds, with the end of the last
    /// one after it — `Plan.barStarts` — so recovery can be bounded in bars. Without it bars are
    /// taken to last two seconds.
    public convenience init(referenceAudio: [Float], lastOnset: Double, extractor: ChromaExtractor,
                            options: FollowerOptions = FollowerOptions(), room: RoomNoise? = nil,
                            movementStarts: [Double] = [], barStarts: [Double] = [],
                            windowSeconds: Double = 10, startWindowSeconds: Double = 0.1, stepSize: Int = 3,
                            backStep: Int = 0) {
        self.init(referenceFeatures: extractor.chromagram(of: referenceAudio),
                  referenceLevels: Self.frameLevels(of: referenceAudio, fftLength: extractor.fftLength,
                                                    hopLength: extractor.hopLength),
                  lastOnset: lastOnset, extractor: extractor, options: options, room: room,
                  movementStarts: movementStarts, barStarts: barStarts, windowSeconds: windowSeconds,
                  startWindowSeconds: startWindowSeconds, stepSize: stepSize, backStep: backStep)
    }

    /// From a reference already analysed: its chroma frames and the level of each frame. What
    /// `stretched(_:levels:by:)` produces, to follow at another tempo without rendering again.
    public init(referenceFeatures: [[Float]], referenceLevels: [Float], lastOnset: Double,
                extractor: ChromaExtractor, options: FollowerOptions = FollowerOptions(), room: RoomNoise? = nil,
                movementStarts: [Double] = [], barStarts: [Double] = [],
                windowSeconds: Double = 10, startWindowSeconds: Double = 0.1, stepSize: Int = 3,
                backStep: Int = 0) {
        self.extractor = extractor
        self.lastOnset = lastOnset
        self.options = options
        self.room = room
        movementFrames = movementStarts.map { Int(($0 * extractor.frameRate).rounded()) }.sorted()
        barFrames = barStarts.map { $0 * extractor.frameRate }
        self.referenceLevels = referenceLevels
        // A typical sounding frame: the median of the louder half, which a few silent bars cannot move
        let sorted = referenceLevels.sorted()
        typicalReferenceLevel = sorted.isEmpty ? 0 : sorted[sorted.count * 3 / 4]
        warping = OnlineTimeWarping(
            reference: referenceFeatures, frameRate: extractor.frameRate,
            windowSeconds: windowSeconds, startWindowSeconds: startWindowSeconds, stepSize: stepSize,
            backStep: backStep)
    }

    /// A reference's features as they would be at another tempo, by interpolating between frames:
    /// `factor` 2 makes it twice as long, as if rendered at half the tempo. An approximation — a
    /// note rendered slower decays further between onsets, which this does not reproduce — but one
    /// that costs no rendering at all.
    public static func stretched(_ features: [[Float]], levels: [Float], by factor: Double) -> ([[Float]], [Float]) {
        guard factor > 0, features.count > 1 else { return (features, levels) }
        let count = max(Int((Double(features.count) * factor).rounded()), 1)
        var outFeatures: [[Float]] = []
        var outLevels: [Float] = []
        outFeatures.reserveCapacity(count)
        outLevels.reserveCapacity(count)
        for j in 0..<count {
            let x = min(Double(j) / factor, Double(features.count - 1))
            let k = min(Int(x), features.count - 2)
            let w = Float(x - Double(k))
            var frame = (0..<features[k].count).map { features[k][$0] * (1 - w) + features[k + 1][$0] * w }
            let peak = frame.max() ?? 0
            if peak > 0 { frame = frame.map { $0 / peak } }  // chroma is normalised to its loudest class
            outFeatures.append(frame)
            let lk = min(k, levels.count - 1), lk1 = min(k + 1, levels.count - 1)
            outLevels.append(levels.isEmpty ? 0 : levels[lk] * (1 - w) + levels[lk1] * w)
        }
        return (outFeatures, outLevels)
    }

    /// Start following from a known place, e.g. the bar the pianist says they are starting at.
    ///
    /// Far more reliable than letting the follower search for itself, and the search stays available
    /// for when the pianist then wanders off.
    ///
    /// Being told is better evidence than anything the follower could find, so it becomes the
    /// trusted place at once, and whatever recovery was doing is dropped.
    public func begin(atReferenceSeconds seconds: Double) {
        warping.relocate(to: Int((seconds * extractor.frameRate).rounded()))
        let now = Double(emitted) * Double(extractor.hopLength) / extractor.sampleRate
        state = .tracking
        trial = Trial()
        anchorFrame = warping.currentFrame
        anchorTime = now
        acceptedFrame = warping.currentFrame
        settledSince = now
        freshFrames = 0
        uncertainSince = nil
        finishRun = 0
        aheadHits.removeAll()
        paceHistory.removeAll()
        playing = false
        playingRun = 0
        quietRun = 0
        restRun = 0
        playingAgainRun = 0
        holding = false
        holdingSince = nil
        roomPeakinessHeard.removeAll()
        roomLevelsHeard.removeAll()
        calibration = nil
        recent.removeAll()
        confidences.removeAll()
        lowConfidenceSince = nil
        lastSearch = -.infinity
        lastLocal = -.infinity
        lastConfidence = 0
        isFinished = false
    }

    /// Process the next `hopLength` samples. Returns nil for the first chunk, which only fills the frame
    /// history, and once the performance has reached the last note.
    public func process(_ chunk: ArraySlice<Float>) -> Position? {
        precondition(chunk.count == extractor.hopLength)
        guard !isFinished else { return nil }
        let historyLength = extractor.fftLength - extractor.hopLength
        let frame = (history ?? [Float](repeating: 0, count: historyLength)) + chunk
        let primed = history != nil
        history = Array(frame.suffix(historyLength))
        guard primed else { return nil }

        let time = Double(emitted) * Double(extractor.hopLength) / extractor.sampleRate
        emitted += 1

        var level: Float = 0
        for sample in frame { level += sample * sample }
        level = (level / Float(frame.count)).squareRoot()
        let decay = Float(exp(-1.0 / (options.loudnessMemorySeconds * extractor.frameRate)))
        loudest = max(level, loudest * decay)

        let analysis = extractor.analyse(frame[...], subtracting: room?.spectrum,
                                         times: options.subtractNoise)
        let features = analysis.chroma
        func held(silent: Bool) -> Position {
            if state == .tracking || !options.holdWhileUncertain { acceptedFrame = warping.currentFrame }
            return Position(time: time, reference: referenceSeconds(warping.currentFrame),
                            referenceFrame: warping.currentFrame, features: features,
                            confidence: lastConfidence, silent: silent, level: level,
                            peakiness: analysis.peakiness, relocation: .none, state: state,
                            anchor: referenceSeconds(anchorFrame), cost: 0, accepted: referenceSeconds(acceptedFrame))
        }

        hear(room: analysis.peakiness, level: level)

        // The floor and the gate the room itself sets, rather than ones fixed in advance
        let tooQuiet = level < max(loudest * options.relativeSilence, levelFloor)
        let gate = peakinessGate
        let unmusical = gate > 0 && analysis.peakiness < gate
        let quiet = tooQuiet || unmusical

        quietRun = quiet ? quietRun + 1 : 0
        // Playing has to hold up for a few frames; a single loud frame used to be enough to declare the
        // piece under way and switch the gate off for good
        playingRun = quiet ? 0 : playingRun + 1
        if playingRun >= options.startFrames { playing = true }
        // The gate applies before the first note of the piece — and again at each movement's end,
        // where the pause is the pianist's and the score has nothing to say about it.
        let gateApplies = !options.gateOnlyBeforeFirstNote || !playing
            || atMovementJoin(warping.currentFrame)
        let silent = options.silenceGate && quietRun >= options.silenceFrames && gateApplies
        if silent {
            // Nothing to match: keep the position and the confidence from before
            return held(silent: true)
        }

        // Inside a written rest there is nothing to align against — the reference is silent too, so
        // silence matches silence anywhere in it — and a noisy room gives the warping a flat chroma
        // to slide along. Hold instead, and pick the piece up at the rest's first note.
        let quietForARest = analysis.peakiness < restGate || tooQuiet
        if options.freezeInRests && isRest(at: warping.currentFrame) && quietForARest {
            restRun += 1
            playingAgainRun = 0
            if restRun >= Int((options.restHoldSeconds * extractor.frameRate).rounded()) {
                if !holding {
                    holding = true
                    holdingSince = time
                    let note = firstSoundingFrame(from: warping.currentFrame) ?? warping.currentFrame
                    restLeftAtHold = Double(note - warping.currentFrame) / extractor.frameRate
                }
                frozenFrames += 1
                return held(silent: true)
            }
        } else {
            restRun = 0
        }
        var relocation = Relocation.none
        if holding {
            // Only real playing releases the hold: a noise frame that happens to look like a note
            // must not, because releasing also moves the position forward to the end of the rest
            let clearlyPlaying = analysis.peakiness >= max(gate, restGate) && !tooQuiet
            playingAgainRun = clearlyPlaying ? playingAgainRun + 1 : 0
            guard playingAgainRun >= options.resumeFrames else {
                frozenFrames += 1
                return held(silent: true)
            }
            let heldFor = time - (holdingSince ?? time)
            holding = false
            holdingSince = nil
            playingAgainRun = 0
            // Waited longer than the rest is written, so where the warping stopped is stale
            if options.reanchorAfterRest, heldFor > restLeftAtHold + options.reanchorAfterSeconds,
               let note = firstSoundingFrame(from: warping.currentFrame) {
                warping.relocate(to: note)
                reanchors += 1
                relocation = .local
                confidences.removeAll()
                lowConfidenceSince = nil
                recent.removeAll()
            }
        }

        let referenceFrame = warping.step(features)
        let raw = warping.windowMean > 0 ? max(0, (warping.windowMean - warping.localCost) / warping.windowMean) : 0
        confidences.append(raw)
        let keepConfidences = Int(max(options.confidenceSeconds, options.lostConfidenceSeconds, options.trustSeconds)
                                  * extractor.frameRate)
        if confidences.count > keepConfidences { confidences.removeFirst(confidences.count - keepConfidences) }
        let confidence = average(of: confidences, seconds: options.confidenceSeconds)
        lastConfidence = confidence

        let keep = Int(options.recoverySeconds * extractor.frameRate)
        if options.recovery || options.localReanchor {
            recent.append(features)
            if recent.count > keep { recent.removeFirst(recent.count - keep) }
        }
        if options.recovery && options.boundedRecovery {
            if recover(time: time, features: features) { relocation = .structural }
        } else if options.recovery {
            if average(of: confidences, seconds: options.lostConfidenceSeconds) < options.lostBelow {
                lowConfidenceSince = lowConfidenceSince ?? time
                if time - (lowConfidenceSince ?? time) >= options.lostForSeconds,
                   time - lastSearch >= options.searchEverySeconds, recent.count == keep {
                    lastSearch = time
                    searches += 1
                    let here = recent.enumerated().reduce(Float(0)) { total, pair in
                        let frame = warping.currentFrame - (recent.count - 1 - pair.offset)
                        return total + (frame >= 0 ? warping.distance(pair.element, toReferenceFrame: frame) : warping.windowMean)
                    } / Float(recent.count)
                    let minJump = Int(options.minJumpSeconds * extractor.frameRate)
                    if let found = warping.search(recent: recent, margin: options.searchMargin,
                                                  keepAwayFrames: Int(options.searchKeepAwaySeconds * extractor.frameRate)),
                       abs(found.frame - warping.currentFrame) >= minJump, found.cost < here * options.improvement {
                        warping.relocate(to: found.frame)
                        relocations += 1
                        relocation = .structural
                        lowConfidenceSince = nil
                        confidences.removeAll()
                    }
                }
            } else {
                lowConfidenceSince = nil
            }
        }

        // A correction too small for recovery to make. Run on a timer rather than on low
        // confidence: a follower a bar out in music that all sounds alike is not short of
        // confidence — it matches the wrong place about as well as it would the right one — so
        // confidence never says anything is wrong. The improvement test is what makes this safe.
        // Only while tracking: moves made while lost would walk the position away a second or two
        // at a time, which is exactly the drift recovery is bounded to prevent.
        if options.localReanchor, relocation == .none, state == .tracking, atRenderedPace,
           time - lastLocal >= options.localEverySeconds {
            let wanted = Int(options.localSeconds * extractor.frameRate)
            if recent.count >= wanted {
                lastLocal = time
                let block = Array(recent.suffix(wanted))
                let reach = Int(options.localReachSeconds * extractor.frameRate)
                if let found = warping.searchNear(block, reach: reach, rates: options.searchRates),
                   found.frame != warping.currentFrame,
                   found.cost < found.here * options.localImprovement {
                    warping.relocate(to: found.frame)
                    localMoves += 1
                    relocation = .local
                }
            }
        }

        if state == .tracking || !options.holdWhileUncertain { acceptedFrame = warping.currentFrame }
        if state == .tracking { trust(time: time) }
        if relocation != .none { paceHistory.removeAll() }
        paceHistory.append(warping.currentFrame)
        let paceFrames = Int(options.localPaceSeconds * extractor.frameRate)
        if paceHistory.count > paceFrames { paceHistory.removeFirst(paceHistory.count - paceFrames) }
        let reference = referenceSeconds(warping.currentFrame)
        if options.boundedRecovery && (options.recovery || options.localReanchor) {
            // Ends on the accepted path only, and only once it has stayed at the last note: a
            // candidate on trial never touches the accepted path, and a brief move there is not
            // the pianist finishing
            finishRun = state == .tracking && reference >= lastOnset ? finishRun + 1 : 0
            isFinished = Double(finishRun) >= max(options.finishHoldSeconds * extractor.frameRate, 1)
        } else {
            isFinished = reference >= lastOnset
        }
        return Position(time: time, reference: reference,
                        referenceFrame: relocation != .none ? warping.currentFrame : referenceFrame,
                        features: features, confidence: confidence, silent: false,
                        level: level, peakiness: analysis.peakiness, relocation: relocation, state: state,
                        anchor: referenceSeconds(anchorFrame), cost: warping.localCost,
                        accepted: referenceSeconds(acceptedFrame))
    }

    /// Whether the accepted path has lately moved at about the tempo the reference was rendered at.
    /// Unknown until `localPaceSeconds` have been followed without a move, and taken as yes then.
    private var atRenderedPace: Bool {
        guard let range = options.localPaceRange else { return true }
        let wanted = Int(options.localPaceSeconds * extractor.frameRate)
        guard paceHistory.count >= wanted, let first = paceHistory.first, let last = paceHistory.last else { return true }
        return range.contains(Double(last - first) / Double(paceHistory.count - 1))
    }

    // MARK: Bounded, provisional recovery

    /// One frame of recovery. Returns true when a candidate was confirmed and the position moved.
    private func recover(time: Double, features: [Float]) -> Bool {
        let rate = extractor.frameRate
        let lost = average(of: confidences, seconds: options.lostConfidenceSeconds) < options.lostBelow
        switch state {
        case .tracking:
            guard lost else {
                lowConfidenceSince = nil
                return false
            }
            lowConfidenceSince = lowConfidenceSince ?? time
            guard time - (lowConfidenceSince ?? time) >= options.lostForSeconds else { return false }
            // Doubt begins. The display keeps what it last showed; nothing moves the trusted place.
            state = .uncertain
            uncertainSince = time
            freshFrames = recent.count
            return false
        case .uncertain:
            freshFrames += 1
            // The warping may find its own way back. It counts only if it came back somewhere the
            // music could have got to from the trusted place: confidence alone cannot tell a
            // correct match from a confident wrong one.
            if average(of: confidences, seconds: options.confidenceSeconds) >= options.trustConfidence,
               recoveryRange(at: time).contains(warping.currentFrame) {
                state = .tracking
                lowConfidenceSince = nil
                uncertainSince = nil
                aheadHits.removeAll()
                return false
            }
            let keep = Int(options.recoverySeconds * rate)
            guard recent.count == keep, freshFrames >= Int(options.searchEverySeconds * rate) else { return false }
            freshFrames = 0
            lastSearch = time
            searches += 1
            propose(time: time)
            return false
        case .confirming:
            guard let probe else {
                state = .uncertain
                return false
            }
            probe.step(features)
            trial.frames += 1
            trial.candidateCost += probe.localCost
            trial.acceptedCost += warping.localCost
            trial.confidence += probe.windowMean > 0 ? max(0, (probe.windowMean - probe.localCost) / probe.windowMean) : 0
            guard trial.frames >= trial.needed else { return false }
            // Judged only on playing heard since the candidate was proposed, never on the block that
            // proposed it: that block already agreed, and asking it again proves nothing
            let pace = Double(probe.currentFrame - trial.start) / Double(trial.frames)
            let fits = trial.candidateCost <= options.confirmImprovement * trial.acceptedCost
            let matches = trial.confidence / Float(trial.frames) >= options.confirmConfidence
            let paced = pace >= options.confirmMinRate && pace <= options.confirmMaxRate
            guard fits && matches && paced && agrees(with: probe, time: time) else {
                rejections += 1
                state = .uncertain
                // The next candidate needs a whole block of playing no search has judged yet
                freshFrames = -Int(options.recoverySeconds * rate) + Int(options.searchEverySeconds * rate)
                return false
            }
            // Take the candidate's path as it stands, rather than restarting one at its position
            let accepted = probe
            self.probe = warping
            warping = accepted
            relocations += 1
            state = .tracking
            aheadHits.removeAll()
            anchorFrame = warping.currentFrame
            anchorTime = time
            acceptedFrame = warping.currentFrame
            settledSince = time
            lowConfidenceSince = nil
            uncertainSince = nil
            confidences.removeAll()
            return true
        }
    }

    /// Look for where the playing has got to, near the trusted place first; put the best on trial.
    ///
    /// Three tiers, each asking for more evidence than the last because a wrong answer there costs
    /// more: a few bars either side, then up to a page ahead for a follower that has fallen behind,
    /// then (only if allowed) anywhere.
    private func propose(time: Double) {
        let rate = extractor.frameRate
        let near = recoveryRange(at: time)
        let reach = Int(options.recoveryContextSeconds * rate)
        let keepAway = Int(options.searchKeepAwaySeconds * rate)
        let minJump = Int(options.minJumpSeconds * rate)
        let here = options.searchRates.map { warping.blockCost(recent, endingAt: warping.currentFrame, rate: $0) }.min() ?? .infinity
        func acceptable(_ found: OnlineTimeWarping.Search, margin: Float) -> Bool {
            // A place with no rival to beat has shown nothing: turned down, not taken by default
            guard let runnerUp = found.runnerUp else { return false }
            return abs(found.frame - warping.currentFrame) >= minJump
                && found.cost < here * options.improvement
                && found.cost <= options.candidateFit * found.typical
                && found.cost * margin < runnerUp
        }
        func look(in candidates: ClosedRange<Int>, context: ClosedRange<Int>) -> OnlineTimeWarping.Search? {
            warping.search(recent: recent, candidates: candidates, context: context, keepAway: keepAway,
                           rates: options.searchRates)
        }
        if let found = look(in: near, context: (near.lowerBound - reach)...(near.upperBound + reach)),
           acceptable(found, margin: options.searchMargin) {
            start(trialAt: found.frame, seconds: options.confirmSeconds, strict: options.confirmBySearch)
            return
        }
        if options.catchUpBarsAhead > options.recoveryBarsAhead {
            let ahead = recoveryRange(at: time, barsAhead: options.catchUpBarsAhead)
            if ahead.upperBound > near.upperBound,
               let found = look(in: (near.upperBound + 1)...ahead.upperBound,
                                context: (near.lowerBound - reach)...(ahead.upperBound + reach)) {
                if acceptable(found, margin: options.catchUpMargin) {
                    start(trialAt: found.frame, seconds: options.catchUpConfirmSeconds, strict: true)
                    return
                }
                // Not clear on its own; see whether an earlier, separate block pointed the same way
                if acceptable(found, margin: 1) {
                    aheadHits.removeAll { time - $0.time > options.catchUpMemorySeconds }
                    let onOnePath = aheadHits.contains { hit in
                        let apart = time - hit.time
                        let pace = Double(found.frame - hit.frame) / (apart * rate)
                        return apart >= options.recoverySeconds
                            && pace >= options.confirmMinRate && pace <= options.confirmMaxRate
                    }
                    aheadHits.append((time, found.frame))
                    if onOnePath {
                        aheadHits.removeAll()
                        start(trialAt: found.frame, seconds: options.catchUpConfirmSeconds, strict: true)
                        return
                    }
                }
            }
        }
        // Far away only after a long doubt, only on a clear winner, and only after a longer trial
        guard options.distantRecovery, let since = uncertainSince,
              time - since >= options.distantAfterSeconds else { return }
        let whole = 0...(warping.referenceCount - 1)
        if let found = look(in: whole, context: whole), !near.contains(found.frame),
           acceptable(found, margin: options.distantMargin) {
            start(trialAt: found.frame, seconds: options.distantConfirmSeconds, distant: true, strict: true)
        }
    }

    private func start(trialAt frame: Int, seconds: Double, distant: Bool = false, strict: Bool) {
        let path = probe ?? OnlineTimeWarping(sharing: warping)
        path.relocate(to: frame)
        probe = path
        trial = Trial(start: path.currentFrame, needed: max(Int(seconds * extractor.frameRate), 1),
                      distant: distant, strict: strict)
        candidates += 1
        state = .confirming
    }

    /// Search again with only the playing heard during the trial, and ask whether it points where
    /// the candidate's path has got to, clearly ahead of every rival.
    ///
    /// Beating the accepted path is not enough on its own: when the follower is lost the accepted
    /// path is wrong too, and in music built from repeated phrases a place eight bars back can beat
    /// it as easily as the right one. A second, independent block has to find the same place.
    private func agrees(with probe: OnlineTimeWarping, time: Double) -> Bool {
        guard trial.strict else { return true }
        let rate = extractor.frameRate
        let block = Array(recent.suffix(min(trial.frames, recent.count)))
        guard block.count >= Int(rate) else { return true }  // too little to search with
        let whole = 0...(warping.referenceCount - 1)
        let range = trial.distant ? whole : recoveryRange(at: time, barsAhead: max(options.catchUpBarsAhead, options.recoveryBarsAhead))
        let reach = Int(options.recoveryContextSeconds * rate)
        let context = trial.distant ? whole : (range.lowerBound - reach)...(range.upperBound + reach)
        guard let again = warping.search(recent: block, candidates: range, context: context,
                                         keepAway: Int(options.searchKeepAwaySeconds * rate),
                                         rates: options.searchRates),
              let runnerUp = again.runnerUp else { return false }
        return abs(again.frame - probe.currentFrame) <= Int(options.minJumpSeconds * rate)
            && again.cost * options.agreeMargin < runnerUp
    }

    /// Move the trusted place up to the position, if the position has earned it: confidence held
    /// for a while, no relocation in that time, and a place the music could have reached from the
    /// last trusted one. The last is what stops a run of small wrong moves ratcheting the place
    /// recovery looks near across the piece.
    private func trust(time: Double) {
        guard time - settledSince >= options.trustSeconds,
              average(of: confidences, seconds: options.trustSeconds) >= options.trustConfidence,
              recoveryRange(at: time).contains(warping.currentFrame) else { return }
        anchorFrame = warping.currentFrame
        anchorTime = time
    }

    /// Where a lost place may be looked for: a few bars back from the trusted place, a few ahead
    /// plus however far the music could have moved since, and within the trusted place's movement
    /// except for the opening bars of the next one.
    func recoveryRange(at time: Double, barsAhead: Double? = nil) -> ClosedRange<Int> {
        let rate = extractor.frameRate
        let allowance = max(0, time - anchorTime) * options.recoveryProgressRate * rate
        let anchor = Double(anchorFrame)
        var low = frame(ofBar: bar(ofFrame: anchor) - options.recoveryBarsBack)
        var high = frame(ofBar: bar(ofFrame: anchor) + (barsAhead ?? options.recoveryBarsAhead)) + allowance
        if let start = movementFrames.last(where: { $0 <= anchorFrame }) { low = max(low, Double(start)) }
        if let next = movementFrames.first(where: { $0 > anchorFrame }), high > Double(next) {
            high = min(high, frame(ofBar: bar(ofFrame: Double(next)) + options.recoveryBarsAhead))
        }
        let lo = min(max(Int(low.rounded(.down)), 0), warping.referenceCount - 1)
        let hi = min(max(Int(high.rounded(.up)), lo), warping.referenceCount - 1)
        return lo...hi
    }

    /// Fractional played-bar index of a reference frame; two-second bars when no bars were given.
    private func bar(ofFrame frame: Double) -> Double {
        guard barFrames.count >= 2 else { return frame / (2 * extractor.frameRate) }
        var lo = 0, hi = barFrames.count - 1
        if frame <= barFrames[0] { return 0 }
        if frame >= barFrames[hi] { return Double(hi) }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if barFrames[mid] <= frame { lo = mid } else { hi = mid }
        }
        let span = barFrames[hi] - barFrames[lo]
        return Double(lo) + (span > 0 ? (frame - barFrames[lo]) / span : 0)
    }

    private func frame(ofBar bar: Double) -> Double {
        guard barFrames.count >= 2 else { return bar * 2 * extractor.frameRate }
        let clamped = min(max(bar, 0), Double(barFrames.count - 1))
        let k = min(Int(clamped), barFrames.count - 2)
        return barFrames[k] + (barFrames[k + 1] - barFrames[k]) * (clamped - Double(k))
    }

    /// The peakiness a frame has to clear to count as playing: what the room asks for, but never
    /// looser than `minPeakiness` and never tighter than `maxPeakiness`.
    private var peakinessGate: Float {
        guard options.minPeakiness > 0 else { return 0 }
        guard let measured = calibration?.peakiness ?? room?.peakiness, measured > 0 else {
            return options.minPeakiness
        }
        return min(max(options.minPeakiness, measured + options.calibrationMargin), options.maxPeakiness)
    }

    /// The level a frame has to clear, from the room if it has been heard.
    private var levelFloor: Float {
        max(options.absoluteSilence, (calibration?.level ?? room?.level ?? 0) * options.floorMargin)
    }

    /// Listen to the room. Only frames that do not look like notes under the *fixed* threshold are
    /// taken, so that raising the gate can never feed back into raising it further.
    private func hear(room peakiness: Float, level: Float) {
        guard options.calibrateSeconds > 0, !playing, peakiness < options.minPeakiness else { return }
        roomPeakinessHeard.append(peakiness)
        roomLevelsHeard.append(level)
        let keep = Int(options.calibrationWindowSeconds * extractor.frameRate)
        if roomPeakinessHeard.count > keep {
            roomPeakinessHeard.removeFirst(roomPeakinessHeard.count - keep)
            roomLevelsHeard.removeFirst(roomLevelsHeard.count - keep)
        }
        sinceCalibrated += 1
        let enough = Int(options.calibrateSeconds * extractor.frameRate)
        guard roomPeakinessHeard.count >= enough, sinceCalibrated >= 16 else { return }
        sinceCalibrated = 0
        let heard = RoomNoise.highWaterMark(of: roomPeakinessHeard)
        var squares: Float = 0
        for value in roomLevelsHeard { squares += value * value }
        calibration = RoomCalibration(
            seconds: Double(roomPeakinessHeard.count) / extractor.frameRate,
            level: (squares / Float(roomLevelsHeard.count)).squareRoot(),
            peakiness: heard,
            gate: min(max(options.minPeakiness, heard + options.calibrationMargin), options.maxPeakiness),
            tooNoisy: heard + options.calibrationMargin > options.maxPeakiness)
    }

    /// The freeze threshold, shifted by however much the room raised the gate, so that the gap
    /// between "not playing" and "definitely playing" stays what it was measured at.
    private var restGate: Float {
        min(options.restPeakiness + (peakinessGate - options.minPeakiness), peakinessGate)
    }

    /// Is the reference silent at this frame, i.e. does the score rest here?
    /// True while the position stands at the join between two movements.
    ///
    /// Asked every frame rather than latched once. Clearing `playing` as the boundary came near was
    /// the obvious way to do this and does not work: the arming happens while the pianist is still
    /// playing the last bars, five frames of which put `playing` back, so the gate is off again by
    /// the time they actually stop. Held as a condition instead, it costs nothing while the playing
    /// continues — the gate only bites when the room goes quiet — and it is still true at the moment
    /// that matters, because a held position does not move out of the window.
    private func atMovementJoin(_ frame: Int) -> Bool {
        guard options.gateBetweenMovements, !movementFrames.isEmpty else { return false }
        let reach = Int((options.movementGateSeconds * extractor.frameRate).rounded())
        return movementFrames.contains { frame >= $0 - reach && frame <= $0 + reach }
    }

    private func isRest(at frame: Int) -> Bool {
        guard typicalReferenceLevel > 0, frame >= 0, frame < referenceLevels.count else { return false }
        return referenceLevels[frame] < options.restLevel * typicalReferenceLevel
    }

    /// The first frame from here on where the reference sounds again: the note after the rest.
    private func firstSoundingFrame(from frame: Int) -> Int? {
        var next = max(frame, 0)
        while next < referenceLevels.count {
            if !isRest(at: next) { return next > frame ? next : nil }
            next += 1
        }
        return nil
    }

    /// RMS of each analysis frame of the reference, framed exactly as the chromagram is.
    public static func frameLevels(of signal: [Float], fftLength: Int, hopLength: Int) -> [Float] {
        guard signal.count >= fftLength else { return [] }
        let count = 1 + (signal.count - fftLength) / hopLength
        return (0..<count).map { frame in
            var sum: Float = 0
            let start = frame * hopLength
            for i in start..<(start + fftLength) { sum += signal[i] * signal[i] }
            return (sum / Float(fftLength)).squareRoot()
        }
    }

    private func referenceSeconds(_ frame: Int) -> Double {
        Double(min(frame, warping.referenceCount - 1)) / extractor.frameRate
    }

    /// Mean of the most recent `seconds` of confidence values.
    private func average(of values: [Float], seconds: Double) -> Float {
        let count = min(max(Int(seconds * extractor.frameRate), 1), values.count)
        guard count > 0 else { return 0 }
        return values.suffix(count).reduce(0, +) / Float(count)
    }
}

/// Splits audio buffers of any size into `hopLength` chunks.
public struct HopChunker {
    public let hopLength: Int
    private var pending: [Float] = []

    public init(hopLength: Int) {
        self.hopLength = hopLength
    }

    public mutating func append(_ samples: [Float], _ body: (ArraySlice<Float>) -> Void) {
        pending += samples
        var offset = 0
        while pending.count - offset >= hopLength {
            body(pending[offset..<(offset + hopLength)])
            offset += hopLength
        }
        pending.removeFirst(offset)
    }
}

/// Maps between reference seconds and score position (quarter notes on the plan's time axis).
public struct ReferenceTimeline {
    public let quarters: [Double]
    public let seconds: [Double]

    /// Breakpoints from the plan: increasing quarter positions and the reference seconds at each.
    public init(quarters: [Double], seconds: [Double]) {
        precondition(quarters.count == seconds.count && quarters.count >= 2)
        self.quarters = quarters
        self.seconds = seconds
    }

    public func quarters(atSeconds s: Double) -> Double { Self.interpolate(s, seconds, quarters) }
    public func seconds(atQuarters q: Double) -> Double { Self.interpolate(q, quarters, seconds) }

    static func interpolate(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = xs[hi] - xs[lo]
        return span > 0 ? ys[lo] + (ys[hi] - ys[lo]) * (x - xs[lo]) / span : ys[hi]
    }
}
