import XCTest
@testable import SoloPianoTracker

/// A score of empty bars a quarter note long, numbered from 1 in each part: enough for the order.
func emptyScore(parts: [Int], jumps: [ScoreData.Jump] = []) -> ScoreData {
    var bars: [ScoreData.Bar] = [], firsts: [Int] = []
    for count in parts {
        firsts.append(bars.count)
        for n in 1...count {
            bars.append(.init(label: "\(n)", number: n, start: Double(bars.count), duration: 1))
        }
    }
    let named = parts.count > 1 ? firsts.enumerated().map { ScoreData.Part(name: "\($0 + 1)", firstBar: $1, tempo: nil) } : []
    return ScoreData(title: "", composer: "", movements: parts.count, parts: named, bars: bars,
                     repeats: [], jumps: jumps, tempos: [], notes: [])
}

func daCapo(at bar: Int, fine: Int?) -> ScoreData.Jump {
    .init(kind: "D.C.", at: bar, target: 0, fine: fine, toCoda: nil, coda: nil)
}

final class PlanTests: XCTestCase {
    /// Two minuets, each D.C. al Fine at its second bar. Only the work's first jump was taken, so the
    /// second minuet ended without going back.
    func testEveryMovementTakesItsOwnJump() {
        let score = emptyScore(parts: [4, 4], jumps: [daCapo(at: 3, fine: 1), daCapo(at: 7, fine: 5)])
        XCTAssertEqual(Plan(score: score, setup: .defaults(for: score)).played.map(\.bar),
                       [0, 1, 2, 3, 0, 1, 4, 5, 6, 7, 4, 5])

        var setup = Setup.defaults(for: score)
        setup.jumpsEnabled = [false, true]
        XCTAssertEqual(Plan(score: score, setup: setup).played.map(\.bar), [0, 1, 2, 3, 4, 5, 6, 7, 4, 5])
    }

    /// A second jump in a movement already written out is not taken, as before.
    func testOneJumpPerMovement() {
        let score = emptyScore(parts: [4, 2], jumps: [daCapo(at: 2, fine: 0), daCapo(at: 3, fine: nil)])
        XCTAssertEqual(Plan(score: score, setup: .defaults(for: score)).played.map(\.bar), [0, 1, 2, 0, 4, 5])
    }
}
