import CoreGraphics
import XCTest
@testable import TuckCore

/// The post-apply audit as the core sees it: `auditTarget` picks a carried app, and a
/// reading of an app the survey did not name is folded in by `observe`.
final class AuditTests: XCTestCase {
    let sep = OwnItem.separator.id
    let ctl = OwnItem.control.id

    private func twoRows(_ order: [String]) -> ToyBar {
        ToyBar(order: order, displays: [ToyBar.display(y: 0, width: 1512), ToyBar.display(y: -1117, width: 1920)])
    }

    func testTargetRotatesOverReusableBindingsInPIDOrder() {
        let toy = twoRows(["a0", sep, "a1", "a2", ctl])
        XCTAssertNil(MenuBar.none.auditTarget)
        var bar = toy.gather(after: .none)
        XCTAssertTrue(bar.reusable)
        var seen: [Int32] = []
        for _ in 0..<5 {
            let target = try! XCTUnwrap(bar.auditTarget)
            seen.append(target.pid)
            bar = toy.audit(bar)
        }
        let pids = [ToyBar.clockPID, toy.pid("a0"), toy.pid("a1"), toy.pid("a2")]
        XCTAssertEqual(seen, pids + [pids[0]])
        XCTAssertEqual(bar.auditMismatches, 0)

        // A binding that is not reusable is skipped until a clean read restores it.
        let failed = toy.audit(bar, failing: true)
        XCTAssertEqual(bar.auditTarget?.pid, toy.pid("a0"))
        XCTAssertEqual(failed.auditTarget?.pid, toy.pid("a1"))
    }

    func testAgreeingAuditChangesNothing() {
        let toy = twoRows(["a0", sep, "a1", ctl])
        let bar = toy.gather(after: .none)
        let audited = toy.audit(bar)
        XCTAssertEqual(audited.auditMismatches, 0)
        XCTAssertTrue(audited.complete)
        XCTAssertTrue(audited.reusable)
        XCTAssertEqual(audited.order, bar.order)
        XCTAssertEqual(audited.roles.map(\.identity), bar.roles.map(\.identity))
        XCTAssertEqual(audited.roles.map(\.members), bar.roles.map(\.members))
        XCTAssertEqual(audited.issues, bar.issues)
        XCTAssertEqual(audited.activeRow, bar.activeRow)
        XCTAssertEqual(audited.survey(toy.rows(), running: toy.running).stale, [:])
        // Only whose turn is next moved.
        XCTAssertNotEqual(audited.auditTarget?.pid, bar.auditTarget?.pid)
    }

    func testAuditCatchesAnIdentityChangeTheWindowsDoNotShow() {
        var toy = twoRows(["a0", sep, "a1", ctl])
        let config = ToyBar.config(hidden: ["a0"], visible: ["a1"])
        var bar = toy.gather(after: .none)
        toy.items["a1"] = "renamed"
        // Same windows, so the carried binding still vouches for the old identity.
        XCTAssertEqual(bar.survey(toy.rows(), running: toy.running).stale, [:])
        while bar.auditTarget?.pid != toy.pid("a1") { bar = toy.audit(bar) }

        let audited = toy.audit(bar)
        XCTAssertEqual(audited.auditMismatches, 1)
        XCTAssertTrue(audited.complete, "\(audited.issues)")
        XCTAssertTrue(audited.reusable)
        XCTAssertEqual(audited.roles.first { $0.pid == toy.pid("a1") }?.identity, IconIdentity(bundle: "app.a1", item: "renamed"))
        // The pass the mismatch requests reads nothing and registers the icon it found.
        let next = toy.gather(after: audited)
        XCTAssertEqual(audited.survey(toy.rows(), running: toy.running).stale, [:])
        XCTAssertEqual(next.auditMismatches, 1)
        guard case .register(let items, _) = assess(config, next, MoveHistory()).next else { return XCTFail("expected register") }
        XCTAssertEqual(Set(items.keys.filter { config.items[$0] == nil }), ["app.a1::renamed"])
    }

    func testFailedAuditMakesTheNextPassReadTheAppAndReportIt() {
        let toy = twoRows(["a0", sep, "a1", ctl])
        let bar = toy.gather(after: .none)
        let target = try! XCTUnwrap(bar.auditTarget)
        let failed = toy.audit(bar, failing: true)
        XCTAssertEqual(failed.auditMismatches, 0)
        XCTAssertFalse(failed.reusable)
        XCTAssertEqual(failed.roles.map(\.identity), bar.roles.map(\.identity))
        XCTAssertEqual(failed.survey(toy.rows(), running: toy.running).stale, [target.pid: "previous read incomplete"])
        // The next pass reads it; a read that fails again is reported, a clean one restores it.
        let unread = toy.gather(after: failed, failing: [target.pid])
        XCTAssertFalse(unread.complete)
        XCTAssertEqual(unread.issues, [WorkIssue(recovery: .retry, message: "Control Centre: timed out")])
        let reread = toy.gather(after: unread)
        XCTAssertTrue(reread.complete)
        XCTAssertTrue(reread.reusable)
    }

    func testMismatchMeansDifferentIdentitiesForTheSameWindows() {
        let toy = twoRows(["a0", sep, ctl])
        let bar = toy.gather(after: .none)
        let app = toy.running.first { $0.pid == toy.pid("a0") }!
        func audit(_ identity: IconIdentity, window: WindowKey, movable: Bool = true) -> MenuBar {
            let icon = AppReading.BoundIcon(identity: identity, label: "A0", movable: movable, window: window, element: 0)
            return MenuBar.observe(bar.survey(bar.rows, running: toy.running), readings: [AppReading(app: app, outcome: .clean([icon]))])
        }
        let same = IconIdentity(bundle: "app.a0", item: nil)
        // Read on either row, the same identity on one of the icon's replicas agrees.
        XCTAssertEqual(audit(same, window: toy.key("a0", row: 0)).auditMismatches, 0)
        XCTAssertEqual(audit(same, window: toy.key("a0", row: 1)).auditMismatches, 0)
        XCTAssertEqual(audit(IconIdentity(bundle: "app.a0", item: "other"), window: toy.key("a0", row: 0)).auditMismatches, 1)
        XCTAssertEqual(audit(same, window: toy.key("a0", row: 0), movable: false).auditMismatches, 1)
        // A reading for a restarted process is not about this binding.
        let restarted = AppProcess(pid: app.pid, bundle: app.bundle, name: app.name, incarnation: "9")
        let stray = MenuBar.observe(bar.survey(bar.rows, running: toy.running), readings: [.failed(restarted, WorkIssue(recovery: .retry, message: "x"))])
        XCTAssertTrue(stray.reusable)
    }
}
