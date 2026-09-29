import Foundation

/// A score: bars, repeat structure and notes, in quarter notes from the start.
///
/// Read from MusicXML by `MusicXMLReader`, or decoded from JSON of the same shape. Bar references
/// are indices into `bars`.
public struct ScoreData: Codable {
    public struct Bar: Codable {
        public let label: String  // bar number as printed, e.g. "0", "12", "X1"
        public let number: Int  // printed bar number this bar belongs to
        public let start: Double
        public let duration: Double

        /// What a pianist reads on the page.
        ///
        /// Usually the label, but a printed bar split by a repeat sign — the Menuetto whose second
        /// strain begins with an upbeat — is two bars in the score, and the second carries a label
        /// left out of the count ("X1"). An edition prints one number across both halves, so that
        /// is the one to name.
        public var printed: String { Int(label) != nil ? label : "\(number)" }
    }

    public struct Repeat: Codable {
        public let start: Int
        public let end: Int  // bar with the backward repeat sign
        public let endings: [[Int]]  // [first, last] bar for pass 1, 2, ...
        public let times: Int
    }

    public struct Jump: Codable {
        public let kind: String  // "D.C." or "D.S."
        public let at: Int
        public let target: Int
        public let fine: Int?
        public let toCoda: Int?
        public let coda: Int?
    }

    public struct Note: Codable {
        public let onset: Double
        public let duration: Double
        public let pitch: Int
        public let bar: Int
    }

    /// A movement, or one half of a prelude and fugue: bar numbers restart in each part.
    public struct Part: Codable, Hashable {
        public let name: String
        public let firstBar: Int
        /// The tempo marking as printed, when the score carries one: Bach's preludes do not, and a
        /// marking only in German or French is taken as it stands.
        public let tempo: String?

        /// True when the name is the movement's number rather than a title ("III", not "Fugue").
        ///
        /// The number may carry a qualifier the database adds — "I (no repeat)" — so only the first
        /// word is tested.
        public var isNumbered: Bool {
            let first = name.split(separator: " ").first ?? ""
            return !first.isEmpty && first.allSatisfy { "IVXLC".contains($0) }
        }
    }

    public let title: String
    public let composer: String
    /// How many movements the whole work has, when the database knows: the parts here may be only
    /// some of them, because a score database holds what it holds.
    public let movements: Int?
    private let storedParts: [Part]?
    public let bars: [Bar]
    public let repeats: [Repeat]
    public let jumps: [Jump]
    public let tempos: [[Double]]  // [bar index, quarter-note BPM]
    public let notes: [Note]

    /// The parts of the work, in playing order. Empty for a piece that is all one part.
    public var parts: [Part] { storedParts ?? [] }

    private enum CodingKeys: String, CodingKey {
        case title, composer, movements, bars, repeats, jumps, tempos, notes
        case storedParts = "parts"
    }

    /// Built here only by `MusicXMLReader`, for a score the pianist brings themselves; the bundled
    /// database arrives as JSON. `parts` is stored as written: empty means a piece all in one part.
    public init(title: String, composer: String, movements: Int?, parts: [Part], bars: [Bar],
                repeats: [Repeat], jumps: [Jump], tempos: [[Double]], notes: [Note]) {
        self.title = title
        self.composer = composer
        self.movements = movements
        self.storedParts = parts
        self.bars = bars
        self.repeats = repeats
        self.jumps = jumps
        self.tempos = tempos
        self.notes = notes
    }

    /// The bars belonging to a part.
    public func bars(ofPart index: Int) -> Range<Int> {
        guard parts.indices.contains(index) else { return 0..<bars.count }
        let end = index + 1 < parts.count ? parts[index + 1].firstBar : bars.count
        return parts[index].firstBar..<end
    }

    /// How many repeats and jumps fall inside a part.
    public func structure(ofPart index: Int) -> (repeats: Int, jumps: Int) {
        let range = bars(ofPart: index)
        return (repeats.filter { range.contains($0.start) }.count,
                jumps.filter { range.contains($0.at) }.count)
    }

    /// Which part a bar belongs to.
    public func part(ofBar bar: Int) -> Int {
        parts.lastIndex { $0.firstBar <= bar } ?? 0
    }

    public func partName(_ index: Int) -> String? {
        parts.indices.contains(index) ? parts[index].name : nil
    }

    /// Marked tempo in force at a bar; bars before the first marking use the first marking.
    public func bpm(at bar: Int, default fallback: Double = 120) -> Double {
        guard !tempos.isEmpty else { return fallback }
        var bpm = tempos[0][1]
        for marking in tempos where Int(marking[0]) <= bar { bpm = marking[1] }
        return bpm
    }

    /// First and last bar carrying a printed bar number, within one part.
    ///
    /// Bar numbers restart in each part, so "bar 1" of a prelude and "bar 1" of its fugue are
    /// different bars and the part has to be given.
    public func bars(numbered number: Int, inPart part: Int = 0) -> (first: Int, last: Int)? {
        let matching = bars(ofPart: part).filter { bars[$0].number == number }
        return matching.isEmpty ? nil : (matching.first!, matching.last!)
    }
}

/// Which repeats and jumps the pianist takes.
public struct Setup: Codable {
    /// One flag per repeat in `ScoreData.repeats`, in the same order.
    public var repeatsEnabled: [Bool]
    /// One flag per jump.
    public var jumpsEnabled: [Bool]
    /// Take repeats again after a D.C./D.S.? Conventionally not.
    public var repeatsAfterJump: Bool

    public init(repeatsEnabled: [Bool] = [], jumpsEnabled: [Bool] = [], repeatsAfterJump: Bool = false) {
        self.repeatsEnabled = repeatsEnabled
        self.jumpsEnabled = jumpsEnabled
        self.repeatsAfterJump = repeatsAfterJump
    }

    public static func defaults(for score: ScoreData) -> Setup {
        Setup(repeatsEnabled: score.repeats.map { _ in true }, jumpsEnabled: score.jumps.map { _ in true })
    }

    private enum CodingKeys: String, CodingKey {
        case repeatsEnabled, jumpsEnabled, repeatsAfterJump
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repeatsEnabled = try values.decodeIfPresent([Bool].self, forKey: .repeatsEnabled) ?? []
        jumpsEnabled = try values.decodeIfPresent([Bool].self, forKey: .jumpsEnabled) ?? []
        repeatsAfterJump = try values.decodeIfPresent(Bool.self, forKey: .repeatsAfterJump) ?? false
    }
}

/// The score with its repeats written out: what the pianist will actually play, in order.
///
/// Its time axis, quarter notes from the start of the performance, is what positions are reported
/// on (through `timeline`).
public struct Plan {
    public struct PlayedBar {
        public let bar: Int  // index into ScoreData.bars
        public let label: String
        public let start: Double  // quarter notes from the start of the performance
        public let duration: Double
        public var end: Double { start + duration }
    }

    public let score: ScoreData
    public let played: [PlayedBar]
    /// Notes in playing order, timed in quarter notes of the performance.
    public let notes: [ScoreData.Note]
    public let timeline: ReferenceTimeline
    /// Notes timed in reference seconds, ready for `SoundFontRenderer`.
    public let referenceNotes: [ReferenceNote]

    public var duration: Double { played.last?.end ?? 0 }

    public init(score: ScoreData, setup: Setup, defaultBPM: Double = 120) {
        self.score = score
        let order = Self.playingOrder(score: score, setup: setup)
        var played: [PlayedBar] = []
        var t = 0.0
        for bar in order {
            played.append(PlayedBar(bar: bar, label: score.bars[bar].label, start: t,
                                    duration: score.bars[bar].duration))
            t += score.bars[bar].duration
        }
        self.played = played

        // Notes of each played bar, shifted onto the performance time axis
        var byBar: [Int: [ScoreData.Note]] = [:]
        for note in score.notes { byBar[note.bar, default: []].append(note) }
        var notes: [ScoreData.Note] = []
        for (k, playedBar) in played.enumerated() {
            let followsInScore = k + 1 < played.count && played[k + 1].bar == playedBar.bar + 1
            for note in byBar[playedBar.bar] ?? [] {
                let onset = playedBar.start + (note.onset - score.bars[playedBar.bar].start)
                // A jump follows: don't let held notes ring into unrelated music
                let duration = followsInScore ? note.duration : min(note.duration, playedBar.end - onset)
                notes.append(ScoreData.Note(onset: onset, duration: duration, pitch: note.pitch, bar: playedBar.bar))
            }
        }
        let planNotes = notes.sorted { $0.onset < $1.onset }
        self.notes = planNotes

        var quarters = [0.0], seconds = [0.0]
        for playedBar in played where playedBar.duration > 0 {
            quarters.append(playedBar.end)
            seconds.append(seconds[seconds.count - 1] + playedBar.duration * 60 / score.bpm(at: playedBar.bar, default: defaultBPM))
        }
        let line = ReferenceTimeline(quarters: quarters, seconds: seconds)
        timeline = line

        referenceNotes = planNotes.map {
            let onset = line.seconds(atQuarters: $0.onset)
            return ReferenceNote(onset: onset, duration: line.seconds(atQuarters: $0.onset + $0.duration) - onset,
                                 pitch: UInt8(clamping: $0.pitch))
        }
    }

    /// Every place a printed bar number is played, in quarter notes. A bar inside a repeated section
    /// is played more than once, so the caller (or the pianist) picks which time.
    public func positions(ofBarNumbered number: Int, inPart part: Int = 0) -> [Double] {
        let range = score.bars(ofPart: part)
        return played.filter { range.contains($0.bar) && score.bars[$0.bar].number == number }.map(\.start)
    }

    /// "Fugue, bar 12" — how to name where the follower is, in a work of several parts.
    public func describe(_ bar: PlayedBar) -> String {
        let name = score.partName(score.part(ofBar: bar.bar)).flatMap { $0.isEmpty ? nil : $0 }
        let printed = score.bars.indices.contains(bar.bar) ? score.bars[bar.bar].printed : bar.label
        return name.map { "\($0), bar \(printed)" } ?? "bar \(printed)"
    }

    /// Where each played bar starts, in reference seconds, with the end of the last one after it:
    /// what `ScoreFollower(barStarts:)` needs to bound its recovery in bars. In playing order, so a
    /// repeat's second pass is later than its first, as it is in the reference.
    public var barStarts: [Double] {
        played.map { timeline.seconds(atQuarters: $0.start) } + [timeline.seconds(atQuarters: duration)]
    }

    /// Where each movement after the first begins, in reference seconds.
    ///
    /// What the follower needs to know to put its start gate back on at a movement break. Taken from
    /// the first time a movement's opening bar is played, so a repeat earlier in the work does not
    /// move it.
    public var movementStarts: [Double] {
        guard score.parts.count > 1 else { return [] }
        return score.parts.dropFirst().compactMap { part in
            played.first { $0.bar == part.firstBar }.map { timeline.seconds(atQuarters: $0.start) }
        }
    }

    /// The bar the performance is at, for a position in quarter notes.
    public func bar(atQuarters q: Double) -> PlayedBar? {
        played.isEmpty ? nil : played[index(atQuarters: q)]
    }

    /// Which played bar a position in quarter notes falls in.
    public func index(atQuarters q: Double) -> Int {
        guard !played.isEmpty else { return 0 }
        var lo = 0, hi = played.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if played[mid].start <= q { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Bar indices in the order they are played, following the enabled repeats and jumps.
    static func playingOrder(score: ScoreData, setup: Setup) -> [Int] {
        let repeats = score.repeats.indices
            .map { (repeat: score.repeats[$0], enabled: setup.repeatsEnabled.indices.contains($0) ? setup.repeatsEnabled[$0] : true) }
            .sorted { $0.repeat.start < $1.repeat.start }
        let jumps = score.jumps.indices
            .filter { setup.jumpsEnabled.indices.contains($0) ? setup.jumpsEnabled[$0] : true }
            .map { score.jumps[$0] }
            .sorted { $0.at < $1.at }

        func resume(_ r: ScoreData.Repeat) -> Int {
            (r.endings.compactMap { $0.last }.max() ?? r.end) + 1
        }
        func bodyEnd(_ r: ScoreData.Repeat) -> Int {
            // The body runs up to the bar before the first ending, or to the repeat sign when there are none
            (r.endings.first?[0] ?? (r.end + 1)) - 1
        }
        func ending(_ r: ScoreData.Repeat, pass: Int) -> [Int]? {
            r.endings.isEmpty ? nil : r.endings[min(pass, r.endings.count) - 1]
        }
        func section(_ first: Int, _ last: Int, takeRepeats: Bool) -> [Int] {
            var order: [Int] = []
            var i = first
            for (r, enabled) in repeats where r.start >= first && resume(r) - 1 <= last {
                order += Array(i..<max(i, r.start))
                let passes = enabled && takeRepeats ? Array(1...max(r.times, 1)) : [max(r.times, 1)]
                for pass in passes {
                    order += Array(r.start...bodyEnd(r))
                    if let e = ending(r, pass: pass) { order += Array(e[0]...e[1]) }
                }
                i = resume(r)
            }
            if i <= last { order += Array(i...last) }
            return order
        }

        let lastBar = score.bars.count - 1
        // A jump belongs to the movement it is written in, and says nothing about the rest of the
        // work. A Menuetto's D.C. goes back to the Menuetto's first bar rather than the sonata's,
        // it ends at the Menuetto's last bar, and the Finale is still to be played after it.
        // Reading the marks against the whole score instead ended the work at the Fine, which
        // dropped every movement that came after. Each movement takes its own first enabled jump:
        // taking only the work's first left a second Menuetto's D.C. unplayed.
        var order: [Int] = []
        var next = 0  // the first bar not yet in the order
        for jump in jumps where jump.at >= next {
            let movement = score.bars(ofPart: score.part(ofBar: jump.at))
            let movementEnd = min(movement.upperBound - 1, lastBar)
            func inMovement(_ bar: Int?) -> Int? { bar.flatMap { movement.contains($0) ? $0 : nil } }
            let target = jump.kind == "D.C."
                ? movement.lowerBound
                : (inMovement(jump.target) ?? movement.lowerBound)
            order += section(next, jump.at, takeRepeats: true)
            if let toCoda = inMovement(jump.toCoda), let coda = inMovement(jump.coda) {
                order += section(target, toCoda, takeRepeats: setup.repeatsAfterJump)
                order += section(coda, movementEnd, takeRepeats: setup.repeatsAfterJump)
            } else {
                order += section(target, inMovement(jump.fine) ?? movementEnd,
                                 takeRepeats: setup.repeatsAfterJump)
            }
            // Whatever the jump did, it did inside its own movement; the work carries on from the next
            next = movementEnd + 1
        }
        if next <= lastBar { order += section(next, lastBar, takeRepeats: true) }
        return order
    }
}
