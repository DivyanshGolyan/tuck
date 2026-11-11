import XCTest
@testable import TuckCore

final class MoveHistoryTests: XCTestCase {
    let before = ["b", OwnItem.separator.id, "a"]
    let after = ["a", "b", OwnItem.separator.id]

    func move(order: [String]? = nil, target: [String] = ["a", "b", OwnItem.separator.id], rows: [CGFloat] = [0],
              purpose: Purpose = .tuck) -> Move {
        Move(id: "a", label: "Alpha", before: "b", purpose: purpose,
             attempt: AttemptKey(order: order ?? before, target: target, rows: rows))
    }

    func testBeganMakesTheMovePending() {
        let history = MoveHistory().record(.began(move()))
        XCTAssertTrue(history.pending)
        XCTAssertEqual(history.phase, .pending(move(), reads: 0))
        XCTAssertNil(history.strikes)
    }

    func testChangedOrderVerifies() {
        let history = MoveHistory().record(.began(move())).observe(order: before, goalMet: false)
            .observe(order: after, goalMet: false)
        XCTAssertEqual(history, MoveHistory())
    }

    func testGoalMetVerifiesEvenWhenOrderIsUnchanged() {
        let history = MoveHistory().record(.began(move())).observe(order: before, goalMet: true)
        XCTAssertEqual(history, MoveHistory())
    }

    func testUnchangedReadsWaitThenStrike() {
        var history = MoveHistory().record(.began(move()))
        for reads in 1..<Limits.unchangedReads {
            history = history.observe(order: before, goalMet: false)
            XCTAssertEqual(history.phase, .pending(move(), reads: reads))
        }
        history = history.observe(order: before, goalMet: false)
        XCTAssertFalse(history.pending)
        XCTAssertEqual(history.strikes?.count, 1)
        XCTAssertNil(history.abandoned(move()))
        history = history.record(.began(move()))
        for _ in 0..<Limits.unchangedReads { history = history.observe(order: before, goalMet: false) }
        XCTAssertEqual(history.abandoned(move()), "Could not move Alpha; order left unchanged")
    }

    func testIdleIgnoresObservations() {
        let struck = MoveHistory().record(.refused(move(), reason: "no", permanent: false))
        XCTAssertEqual(struck.observe(order: before, goalMet: false), struck)
        XCTAssertEqual(struck.observe(order: after, goalMet: true), struck)
        XCTAssertEqual(MoveHistory().observe(order: before, goalMet: false), MoveHistory())
    }

    func testThreeReadBoundHoldsUnderManyRepeats() {
        var history = MoveHistory()
        for _ in 0..<10_000 {
            history = history.record(.began(move()))
            var reads = 0
            while history.pending {
                history = history.observe(order: before, goalMet: false)
                reads += 1
            }
            XCTAssertEqual(reads, Limits.unchangedReads)
            XCTAssertLessThanOrEqual(history.strikes?.count ?? 0, Limits.attempts)
        }
        XCTAssertEqual(history.strikes?.count, Limits.attempts)
        XCTAssertNotNil(history.abandoned(move()))
    }

    func testRefusalStrikesAndPermanentRefusalAbandonsAtOnce() {
        let once = MoveHistory().record(.refused(move(), reason: "busy", permanent: false))
        XCTAssertNil(once.abandoned(move()))
        XCTAssertEqual(once.record(.refused(move(), reason: "busy", permanent: false)).abandoned(move()), "busy")
        let permanent = MoveHistory().record(.refused(move(), reason: "Icon overflows", permanent: true))
        XCTAssertEqual(permanent.abandoned(move()), "Icon overflows")
        XCTAssertFalse(permanent.pending)
    }

    func testStrikeSlotIsReplacedByANewOrderTargetOrRows() {
        let abandoned = MoveHistory().record(.refused(move(), reason: "stuck", permanent: true))
        XCTAssertNotNil(abandoned.abandoned(move()))
        let others = [move(order: after), move(target: ["b", "a", OwnItem.separator.id]), move(rows: [0, 1080])]
        for other in others {
            XCTAssertNil(abandoned.abandoned(other))
            let replaced = abandoned.record(.refused(other, reason: "new", permanent: false))
            XCTAssertNil(replaced.abandoned(move()))
            XCTAssertNil(replaced.abandoned(other))
            XCTAssertEqual(replaced.strikes?.count, 1)
        }
    }

    func testPendingMoveSurvivesUnrelatedStrikes() {
        let history = MoveHistory().record(.began(move())).record(.refused(move(order: after), reason: "x", permanent: false))
        XCTAssertTrue(history.pending)
        XCTAssertEqual(history.observe(order: after, goalMet: false).pending, false)
    }
}
