import Foundation

/// Online time warping with a step-size limit (Arzt & Widmer 2010).
///
/// A port of Matchmaker's `OnlineTimeWarpingArztFrame` and its Cython loop (`oltw_arzt_loop`),
/// kept numerically identical, including the unnormalized cost used for the very first cell.
///
/// Each performance frame fills one column of the accumulated-cost matrix, but only for reference
/// frames within `windowFrames` of the current position. The position is the cell with the lowest
/// cost divided by path length, and may move forward by at most `stepSize` frames per input
/// frame and never backward.
public final class OnlineTimeWarping {
    public let dimension: Int
    public let referenceCount: Int
    public let windowFrames: Int
    public let startWindowFrames: Int
    public let stepSize: Int
    /// How far the position may move back towards the start, in reference frames per input frame.
    ///
    /// Zero is Matchmaker's behaviour and the paper's: the position advances or stands still, never
    /// retreats. That is safe, but it means the follower can only ever be wrong in one direction —
    /// where the music gives no evidence to advance, standing still is the only legal move, and any
    /// error so accumulated is permanent. A few frames back per input frame let the same cost
    /// surface that found the error undo it, gradually, and without discarding the path the way a
    /// relocation does. Sustained, pedalled writing needs this most: a chroma frame there cannot
    /// tell one moment from its neighbours, so the position sits while the music moves on.
    public let backStep: Int

    /// Reference frame the performance is currently at.
    public private(set) var currentFrame = 0
    /// Number of performance frames processed.
    public private(set) var inputIndex = 0
    /// Distance between the last performance frame and the reference frame it was matched to.
    public private(set) var localCost: Float = 0
    /// Average distance to every reference frame in the search window, as a scale for `localCost`.
    public private(set) var windowMean: Float = 0

    private let reference: [Float]  // referenceCount x dimension, row-major
    // Columns 0 and 1 of Matchmaker's global cost matrix, indexed by reference frame + 1.
    private var previous: [Float]
    private var current: [Float]
    private var finiteInPrevious: Range<Int> = 0..<0
    private var windowCost: [Float]
    // Where the current path began. Zero until `relocate`, so the normalization below is Matchmaker's
    // exactly: it divides the accumulated cost by the number of steps taken to reach the cell, and
    // after a relocation those steps are counted from the new position, not from the start of the
    // piece. Without this, a relocation deep into a long piece divides by a number so large that
    // every cell in the window looks equally good and the position creeps forward instead of
    // tracking (measured: a re-anchored run sat 0.2-0.3 s behind for the rest of the movement).
    private var originInput = 0
    private var originFrame = 0

    public init(reference frames: [[Float]], frameRate: Double, windowSeconds: Double = 10,
                startWindowSeconds: Double = 0.1, stepSize: Int = 3, backStep: Int = 0) {
        precondition(!frames.isEmpty, "reference has no frames")
        dimension = frames[0].count
        referenceCount = frames.count
        reference = frames.flatMap { $0 }
        // np.round rounds halves to even
        windowFrames = Int((windowSeconds * frameRate).rounded(.toNearestOrEven))
        startWindowFrames = Int((startWindowSeconds * frameRate).rounded(.toNearestOrEven))
        self.stepSize = stepSize
        self.backStep = backStep
        previous = [Float](repeating: .infinity, count: referenceCount + 1)
        current = previous
        windowCost = [Float](repeating: 0, count: referenceCount)
    }

    /// A second path over the same reference, for trying out a place without disturbing the path
    /// already accepted. The reference features are shared rather than copied: an array is only
    /// copied when written to, and nothing writes to them.
    public init(sharing other: OnlineTimeWarping) {
        dimension = other.dimension
        referenceCount = other.referenceCount
        reference = other.reference
        windowFrames = other.windowFrames
        startWindowFrames = other.startWindowFrames
        stepSize = other.stepSize
        backStep = other.backStep
        previous = [Float](repeating: .infinity, count: referenceCount + 1)
        current = previous
        windowCost = [Float](repeating: 0, count: referenceCount)
    }

    /// Consume one performance frame and return the updated reference frame.
    @discardableResult
    public func step(_ input: [Float]) -> Int {
        precondition(input.count == dimension)
        let width = currentFrame < startWindowFrames ? startWindowFrames : windowFrames
        let start = max(currentFrame - width, 0)
        let end = min(currentFrame + width, referenceCount)

        reference.withUnsafeBufferPointer { ref in
            input.withUnsafeBufferPointer { x in
                for j in start..<end {
                    var distance: Float = 0  // Manhattan (L1)
                    let row = j * dimension
                    for i in 0..<dimension {
                        distance += abs(ref[row + i] - x[i])
                    }
                    windowCost[j - start] = distance
                }
            }
        }

        var minCost = Float.infinity
        var minIndex = max(currentFrame - stepSize, 0)
        if start == 0 && inputIndex == 0 {
            var sum: Float = 0
            for k in 0..<(end - start) { sum += windowCost[k] }
            current[1] = sum
            minCost = sum
            minIndex = 0
        }
        for scoreIndex in start..<end where !(scoreIndex == 0 && inputIndex == 0) {
            let d = windowCost[scoreIndex - start]
            let best = min(current[scoreIndex] + d,  // reference advanced within this input frame
                           previous[scoreIndex + 1] + d,  // input advanced, reference stayed
                           previous[scoreIndex] + d)  // both advanced
            current[scoreIndex + 1] = best
            let steps = (inputIndex - originInput) + (scoreIndex - originFrame)
            let normalized = Float(Double(best) / (Double(max(steps, 0)) + 1.0))
            if normalized < minCost {
                minCost = normalized
                minIndex = scoreIndex
            }
        }

        // Shift the columns: this column becomes the previous one, the next starts at infinity.
        swap(&previous, &current)
        for i in finiteInPrevious { current[i] = .infinity }
        finiteInPrevious = (start + 1)..<(end + 1)

        let floor = max(currentFrame - backStep, 0)
        currentFrame = inputIndex > 0 ? min(max(minIndex, floor), currentFrame + stepSize) : minIndex
        inputIndex += 1

        var sum: Float = 0
        for k in 0..<(end - start) { sum += windowCost[k] }
        windowMean = sum / Float(max(end - start, 1))
        localCost = windowCost[min(max(currentFrame - start, 0), end - start - 1)]
        return currentFrame
    }

    /// Distance between a performance frame and one reference frame.
    func distance(_ x: [Float], toReferenceFrame j: Int) -> Float {
        var distance: Float = 0
        let row = j * dimension
        for i in 0..<dimension { distance += abs(reference[row + i] - x[i]) }
        return distance
    }

    /// Where in the whole reference the recent performance frames fit best ("where am I?").
    ///
    /// Compares the last frames against every position in the reference, and answers only when the
    /// best position beats everything outside its neighbourhood by `margin`, so that passages which
    /// sound alike produce no answer instead of a wrong one.
    public func search(recent frames: [[Float]], margin: Float, keepAwayFrames: Int) -> (frame: Int, cost: Float)? {
        guard frames.count > 1, referenceCount > frames.count else { return nil }
        var costs = [Float](repeating: .infinity, count: referenceCount)
        for end in (frames.count - 1)..<referenceCount {
            var total: Float = 0
            for (offset, frame) in frames.reversed().enumerated() {
                total += distance(frame, toReferenceFrame: end - offset)
            }
            costs[end] = total / Float(frames.count)
        }
        guard let best = costs.indices.min(by: { costs[$0] < costs[$1] }), costs[best].isFinite else { return nil }
        var runnerUp = Float.infinity
        for (j, cost) in costs.enumerated() where abs(j - best) > keepAwayFrames {
            runnerUp = min(runnerUp, cost)
        }
        guard runnerUp.isFinite, costs[best] * margin < runnerUp else { return nil }
        return (best, costs[best])
    }

    /// Where the recent frames fit best within `reach` of the current position, and what the
    /// current position itself costs, so the caller can weigh the one against the other.
    ///
    /// The warping compares one frame at a time, and one chroma frame cannot tell a moment from its
    /// neighbours in sustained, pedalled writing — measured on Ravel's *Pavane*, half a second of
    /// music either side is indistinguishable. A block of frames can: it carries the order the
    /// harmonies came in, which a single frame throws away. This asks the smaller question recovery
    /// never asks, "of the places near here, which fits the last couple of seconds best?"
    ///
    /// `rates` lays the block at several tempos, as `search` does; a place and the current position
    /// are each judged at their best rate, so the comparison stays like for like.
    public func searchNear(_ recent: [[Float]], reach: Int, rates: [Double] = [1]) -> (frame: Int, cost: Float, here: Float)? {
        guard recent.count > 1, referenceCount > recent.count else { return nil }
        func cost(endingAt end: Int) -> Float {
            rates.map { blockCost(recent, endingAt: end, rate: $0) }.min() ?? .infinity
        }
        let low = max(currentFrame - reach, 0)
        let high = min(currentFrame + reach, referenceCount - 1)
        guard low <= high else { return nil }
        var bestFrame = low, best = Float.infinity
        for end in low...high {
            let c = cost(endingAt: end)
            if c < best { best = c; bestFrame = end }
        }
        return (bestFrame, best, cost(endingAt: currentFrame))
    }

    /// What a search of part of the reference found, with what the caller needs to judge it.
    public struct Search {
        /// Reference frame the most recent input frame lines up with.
        public let frame: Int
        /// Mean distance along the block at that place.
        public let cost: Float
        /// Reference frames per input frame the block was laid at, 1 being the rendered tempo.
        public let rate: Double
        /// The best place in `context` that is not within `keepAway` of `frame`, or nil when the
        /// context is too short to hold one — in which case nothing says the answer is distinctive.
        public let runnerUp: Float?
        /// Mean over the context of each place's best cost: what an arbitrary place fits like.
        public let typical: Float
    }

    /// Where the recent frames fit best among `candidates`, judged against every place in `context`.
    ///
    /// The two ranges are kept apart on purpose. Restricting the answer to a few bars near where the
    /// pianist was keeps a match with a similar passage pages away from being taken; but restricting
    /// the *rivals* to the same few bars would make almost any answer look distinctive, because
    /// there would be nothing left to be confused with. So rivals are drawn from a wider context.
    ///
    /// `rates` lays the block at several tempos: at 0.5 the last three seconds of playing are
    /// compared with a second and a half of reference, which is what half-speed practice sounds
    /// like against a reference rendered at the marked tempo. A place's cost is its best over the
    /// rates, so a rate is chosen for the place and not for the search as a whole.
    public func search(recent frames: [[Float]], candidates: ClosedRange<Int>, context: ClosedRange<Int>,
                       keepAway: Int, rates: [Double] = [1]) -> Search? {
        let n = frames.count
        guard n > 1, !rates.isEmpty else { return nil }
        let low = max(context.lowerBound, 0), high = min(context.upperBound, referenceCount - 1)
        guard low <= high else { return nil }
        var costs = [Float](repeating: .infinity, count: high - low + 1)
        var bestRate = [Double](repeating: 1, count: high - low + 1)
        // The block's frames, newest first, flattened once
        var block = [Float](repeating: 0, count: n * dimension)
        for (offset, frame) in frames.reversed().enumerated() {
            for i in 0..<dimension { block[offset * dimension + i] = frame[i] }
        }
        // Reference rows each block frame falls on, per rate (offset 0 is the newest frame), flattened
        let steps = rates.flatMap { rate in (0..<n).map { Int((Double($0) * rate).rounded()) } }
        // The whole piece against three seconds of playing is tens of millions of comparisons, and
        // the hops of a live input wait behind it, at exactly the moment the place is needed. The
        // places are shared out among the cores, and a chroma frame's twelve bins compared four at
        // a time.
        let chunk = 512
        let dimension = dimension
        costs.withUnsafeMutableBufferPointer { costsBuffer in
            bestRate.withUnsafeMutableBufferPointer { ratesBuffer in
                // Each chunk writes only its own places
                let costs = costsBuffer, bestRate = ratesBuffer
                reference.withUnsafeBufferPointer { ref in
                    block.withUnsafeBufferPointer { x in
                        steps.withUnsafeBufferPointer { steps in
                            let work = { (c: Int) in
                                for end in (low + c * chunk)...min(low + (c + 1) * chunk - 1, high) {
                                    for r in rates.indices where end - steps[r * n + n - 1] >= 0 {
                                        let step = UnsafeBufferPointer(rebasing: steps[(r * n)..<(r * n + n)])
                                        let cost = Self.blockDistance(ref, x, endingAt: end, step: step,
                                                                      dimension: dimension) / Float(n)
                                        if cost < costs[end - low] {
                                            costs[end - low] = cost
                                            bestRate[end - low] = rates[r]
                                        }
                                    }
                                }
                            }
                            let chunks = (high - low) / chunk + 1
                            if chunks > 1 {
                                DispatchQueue.concurrentPerform(iterations: chunks, execute: work)
                            } else {
                                work(0)
                            }
                        }
                    }
                }
            }
        }
        let lowCandidate = max(candidates.lowerBound, low), highCandidate = min(candidates.upperBound, high)
        guard lowCandidate <= highCandidate else { return nil }
        var best = lowCandidate
        for j in lowCandidate...highCandidate where costs[j - low] < costs[best - low] { best = j }
        guard costs[best - low].isFinite else { return nil }
        var runnerUp = Float.infinity, sum: Float = 0, counted = 0
        for j in low...high where costs[j - low].isFinite {
            sum += costs[j - low]
            counted += 1
            if abs(j - best) > keepAway { runnerUp = min(runnerUp, costs[j - low]) }
        }
        return Search(frame: best, cost: costs[best - low], rate: bestRate[best - low],
                      runnerUp: runnerUp.isFinite ? runnerUp : nil, typical: sum / Float(max(counted, 1)))
    }

    /// Summed L1 distance of a flattened block (newest frame first) laid back from reference frame
    /// `end`, block frame `k` on reference row `end - step[k]`.
    @inline(__always)
    private static func blockDistance(_ ref: UnsafeBufferPointer<Float>, _ x: UnsafeBufferPointer<Float>,
                                      endingAt end: Int, step: UnsafeBufferPointer<Int>, dimension: Int) -> Float {
        guard dimension == 12, let refBase = ref.baseAddress, let xBase = x.baseAddress else {
            var total: Float = 0
            for offset in step.indices {
                let row = (end - step[offset]) * dimension, col = offset * dimension
                for i in 0..<dimension { total += abs(ref[row + i] - x[col + i]) }
            }
            return total
        }
        // A chroma frame: three groups of four bins, each summed apart so no addition waits on another
        var a = SIMD4<Float>(), b = SIMD4<Float>(), c = SIMD4<Float>()
        for offset in step.indices {
            let row = UnsafeRawPointer(refBase + (end - step[offset]) * 12)
            let col = UnsafeRawPointer(xBase + offset * 12)
            a += absolute(row.loadUnaligned(as: SIMD4<Float>.self) - col.loadUnaligned(as: SIMD4<Float>.self))
            b += absolute(row.loadUnaligned(fromByteOffset: 16, as: SIMD4<Float>.self)
                          - col.loadUnaligned(fromByteOffset: 16, as: SIMD4<Float>.self))
            c += absolute(row.loadUnaligned(fromByteOffset: 32, as: SIMD4<Float>.self)
                          - col.loadUnaligned(fromByteOffset: 32, as: SIMD4<Float>.self))
        }
        return (a + b + c).sum()
    }

    /// |v|, bin by bin.
    @inline(__always)
    private static func absolute(_ v: SIMD4<Float>) -> SIMD4<Float> {
        pointwiseMax(v, -v)
    }

    /// Mean distance of the recent frames laid back from `end` at `rate`, frames before the start
    /// of the reference counting as an average one.
    func blockCost(_ frames: [[Float]], endingAt end: Int, rate: Double = 1) -> Float {
        guard !frames.isEmpty else { return 0 }
        var total: Float = 0
        for (offset, frame) in frames.reversed().enumerated() {
            let j = end - Int((Double(offset) * rate).rounded())
            total += j >= 0 && j < referenceCount ? distance(frame, toReferenceFrame: j) : windowMean
        }
        return total / Float(frames.count)
    }

    /// Restart the search from a position, as if following had just begun there.
    public func relocate(to frame: Int) {
        let clamped = min(max(frame, 0), referenceCount - 1)
        for i in previous.indices { previous[i] = .infinity }
        for i in current.indices { current[i] = .infinity }
        previous[clamped + 1] = 0
        finiteInPrevious = (clamped + 1)..<(clamped + 2)
        currentFrame = clamped
        // The path starts again here, so the cost normalization has to count from here too
        originInput = inputIndex
        originFrame = clamped
    }
}
