import ApplicationServices
import Foundation
import XCTest
@testable import TuckCore
@testable import Tuck

final class AXReadTests: XCTestCase {
    // Creating references is local. Every read and timeout below is injected:
    // these tests neither contact another app nor require Accessibility consent.
    private func element(_ pid: pid_t = 12345) -> AXUIElement { AXUIElementCreateApplication(pid) }

    func testIncarnationIsStableForARunningProcessWithoutLaunchDate() {
        let own = getpid()
        let first = AppProcess.incarnation(pid: own, launchDate: nil)
        XCTAssertEqual(first, AppProcess.incarnation(pid: own, launchDate: nil))
        XCTAssertNotEqual(first, AppProcess.incarnation(pid: 1, launchDate: nil))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(AppProcess.incarnation(pid: own, launchDate: date), String(date.timeIntervalSince1970))
    }

    func testTypedRecoveryClassification() {
        for code in [AXError.cannotComplete, .invalidUIElement, .failure] {
            XCTAssertEqual(AXReadFailure(code, operation: "test").issue.recovery, .retry)
        }
        for code in [AXError.apiDisabled, .attributeUnsupported, .actionUnsupported, .notificationUnsupported,
                     .notImplemented, .noValue, .illegalArgument, .notEnoughPrecision] {
            XCTAssertEqual(AXReadFailure(code, operation: "test").issue.recovery, .awaitChange)
        }
        XCTAssertEqual(AXReadFailure("Read budget exhausted").issue.recovery, .retry)
    }

    func testFirstFailureSkipsAllFurtherCallsForProcess() {
        var reads = 0; var timeouts = 0
        let read = AXRead(setTimeout: { _, _ in timeouts += 1; return .success }, copyAttribute: { _, _ in
            reads += 1; return (.cannotComplete, nil)
        })
        for _ in 0..<4 {
            XCTAssertThrowsError(try read.value(element(), "AXTitle")) { error in
                XCTAssertEqual((error as? AXReadFailure)?.code, .cannotComplete)
            }
        }
        XCTAssertEqual(reads, 1); XCTAssertEqual(timeouts, 1)
    }

    func testOptionalUnsupportedAndNoValueAreNotTransportFailures() throws {
        var calls = 0
        let read = AXRead(setTimeout: { _, _ in .success }, copyAttribute: { _, attribute in
            calls += 1; return (attribute == "missing" ? .noValue : .attributeUnsupported, nil)
        })
        XCTAssertNil(try read.value(element(), "missing", optional: false))
        XCTAssertNil(try read.value(element(), "optional"))
        XCTAssertThrowsError(try read.value(element(), "required", optional: false)) { error in
            XCTAssertEqual((error as? AXReadFailure)?.issue.recovery, .awaitChange)
        }
        XCTAssertEqual(calls, 3)
    }

    func testTimeoutIsSetOnEveryReadObjectBeforeRead() throws {
        var operations: [String] = []
        let read = AXRead(setTimeout: { _, timeout in
            XCTAssertEqual(timeout, AXRead.messagingTimeout); operations.append("timeout"); return .success
        }, copyAttribute: { _, _ in operations.append("read"); return (.success, "value" as CFString) })
        _ = try read.value(element(12345), "AXTitle")
        _ = try read.value(element(12346), "AXTitle")
        XCTAssertEqual(operations, ["timeout", "read", "timeout", "read"])
    }

    func testFailedTimeoutSetupDoesNotSendAttributeRead() {
        var reads = 0
        let read = AXRead(setTimeout: { _, _ in .invalidUIElement }, copyAttribute: { _, _ in
            reads += 1; return (.success, nil)
        })
        XCTAssertThrowsError(try read.value(element(), "AXTitle"))
        XCTAssertEqual(reads, 0)
    }

    func testProcessCallLimitStopsBeforeNextIPC() throws {
        var calls = 0
        let read = AXRead(limit: 1, setTimeout: { _, _ in .success }, copyAttribute: { _, _ in
            calls += 1; return (.success, nil)
        })
        _ = try read.value(element(), "AXTitle")
        XCTAssertThrowsError(try read.value(element(), "AXTitle"))
        XCTAssertEqual(calls, 1)
    }

    func testPassDeadlineIsCooperativeNotCancellationOfInFlightRead() throws {
        var clock: TimeInterval = 0; var calls = 0
        let pass = AXReadBudget(10, duration: 2, now: { clock })
        let read = AXRead(pass: pass, processDuration: 100, setTimeout: { _, _ in .success }, copyAttribute: { _, _ in
            calls += 1; clock = 3; return (.success, "late value" as CFString)
        })
        XCTAssertEqual(try read.value(element(), "AXTitle") as? String, "late value")
        XCTAssertThrowsError(try read.value(element(), "AXTitle"))
        XCTAssertEqual(calls, 1)
    }

    func testProcessDeadlineStopsBeforeNextIPC() throws {
        var clock: TimeInterval = 0; var calls = 0
        let pass = AXReadBudget(10, duration: 100, now: { clock })
        let read = AXRead(pass: pass, processDuration: 0.8, setTimeout: { _, _ in .success }, copyAttribute: { _, _ in
            calls += 1; clock = 1; return (.success, nil)
        })
        _ = try read.value(element(), "AXTitle")
        XCTAssertThrowsError(try read.value(element(), "AXTitle"))
        XCTAssertEqual(calls, 1)
    }

    func testPassCallBudgetIsSharedAcrossReaders() throws {
        let pass = AXReadBudget(1)
        var calls = 0
        func reader() -> AXRead {
            AXRead(pass: pass, setTimeout: { _, _ in .success }, copyAttribute: { _, _ in
                calls += 1; return (.success, nil)
            })
        }
        _ = try reader().value(element(), "AXTitle")
        XCTAssertThrowsError(try reader().value(element(), "AXTitle"))
        XCTAssertEqual(calls, 1)
    }

    func testIncompleteSnapshotsNeverAuthorizeCachedIdentityAsComplete() {
        let own: Int32 = 900
        let app = AppProcess(pid: 12345, bundle: "local.test", name: "Test", incarnation: "1")
        let icon = StatusWindow(key: WindowKey(pid: app.pid, number: 42), frame: CGRect(x: 100, y: 0, width: 30, height: 24), onScreen: true)
        let list = WindowList(skippingMalformed: [
            icon,
            StatusWindow(key: WindowKey(pid: own, number: 1), frame: CGRect(x: 200, y: 0, width: 4, height: 24),
                         onScreen: true, title: OwnItem.separator.title),
            StatusWindow(key: WindowKey(pid: own, number: 2), frame: CGRect(x: 220, y: 0, width: 20, height: 24),
                         onScreen: true, title: OwnItem.control.title)])
        let rows = MenuRows(list, ownPID: own, displays: [])
        let cached = AppReading.BoundIcon(identity: IconIdentity(bundle: app.bundle, item: "cached"), label: "Cached",
                                          movable: true, window: icon.key, element: 0)
        let clean = MenuBar.observe(MenuBar.none.survey(rows, running: [app]),
                                    readings: [AppReading(app: app, outcome: .clean([cached]))])
        XCTAssertTrue(clean.complete)
        XCTAssertTrue(clean.reusable)

        let busy = MenuBar.observe(clean.survey(rows, running: [app]),
                                   readings: [.failed(app, WorkIssue(recovery: .retry, message: "Target busy"))])
        XCTAssertEqual(busy.roles.map(\.identity.key), ["local.test::cached"])
        XCTAssertFalse(busy.complete)
        XCTAssertFalse(busy.reusable)
        XCTAssertEqual(busy.survey(rows, running: [app]).stale, [app.pid: "previous read incomplete"])

        let unread = MenuBar.observe(busy.survey(rows, running: [app]), readings: [])
        XCTAssertEqual(unread.roles.map(\.identity.key), ["local.test::cached"])
        XCTAssertFalse(unread.complete)
        XCTAssertEqual(unread.issues, [WorkIssue(recovery: .retry, message: "Test: not read (previous read incomplete)")])
    }

    @MainActor
    func testBusyWorkerLeavesMainActorResponsive() async throws {
        let started = expectation(description: "Worker started")
        let heartbeat = expectation(description: "Main actor remains responsive")
        let release = DispatchSemaphore(value: 0)
        let worker = SerialWorker(label: "local.tuck.tests.busy-read")
        let result = Task {
            try await worker.run {
                started.fulfill()
                // Model one synchronous busy provider, not actual AX or GUI work.
                return release.wait(timeout: .now() + 5) == .success
            }
        }
        defer { release.signal() }
        await fulfillment(of: [started], timeout: 2)
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 2)
        release.signal()
        let unblocked = try await result.value
        XCTAssertTrue(unblocked)
    }
}
