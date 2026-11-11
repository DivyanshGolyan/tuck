import XCTest
@testable import TuckCore

final class MoveVerificationTests: XCTestCase {
    func testSuccessfulButDelayedObservationWaitsTwiceThenVerifies() {
        let before = ["a", "separator", "b"]
        var verification = MoveVerification(itemID: "b", before: before)
        XCTAssertEqual(verification.observe(order: before, goalSatisfied: false), .wait)
        XCTAssertEqual(verification.unchangedReads, 1)
        XCTAssertEqual(verification.observe(order: before, goalSatisfied: false), .wait)
        XCTAssertEqual(verification.unchangedReads, 2)
        XCTAssertEqual(verification.observe(order: ["b", "a", "separator"], goalSatisfied: false), .verified)
        XCTAssertEqual(verification.unchangedReads, 2)
        XCTAssertEqual(verification.itemID, "b")
        XCTAssertEqual(verification.before, before)
    }

    func testThreeUnchangedReadsAwaitExternalChangeAndCounterIsBounded() {
        var verification = MoveVerification(itemID: "a", before: ["a", "b"])
        XCTAssertEqual(verification.observe(order: ["a", "b"], goalSatisfied: false), .wait)
        XCTAssertEqual(verification.observe(order: ["a", "b"], goalSatisfied: false), .wait)
        XCTAssertEqual(verification.observe(order: ["a", "b"], goalSatisfied: false), .awaitChange)
        for _ in 0..<10_000 {
            XCTAssertEqual(verification.observe(order: ["a", "b"], goalSatisfied: false), .awaitChange)
        }
        XCTAssertEqual(verification.unchangedReads, 3)
        XCTAssertEqual(verification.observe(order: ["b", "a"], goalSatisfied: false), .verified)
    }

    func testSatisfiedGoalVerifiesEvenIfObservationUnchanged() {
        var verification = MoveVerification(itemID: "a", before: ["a"])
        XCTAssertEqual(verification.observe(order: ["a"], goalSatisfied: true), .verified)
        XCTAssertEqual(verification.unchangedReads, 0)
    }

    func testVerificationStateIsIndependentValueAndNewFactResetsReads() {
        let original = MoveVerification(itemID: "a", before: [])
        var copy = original
        XCTAssertEqual(copy.observe(order: [], goalSatisfied: false), .wait)
        XCTAssertEqual(original.unchangedReads, 0)
        XCTAssertEqual(MoveVerification(itemID: "a", before: ["a"]).unchangedReads, 0)
    }
}

final class MoveAttemptsTests: XCTestCase {
    func testOrderIsAbandonedOnlyAfterLimitFailuresOfThatExactOrder() {
        var attempts = MoveAttempts()
        XCTAssertNil(attempts.abandoned(order: ["a", "b"]))
        attempts.fail(order: ["a", "b"], reason: "first")
        XCTAssertNil(attempts.abandoned(order: ["a", "b"]))
        attempts.fail(order: ["a", "b"], reason: "second")
        XCTAssertEqual(attempts.abandoned(order: ["a", "b"]), "second")
        XCTAssertNil(attempts.abandoned(order: ["b", "a"]))
    }

    func testDifferentOrderStartsNewCountAndResetForgets() {
        var attempts = MoveAttempts()
        attempts.fail(order: ["a", "b"], reason: "x")
        attempts.fail(order: ["b", "a"], reason: "y")
        XCTAssertNil(attempts.abandoned(order: ["b", "a"]))
        attempts.fail(order: ["b", "a"], reason: "y")
        XCTAssertNotNil(attempts.abandoned(order: ["b", "a"]))
        attempts.reset()
        XCTAssertNil(attempts.abandoned(order: ["b", "a"]))
    }

    func testFinalFailureAbandonsImmediately() {
        var attempts = MoveAttempts()
        attempts.fail(order: ["a"], reason: "overflow", final: true)
        XCTAssertEqual(attempts.abandoned(order: ["a"]), "overflow")
    }
}
