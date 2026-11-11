import Foundation
import XCTest
@testable import TuckCore

final class SerialWorkerQueuedCancellationTests: XCTestCase {
    func testCancelledQueuedOperationIsSkippedAndDoesNotInterruptRunningCall() async throws {
        let worker = SerialWorker(label: "test.worker.queued-cancellation")
        let blockerEntered = expectation(description: "blocking operation entered")
        let blockerReleased = DispatchSemaphore(value: 0)
        let first = Task { try await worker.run {
            blockerEntered.fulfill()
            guard blockerReleased.wait(timeout: .now() + 3) == .success else {
                throw QueueTestError.blockerTimedOut
            }
            return 1
        } }
        defer { blockerReleased.signal() }
        await fulfillment(of: [blockerEntered], timeout: 2)

        let secondAttempted = expectation(description: "second task attempting worker call")
        let secondFinishedEarly = expectation(description: "queued task cannot finish before head releases")
        secondFinishedEarly.isInverted = true
        let state = InvocationCount()
        let second = Task {
            secondAttempted.fulfill()
            defer { secondFinishedEarly.fulfill() }
            return try await worker.run {
                state.record()
                return 2
            }
        }
        await fulfillment(of: [secondAttempted], timeout: 2)
        // A bounded test-only settling interval lets run enqueue before cancel.
        // The inverted expectation below detects cancellation before enqueue:
        // a pre-enqueue cancellation would finish immediately, failing the test.
        try await Task.sleep(nanoseconds: 30_000_000)
        second.cancel()
        await fulfillment(of: [secondFinishedEarly], timeout: 0.05)
        blockerReleased.signal()
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, 1)
        do {
            _ = try await second.value
            XCTFail("Cancelled queued work must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(state.count, 0)
        let subsequent = try await worker.run { 3 }
        XCTAssertEqual(subsequent, 3)
    }
}

private enum QueueTestError: Error { case blockerTimedOut }

private final class InvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
