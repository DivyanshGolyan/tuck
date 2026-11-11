import XCTest
@testable import TuckCore

final class RecoveryTests: XCTestCase {
    func testWorkIssueSeparatesRecoveryPolicyFromMessage() {
        let retry = WorkIssue(recovery: .retry, message: "AX service temporarily busy")
        XCTAssertEqual(retry, WorkIssue(recovery: .retry, message: "AX service temporarily busy"))
        XCTAssertNotEqual(retry, WorkIssue(recovery: .awaitChange, message: retry.message))
        XCTAssertNotEqual(retry, WorkIssue(recovery: .retry, message: "Different"))
        XCTAssertEqual(Recovery.retry.rawValue, "retry")
        XCTAssertEqual(Recovery.awaitChange.rawValue, "awaitChange")
        XCTAssertEqual(Recovery.discard.rawValue, "discard")
    }

    func testBackoffExactSequenceCapResetAndValueIsolation() {
        var backoff = RetryBackoff()
        XCTAssertEqual((0..<6).map { _ in backoff.nextDelay() }, [0.25, 0.75, 2, 5, 15, 30])
        for _ in 0..<10_000 { XCTAssertEqual(backoff.nextDelay(), 30) }
        backoff.reset()
        XCTAssertEqual(backoff, RetryBackoff())
        var copy = backoff
        XCTAssertEqual(copy.nextDelay(), 0.25)
        XCTAssertEqual(copy.nextDelay(), 0.75)
        XCTAssertEqual(backoff.nextDelay(), 0.25)
        // Reading/holding these values has no scheduler or work-gate effects.
        XCTAssertEqual(LatestWork(), LatestWork())
    }

    func testIdleGateStartsNoWorkUntilRequested() {
        var work = LatestWork()
        XCTAssertEqual(work.generation, 0)
        XCTAssertNil(work.running)
        XCTAssertNil(work.applied)
        XCTAssertFalse(work.pending)
        XCTAssertNil(work.begin())
        work.finish(token: 42, applied: true)
        XCTAssertEqual(work, LatestWork())
    }

    func testTenThousandEventsCoalesceToLatestPendingIntent() {
        var work = LatestWork()
        work.request()
        let first = work.begin()!
        for _ in 0..<10_000 {
            work.request()
            XCTAssertEqual(work.running, first)
            XCTAssertTrue(work.pending)
            XCTAssertNil(work.begin())
        }
        XCTAssertEqual(work.generation, 10_001)
        XCTAssertFalse(work.isCurrent(token: first))
        work.finish(token: first, applied: true)
        XCTAssertNil(work.running)
        XCTAssertNil(work.applied)
        XCTAssertTrue(work.pending)
        let latest = work.begin()!
        XCTAssertEqual(latest, 2)
        XCTAssertTrue(work.isCurrent(token: latest))
        XCTAssertFalse(work.pending)
        work.finish(token: latest, applied: true)
        XCTAssertEqual(work.applied, 10_001)
        XCTAssertNil(work.running)
        XCTAssertFalse(work.pending)
        XCTAssertNil(work.begin())
    }

    func testStaleCompletionCannotReleaseNewerGeneration() {
        var work = LatestWork()
        work.request()
        let old = work.begin()!
        work.request()
        work.finish(token: old, applied: false)
        let latest = work.begin()!
        let before = work
        work.finish(token: old, applied: true)
        XCTAssertEqual(work, before)
        XCTAssertTrue(work.isCurrent(token: latest))
        work.finish(token: latest, applied: true)
        XCTAssertEqual(work.applied, work.generation)
        XCTAssertFalse(work.isCurrent(token: latest))
        work.request()
        XCTAssertFalse(work.isCurrent(token: latest))
        XCTAssertEqual(work.applied, 2)
    }

    func testCancellationReleasesOnlyRunningReservationAndPreservesNewIntent() {
        var work = LatestWork()
        work.request()
        let cancelled = work.begin()!
        work.request()
        work.finish(token: cancelled, applied: false)
        XCTAssertNil(work.applied)
        XCTAssertNil(work.running)
        XCTAssertTrue(work.pending)
        let next = work.begin()!
        work.finish(token: next, applied: false)
        XCTAssertNil(work.applied)
        XCTAssertNil(work.running)
        XCTAssertFalse(work.pending)
        XCTAssertNil(work.begin())
    }

    func testRetryDefersWithoutInventingAnExternalGeneration() {
        var work = LatestWork()
        work.request()
        let original = work.begin()!
        work.deferPending()
        XCTAssertEqual(work.generation, original)
        XCTAssertNil(work.begin())
        work.finish(token: original, applied: false)
        let retry = work.begin()!
        XCTAssertNotEqual(retry, original)
        XCTAssertFalse(work.isCurrent(token: original))
        XCTAssertTrue(work.isCurrent(token: retry))
        let beforeDuplicateCompletion = work
        work.finish(token: original, applied: true)
        XCTAssertEqual(work, beforeDuplicateCompletion)
        work.finish(token: retry, applied: true)
        XCTAssertEqual(work.applied, original)
        XCTAssertFalse(work.pending)
        XCTAssertNil(work.begin())
    }

    func testAwaitChangeAbandonsPendingWithoutCancellingRunningWork() {
        var work = LatestWork()
        work.request()
        let running = work.begin()!
        work.request()
        work.abandonPending()
        XCTAssertEqual(work.running, running)
        XCTAssertFalse(work.pending)
        work.finish(token: running, applied: false)
        XCTAssertNil(work.begin())
        work.deferPending()
        work.abandonPending()
        XCTAssertNil(work.begin())
        work.request()
        XCTAssertNotNil(work.begin())
    }

    func testGateIsValueStateNotAScheduler() {
        var work = LatestWork()
        work.request()
        var copy = work
        let token = copy.begin()!
        copy.finish(token: token, applied: true)
        XCTAssertNil(work.running)
        XCTAssertNil(work.applied)
        XCTAssertTrue(work.pending)
        XCTAssertEqual(work.generation, 1)
    }
}
