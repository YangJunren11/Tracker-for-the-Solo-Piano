import Foundation

/// Anything that turns hops of audio into positions: one follower, or several choosing a tempo.
public protocol Following: AnyObject {
    var extractor: ChromaExtractor { get }
    /// What listening to the room before the first note came to.
    var calibration: RoomCalibration? { get }
    /// Start, or restart, at a place in reference seconds.
    func begin(atReferenceSeconds seconds: Double)
    func process(_ chunk: ArraySlice<Float>) -> ScoreFollower.Position?
}

extension ScoreFollower: Following {}

/// Follows at the tempo the pianist is playing, found from the bars they begin with.
///
/// A reference rendered far from the pianist's tempo is what loses slow practice, and a score with
/// no tempo marking is the same problem from the other side: none of Bach's preludes and fugues has
/// one, so they are rendered at a default of 120. Rather than ask, this starts a follower at each of
/// a few tempos wherever the pianist begins. Once the one that fits the playing best has followed
/// `openingBars` bars, it keeps that one and stops the rest. See the README.
///
/// Choosing once is the point. A choice that could be revisited at any moment flip-flopped at a
/// quarter speed, and once moved the display 32 bars by changing member. Here every member starts at
/// the same place and the choice is made within the opening, so it cannot become a jump anywhere
/// far; after it, one follower runs, as before. A restart (`begin`) chooses again: the tempo a
/// passage is practised at is not the tempo the piece is played at.
///
/// The evidence is the one a wrong tempo cannot fake. A member at the wrong tempo can keep its own
/// path's cost low by standing still or skipping; it cannot lay the last few seconds of playing
/// straight against its reference, ending where it thinks the music is, and have them line up. That
/// fit is averaged over every sounding moment since the start, and the lowest average wins.
public final class TempoChoice: Following {
    public struct Member {
        /// This member's reference tempo over the tempo positions are reported at: 0.5 is a
        /// reference rendered at half the tempo, twice as long, whose seconds are halved to report.
        public let rate: Double
        public let follower: ScoreFollower

        public init(rate: Double, follower: ScoreFollower) {
            self.rate = rate
            self.follower = follower
        }
    }

    public let members: [Member]
    /// The choice is made once the best-fitting member has followed this many bars from the start…
    public var openingBars: Double = 10
    /// …or after this many seconds of playing, whichever comes first.
    public var openingSeconds: Double = 60
    /// Seconds of playing each judgement lays against every reference. Two measured best of 2, 3,
    /// 4, 5 and 8: rubato bends a longer stretch away from any straight line.
    public var windowSeconds: Double = 2
    /// Frames between judgements; a judgement holds until the next.
    public var judgeEvery = 5
    /// How much better another tempo has to fit than the score's own before it is shown or chosen.
    /// Without it, steady harmony — a bar of one broken chord — fits a slower reference nearly as
    /// well, and the choice leant slow.
    public var preference: Double = 0.05
    /// Show whichever member fits best so far while choosing, rather than the one at the score's own
    /// tempo: with a marking four times too fast, that one is lost for the whole opening.
    public var showLeader = true

    /// The member at the score's own tempo: shown until another fits clearly better.
    public let preferred: Int
    /// The member chosen since the last start, once the opening is over.
    public private(set) var chosen: Int?
    /// When the choice was made, in seconds of performance.
    public private(set) var chosenAt: Double?

    public var extractor: ChromaExtractor { members[preferred].follower.extractor }
    /// The member whose positions are reported now.
    public var active: Member { members[chosen ?? shown] }
    public var isFinished: Bool {
        chosen.map { members[$0].follower.isFinished } ?? members.allSatisfy { $0.follower.isFinished }
    }
    public var calibration: RoomCalibration? { active.follower.calibration }

    /// Where each played bar starts, in reported seconds, with the end of the last one after it.
    private let barStarts: [Double]
    private var shown: Int
    private var recent: [[Float]] = []
    private var frames = 0
    private var judgement: [Float]
    private var totals: [Double]
    private var judged = 0
    private var heard = 0
    private var startBar: Double?
    private var lastShownBar = 0.0

    /// `barStarts` are on the reported axis — `Plan.barStarts` — and each member's follower is
    /// given its own, divided by its rate.
    public init(members: [Member], barStarts: [Double]) {
        precondition(!members.isEmpty)
        self.members = members
        self.barStarts = barStarts
        preferred = members.firstIndex { abs($0.rate - 1) < 1e-9 } ?? 0
        shown = preferred
        judgement = Array(repeating: .infinity, count: members.count)
        totals = Array(repeating: 0, count: members.count)
    }

    /// Start, or restart, every member at a place in reported seconds, and choose again.
    public func begin(atReferenceSeconds seconds: Double) {
        for member in members { member.follower.begin(atReferenceSeconds: seconds / member.rate) }
        chosen = nil
        chosenAt = nil
        shown = preferred
        recent = []
        frames = 0
        judgement = Array(repeating: .infinity, count: members.count)
        totals = Array(repeating: 0, count: members.count)
        judged = 0
        heard = 0
        startBar = nil
    }

    public func process(_ chunk: ArraySlice<Float>) -> ScoreFollower.Position? {
        if let chosen {
            return members[chosen].follower.process(chunk).map { reported($0, rate: members[chosen].rate) }
        }
        // A member that comes to the end of its reference stops: typically one rendered much faster
        // than the playing, which runs out of music. It drops out of the choice instead of ending it.
        let positions = members.map { $0.follower.isFinished ? nil : $0.follower.process(chunk) }
        let live = members.indices.filter { positions[$0] != nil }
        guard let first = live.first else { return nil }  // the first hop only primes, or all have finished
        let bars = members.indices.map { k in
            positions[k].map { bar(atSeconds: $0.reference * members[k].rate) } ?? -.infinity
        }
        if startBar == nil { startBar = live.map { bars[$0] }.min() }

        let window = Int(windowSeconds * extractor.frameRate)
        recent.append(positions[first]!.features)  // the same playing for every member
        if recent.count > window { recent.removeFirst(recent.count - window) }
        if frames >= window, (frames - window) % judgeEvery == 0 {
            for k in members.indices {
                judgement[k] = positions[k].map {
                    straightCost(of: members[k].follower, endingAt: Int(($0.accepted * extractor.frameRate).rounded()))
                } ?? .infinity
            }
        }
        frames += 1

        let sounding = !live.contains { positions[$0]!.silent }
        if sounding { heard += 1 }
        if sounding, live.allSatisfy({ judgement[$0].isFinite }) {
            for k in live { totals[k] += Double(judgement[k]) }
            judged += 1
        }
        let best = live.min { totals[$0] < totals[$1] }!
        let preferredLive = positions[preferred] != nil
        var leader = preferredLive ? preferred : best
        if judged > 0, !preferredLive || totals[best] < totals[preferred] * (1 - preference) { leader = best }
        var next = showLeader && judged > 0 ? leader : shown
        if positions[next] == nil { next = leader }
        let frame = 1 / extractor.frameRate
        if Double(judged) * frame >= min(2, windowSeconds),
           bars[leader] - (startBar ?? 0) >= openingBars || Double(heard) * frame >= openingSeconds {
            chosen = leader
            chosenAt = positions[leader]!.time
            next = leader
        }
        // Changing member is not following: the display goes straight to the new one's place
        let moved = next != shown && abs(bars[next] - lastShownBar) > 1
        shown = next
        lastShownBar = bars[shown]
        var position = reported(positions[shown]!, rate: members[shown].rate, relocation: moved ? .structural : nil)
        position.choosingTempo = chosen == nil
        return position
    }

    /// Mean distance of the recent playing laid frame for frame against a member's reference, ending
    /// at `end`; infinite until half the frames fall inside the reference.
    private func straightCost(of follower: ScoreFollower, endingAt end: Int) -> Float {
        let warping = follower.warping
        let last = min(max(end, 0), warping.referenceCount - 1)
        var total: Float = 0, counted = 0
        for (offset, frame) in recent.reversed().enumerated() where last - offset >= 0 {
            total += warping.distance(frame, toReferenceFrame: last - offset)
            counted += 1
        }
        return counted > recent.count / 2 ? total / Float(counted) : .infinity
    }

    /// Fractional played-bar index of a place in reported seconds.
    private func bar(atSeconds seconds: Double) -> Double {
        guard barStarts.count > 1 else { return seconds / 2 }  // two seconds a bar, as recovery assumes
        var low = 0, high = barStarts.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if barStarts[mid] <= seconds { low = mid } else { high = mid }
        }
        let span = max(barStarts[low + 1] - barStarts[low], 1e-9)
        return Double(low) + min(max((seconds - barStarts[low]) / span, 0), 1)
    }

    /// A member's position on the reported axis.
    private func reported(_ p: ScoreFollower.Position, rate: Double,
                          relocation: Relocation? = nil) -> ScoreFollower.Position {
        ScoreFollower.Position(time: p.time, reference: p.reference * rate,
                               referenceFrame: Int((Double(p.referenceFrame) * rate).rounded()),
                               features: p.features, confidence: p.confidence, silent: p.silent,
                               level: p.level, peakiness: p.peakiness, relocation: relocation ?? p.relocation,
                               state: p.state, anchor: p.anchor * rate, cost: p.cost, accepted: p.accepted * rate,
                               tempo: rate)
    }
}
