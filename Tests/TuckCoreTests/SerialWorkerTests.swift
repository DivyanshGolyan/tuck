import Foundation
import XCTest
@testable import TuckCore

final class SerialWorkerTests: XCTestCase {
    @MainActor func testBlockingCallDoesNotBlockMainAndReturnsOffMainValue() async throws {
        let worker = SerialWorker(label: "test.worker.main")
        let started = expectation(description: "worker started")
        let mainAdvanced = expectation(description: "main still responds")
        let task = Task { try await worker.run {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.15)
            return 42
        } }
        await fulfillment(of: [started], timeout: 2)
        DispatchQueue.main.async { mainAdvanced.fulfill() }
        await fulfillment(of: [mainAdvanced], timeout: 1)
        let result = try await task.value
        XCTAssertEqual(result, 42)
    }

    func testSerialExecutionAndCancellationDiscardDoNotCreateReplacementConcurrency() async throws {
        let worker = SerialWorker(label: "test.worker.serial")
        let started = expectation(description: "started")
        let lock = NSLock()
        var active = 0
        var maximum = 0
        let first = Task { try await worker.run {
            lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.15)
            lock.lock(); active -= 1; lock.unlock()
            return 1
        } }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        let second = Task { try await worker.run {
            lock.lock(); active += 1; maximum = max(maximum, active); active -= 1; lock.unlock()
            return 2
        } }
        do { _ = try await first.value; XCTFail("Cancelled result must not be delivered") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value
        XCTAssertEqual(result, 2)
        XCTAssertEqual(maximum, 1)
    }

    func testThrownFailurePropagatesAndNextJobRuns() async throws {
        enum Failure: Error { case expected }
        let worker = SerialWorker(label: "test.worker.errors")
        do { let _: Int = try await worker.run { throw Failure.expected }; XCTFail("Expected error") }
        catch { XCTAssertTrue(error is Failure) }
        let result = try await worker.run { 9 }
        XCTAssertEqual(result, 9)
    }
}
