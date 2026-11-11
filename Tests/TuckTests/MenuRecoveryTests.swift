import ApplicationServices
import Darwin
import Foundation
import XCTest
import TuckCore
@testable import Tuck

// Reconstructed on 2026-11-11 from the original test names and the code under
// test, after the original file was deleted by mistake. Every read is injected:
// no test contacts another app or needs Accessibility consent.
final class MenuRecoveryTests: XCTestCase {
    private func element(_ pid: pid_t = 4242) -> AXUIElement { AXUIElementCreateApplication(pid) }
    private func size(_ width: CGFloat, _ height: CGFloat) -> CFTypeRef {
        var value = CGSize(width: width, height: height)
        return AXValueCreate(.cgSize, &value)!
    }
    private func point(_ x: CGFloat, _ y: CGFloat) -> CFTypeRef {
        var value = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &value)!
    }
    private func reader(pass: AXReadBudget = AXReadBudget(), role: (AXError, CFTypeRef?) = (.success, kAXMenuRole as CFString),
                        size: (AXError, CFTypeRef?), seen: ((String) -> Void)? = nil) -> AXRead {
        AXRead(pass: pass, setTimeout: { _, _ in .success }, copyAttribute: { _, attribute in
            seen?(attribute)
            return attribute == kAXRoleAttribute ? role : size
        })
    }
    private func ledger(_ registrations: [(pid_t, String)] = [(1, "a")]) -> MenuLedger {
        var ledger = MenuLedger()
        for (pid, incarnation) in registrations { ledger.register(pid: pid, incarnation: incarnation) }
        return ledger
    }

    // MARK: Presence evidence

    func testExactSuccessfulZeroSizeRetiresMenu() {
        let presence = MenuPresenceReader.presence(of: element(), read: reader(size: (.success, size(0, 0))))
        XCTAssertEqual(presence, .closed("zero-size"))
    }

    func testPositiveSizeRetainsMenu() {
        let presence = MenuPresenceReader.presence(of: element(), read: reader(size: (.success, size(180, 240))))
        XCTAssertEqual(presence, .open)
        XCTAssertEqual(presence.reason, "positive-size")
    }

    func testEmptyChildrenAreNeverUsedAsClosureEvidence() {
        var attributes: [String] = []
        let read = reader(size: (.success, size(180, 240))) { attributes.append($0) }
        XCTAssertEqual(MenuPresenceReader.presence(of: element(), read: read), .open)
        XCTAssertFalse(attributes.contains(kAXChildrenAttribute))
        XCTAssertEqual(attributes, [kAXRoleAttribute, kAXSizeAttribute])
    }

    func testFailuresAndMissingSizeRemainUnknown() {
        let menu = element()
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(role: (.cannotComplete, nil), size: (.success, size(0, 0)))),
                       .unknown("ax-\(AXError.cannotComplete.rawValue)"))
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(role: (.success, "AXApplication" as CFString), size: (.success, size(0, 0)))),
                       .unknown("not-menu"))
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(size: (.success, nil))), .unknown("missing-size"))
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(size: (.noValue, nil))),
                       .unknown("ax-\(AXError.noValue.rawValue)"))
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(size: (.attributeUnsupported, nil))),
                       .unknown("ax-\(AXError.attributeUnsupported.rawValue)"))
    }

    func testMalformedNegativeNonfiniteAndDegenerateSizesRemainUnknown() {
        let menu = element()
        func presence(_ value: CFTypeRef) -> MenuPresence {
            MenuPresenceReader.presence(of: menu, read: reader(size: (.success, value)))
        }
        XCTAssertEqual(presence("0x0" as CFString), .unknown("malformed-size"))
        XCTAssertEqual(presence(point(0, 0)), .unknown("malformed-size"))
        XCTAssertEqual(presence(size(-1, 5)), .unknown("invalid-size"))
        XCTAssertEqual(presence(size(.infinity, 5)), .unknown("invalid-size"))
        XCTAssertEqual(presence(size(.nan, .nan)), .unknown("invalid-size"))
        XCTAssertEqual(presence(size(0, 5)), .unknown("degenerate-size"))
        XCTAssertEqual(presence(size(5, 0)), .unknown("degenerate-size"))
    }

    func testInvalidExactElementCanRetireButTimeoutCannot() {
        let menu = element()
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(role: (.invalidUIElement, nil), size: (.success, size(0, 0)))),
                       .closed("invalid-element"))
        XCTAssertEqual(MenuPresenceReader.presence(of: menu, read: reader(size: (.invalidUIElement, nil))),
                       .closed("invalid-element"))
        let timedOut = MenuPresenceReader.presence(of: menu, read: reader(role: (.cannotComplete, nil), size: (.success, size(0, 0))))
        XCTAssertTrue(timedOut.isUnknown)
    }

    func testExhaustedReadBudgetRemainsUnknown() {
        var calls = 0
        let read = reader(pass: AXReadBudget(0), size: (.success, size(0, 0))) { _ in calls += 1 }
        XCTAssertEqual(MenuPresenceReader.presence(of: element(), read: read), .unknown("read-budget"))
        XCTAssertEqual(calls, 0, "No IPC after budget")
    }

    func testPresenceDeadlineDoesNotTurnTimeoutIntoClosure() {
        var now: TimeInterval = 100
        let budget = AXReadBudget(64, duration: 1.2, now: { now })
        var calls = 0
        let read = AXRead(pass: budget, setTimeout: { _, _ in .success }, copyAttribute: { _, attribute in
            calls += 1
            now += 5
            return attribute == kAXRoleAttribute ? (.success, kAXMenuRole as CFString) : (.success, self.size(0, 0))
        })
        XCTAssertEqual(MenuPresenceReader.presence(of: element(), read: read), .unknown("read-budget"))
        XCTAssertEqual(calls, 1)
    }

    // MARK: Ledger

    func testStaleResultCannotRetireDuplicateOpen() throws {
        var ledger = ledger()
        let menu = element()
        let first = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: menu))
        let second = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: menu))
        XCTAssertEqual(ledger.tokens.count, 1)
        XCTAssertFalse(ledger.apply(.closed("zero-size"), to: first))
        XCTAssertEqual(ledger.tokens.count, 1)
        XCTAssertTrue(ledger.apply(.closed("zero-size"), to: second))
        XCTAssertTrue(ledger.tokens.isEmpty)
    }

    func testStaleResultCannotRetireCloseThenReopen() throws {
        var ledger = ledger()
        let menu = element()
        let first = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: menu))
        ledger.closed(pid: 1, incarnation: "a", element: menu)
        XCTAssertTrue(ledger.tokens.isEmpty)
        let reopened = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: menu))
        XCTAssertFalse(ledger.apply(.closed("zero-size"), to: first))
        XCTAssertEqual(ledger.tokens.count, 1)
        XCTAssertFalse(ledger.apply(.open, to: reopened))
        XCTAssertFalse(ledger.apply(.unknown("ax-1"), to: reopened))
        XCTAssertEqual(ledger.tokens.count, 1)
    }

    func testRegistrationReplacementAndPIDReuseRejectOldResultsAndEvents() throws {
        var ledger = ledger()
        let menu = element()
        let old = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: menu))
        ledger.register(pid: 1, incarnation: "b")
        XCTAssertTrue(ledger.tokens.isEmpty)
        XCTAssertNil(ledger.opened(pid: 1, incarnation: "a", element: menu))
        let current = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "b", element: menu))
        XCTAssertFalse(ledger.apply(.closed("zero-size"), to: old))
        ledger.closed(pid: 1, incarnation: "a", element: menu)
        ledger.closed(pid: 1, incarnation: "a", element: menu, application: true)
        ledger.unregister(pid: 1, incarnation: "a")
        XCTAssertEqual(ledger.tokens.count, 1)
        XCTAssertTrue(ledger.apply(.closed("zero-size"), to: current))
        XCTAssertNil(ledger.opened(pid: 2, incarnation: "b", element: menu))
    }

    func testPartialRemovalKeepsOtherMenusAndProcessesLatched() throws {
        var ledger = ledger([(1, "a"), (2, "b")])
        let first = element(101), second = element(102), other = element(103)
        ledger.opened(pid: 1, incarnation: "a", element: first)
        let secondToken = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: second))
        ledger.opened(pid: 2, incarnation: "b", element: other)
        ledger.closed(pid: 1, incarnation: "a", element: first)
        XCTAssertEqual(ledger.tokens.count, 2)
        XCTAssertTrue(ledger.apply(.closed("zero-size"), to: secondToken))
        XCTAssertEqual(ledger.tokens.map(\.pid), [2])
    }

    func testApplicationCloseOnlyClearsMatchingRegistration() {
        var ledger = ledger([(1, "a"), (2, "b")])
        ledger.opened(pid: 1, incarnation: "a", element: element(101))
        ledger.opened(pid: 1, incarnation: "a", element: element(102))
        ledger.opened(pid: 2, incarnation: "b", element: element(103))
        ledger.closed(pid: 1, incarnation: "stale", element: element(1), application: true)
        XCTAssertEqual(ledger.tokens.count, 3)
        ledger.closed(pid: 1, incarnation: "a", element: element(1), application: true)
        XCTAssertEqual(ledger.tokens.map(\.pid), [2])
    }

    // MARK: Bounded validation pass

    func testInvalidElementFailureCannotRetireSiblingReference() {
        let tokens = [MenuToken(pid: 1, incarnation: "a", element: element(101), epoch: 1),
                      MenuToken(pid: 1, incarnation: "a", element: element(102), epoch: 2),
                      MenuToken(pid: 2, incarnation: "b", element: element(103), epoch: 3)]
        var readers = 0
        let checks = MenuPresenceReader.check(tokens, processExited: { _ in false }, makeRead: { budget in
            readers += 1
            return readers == 1
                ? self.reader(pass: budget, role: (.invalidUIElement, nil), size: (.success, self.size(0, 0)))
                : self.reader(pass: budget, size: (.success, self.size(0, 0)))
        })
        XCTAssertEqual(checks.map(\.presence), [.closed("invalid-element"), .unknown("earlier-read-failure"), .closed("zero-size")])
        XCTAssertEqual(readers, 2)
    }

    func testOnlyFailedESRCHProbeProvesProcessExit() {
        XCTAssertTrue(MenuPresenceReader.processHasExited(result: -1, error: ESRCH))
        XCTAssertFalse(MenuPresenceReader.processHasExited(result: 0, error: ESRCH))
        XCTAssertFalse(MenuPresenceReader.processHasExited(result: 0, error: 0))
        XCTAssertFalse(MenuPresenceReader.processHasExited(result: -1, error: EPERM))
        XCTAssertFalse(MenuPresenceReader.processHasExited(result: -1, error: EINVAL))
    }

    func testAliveReusedPIDAndPermissionErrorsStillUseConservativeAXPath() {
        let token = MenuToken(pid: 1, incarnation: "a", element: element(), epoch: 1)
        for probe in [(Int32(0), Int32(0)), (Int32(-1), EPERM)] {
            var readers = 0
            let checks = MenuPresenceReader.check([token],
                processExited: { _ in MenuPresenceReader.processHasExited(result: probe.0, error: probe.1) },
                makeRead: { budget in
                    readers += 1
                    return self.reader(pass: budget, size: (.success, self.size(120, 80)))
                })
            XCTAssertEqual(checks.map(\.presence), [.open])
            XCTAssertEqual(readers, 1)
        }
    }

    func testExitedProcessSkipsAXAndRetiresOnlyCapturedToken() throws {
        var ledger = ledger([(1, "a"), (2, "b")])
        let captured = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: element(101)))
        ledger.opened(pid: 2, incarnation: "b", element: element(102))
        let checks = MenuPresenceReader.check([captured], processExited: { $0 == 1 }, makeRead: { budget in
            XCTFail("Exited owner must not create an AX reader")
            return self.reader(pass: budget, size: (.success, self.size(1, 1)))
        })
        XCTAssertEqual(checks.map(\.presence), [.closed("process-exited")], "No AX for exited owner")
        for check in checks { ledger.apply(check.presence, to: check.token) }
        XCTAssertEqual(ledger.tokens.map(\.pid), [2])
    }

    func testProcessExitResultsCannotRetireReopenedOrReincarnatedTokens() throws {
        var ledger = ledger()
        let menu = element(101)
        let captured = try XCTUnwrap(ledger.opened(pid: 1, incarnation: "a", element: menu))
        let checks = MenuPresenceReader.check([captured], processExited: { _ in true })
        ledger.opened(pid: 1, incarnation: "a", element: menu)
        XCTAssertFalse(ledger.apply(checks[0].presence, to: checks[0].token))
        XCTAssertEqual(ledger.tokens.count, 1)
        ledger.register(pid: 1, incarnation: "b")
        ledger.opened(pid: 1, incarnation: "b", element: menu)
        XCTAssertFalse(ledger.apply(checks[0].presence, to: checks[0].token))
        XCTAssertEqual(ledger.tokens.count, 1)
    }

    func testProcessProbeIsCachedPerPIDWithinPassIncludingAliveResults() {
        let tokens = [MenuToken(pid: 1, incarnation: "a", element: element(101), epoch: 1),
                      MenuToken(pid: 1, incarnation: "a", element: element(102), epoch: 2),
                      MenuToken(pid: 2, incarnation: "b", element: element(103), epoch: 3),
                      MenuToken(pid: 2, incarnation: "b", element: element(104), epoch: 4)]
        var probes: [pid_t] = []
        let checks = MenuPresenceReader.check(tokens, processExited: { pid in probes.append(pid); return pid == 2 },
            makeRead: { self.reader(pass: $0, size: (.success, self.size(10, 10))) })
        XCTAssertEqual(probes, [1, 2])
        XCTAssertEqual(checks.map(\.presence), [.open, .open, .closed("process-exited"), .closed("process-exited")])
    }

    // MARK: Recovery loop

    @MainActor private final class Probe {
        var validations = 0
        var active = 0
        var maxActive = 0
        var delays: [TimeInterval] = []
        var held: [CheckedContinuation<Void, Never>] = []
    }

    @MainActor private func openLedger() -> MenuLedger {
        var ledger = MenuLedger()
        ledger.register(pid: 1, incarnation: "a")
        ledger.opened(pid: 1, incarnation: "a", element: AXUIElementCreateApplication(4242))
        return ledger
    }

    @MainActor private func settle(_ turns: Int = 50) async {
        for _ in 0..<turns { await Task.yield() }
    }

    @MainActor func testRecoveryDoesNoIdleWorkAndStopsAfterLastMenuRetires() async {
        let probe = Probe()
        let cleared = expectation(description: "Menu blocker cleared")
        let observers = IconObservers(ledger: openLedger(), terminationCenter: nil,
            validateMenus: { tokens in
                probe.validations += 1
                return tokens.map { MenuCheck(token: $0, presence: .closed("zero-size")) }
            },
            recoverySleep: { delay in probe.delays.append(delay); await Task.yield() })
        observers.menuChanged = { open in if !open { cleared.fulfill() } }
        XCTAssertTrue(observers.isMenuOpen)
        await settle()
        XCTAssertEqual(probe.validations, 0)
        XCTAssertTrue(probe.delays.isEmpty)
        observers.setMenuRecoveryNeeded(true)
        await fulfillment(of: [cleared], timeout: 5)
        XCTAssertFalse(observers.isMenuOpen)
        XCTAssertEqual(observers.menuCount, 0)
        XCTAssertEqual(probe.validations, 1)
        await settle()
        XCTAssertEqual(probe.validations, 1)
        XCTAssertEqual(probe.delays, [0.25])
    }

    @MainActor func testUnknownRetriesIndefinitelyWithCappedBackoffUntilSuspended() async {
        let probe = Probe()
        let eight = expectation(description: "Eight attempts, no age-based retirement")
        let observers = IconObservers(ledger: openLedger(), terminationCenter: nil,
            validateMenus: { tokens in
                probe.validations += 1
                if probe.validations == 8 { eight.fulfill() }
                return tokens.map { MenuCheck(token: $0, presence: .unknown("ax-\(AXError.cannotComplete.rawValue)")) }
            },
            recoverySleep: { delay in probe.delays.append(delay); await Task.yield() })
        observers.setMenuRecoveryNeeded(true)
        await fulfillment(of: [eight], timeout: 5)
        XCTAssertTrue(observers.isMenuOpen)
        XCTAssertEqual(Array(probe.delays.prefix(8)), [0.25, 0.75, 2, 2, 2, 2, 2, 2])
        XCTAssertEqual(observers.lastMenuCheckResult, "closed=0 open=0 unknown=1")
        observers.setMenuRecoveryNeeded(false)
        await settle()
        let stopped = probe.validations
        await settle()
        XCTAssertEqual(probe.validations, stopped)
        XCTAssertTrue(observers.isMenuOpen)
    }

    @MainActor func testCancelledInFlightValidationKeepsSingleFlightAndCannotApplyOrClobberReplacement() async {
        let probe = Probe()
        let first = expectation(description: "First validation running")
        let replacement = expectation(description: "Replacement validation running")
        let cleared = expectation(description: "Menu blocker cleared")
        let observers = IconObservers(ledger: openLedger(), terminationCenter: nil,
            validateMenus: { tokens in
                probe.validations += 1; probe.active += 1
                probe.maxActive = max(probe.maxActive, probe.active)
                if probe.validations == 1 { first.fulfill() }
                if probe.validations == 2 { replacement.fulfill() }
                await withCheckedContinuation { probe.held.append($0) }
                probe.active -= 1
                return tokens.map { MenuCheck(token: $0, presence: .closed("zero-size")) }
            },
            recoverySleep: { _ in await Task.yield() })
        observers.menuChanged = { open in if !open { cleared.fulfill() } }
        observers.setMenuRecoveryNeeded(true)
        await fulfillment(of: [first], timeout: 5)
        observers.setMenuRecoveryNeeded(false)
        observers.setMenuRecoveryNeeded(true)
        await settle()
        XCTAssertEqual(probe.validations, 1)
        probe.held.removeFirst().resume()
        await fulfillment(of: [replacement], timeout: 5)
        XCTAssertTrue(observers.isMenuOpen)
        XCTAssertEqual(observers.menuChecks, 0)
        XCTAssertEqual(probe.maxActive, 1)
        probe.held.removeFirst().resume()
        await fulfillment(of: [cleared], timeout: 5)
        XCTAssertFalse(observers.isMenuOpen)
        XCTAssertEqual(observers.menuChecks, 1)
        XCTAssertEqual(probe.validations, 2)
    }

    @MainActor func testSuspendingDuringBackoffPreventsValidation() async {
        let probe = Probe()
        let scheduled = expectation(description: "Backoff scheduled")
        let observers = IconObservers(ledger: openLedger(), terminationCenter: nil,
            validateMenus: { tokens in
                probe.validations += 1
                return tokens.map { MenuCheck(token: $0, presence: .closed("zero-size")) }
            },
            recoverySleep: { delay in
                probe.delays.append(delay)
                if probe.delays.count == 1 { scheduled.fulfill() }
                await withCheckedContinuation { probe.held.append($0) }
            })
        observers.setMenuRecoveryNeeded(true)
        await fulfillment(of: [scheduled], timeout: 5)
        observers.setMenuRecoveryNeeded(false)
        probe.held.removeFirst().resume()
        await settle()
        XCTAssertEqual(probe.validations, 0)
        XCTAssertTrue(observers.isMenuOpen)
        XCTAssertEqual(probe.delays, [0.25])
    }
}
