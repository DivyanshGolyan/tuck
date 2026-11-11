import CoreGraphics
import XCTest
@testable import TuckCore

/// One example per row of the `assess` precedence table, on bars observed from a ToyBar.
final class VerdictTests: XCTestCase {
    let sep = OwnItem.separator.id
    let ctl = OwnItem.control.id

    private func isHide(_ boundary: Boundary) -> Bool {
        if case .hide = boundary { return true }
        return false
    }

    private func frame(_ toy: ToyBar, _ id: String, row: Int = 0) -> CGRect {
        toy.frames(row: row).first { $0.id == id }!.frame
    }

    // MARK: Rule 1

    func testIncompleteBarStopsOnTheFirstRetryIssueAndKeepsTheBoundary() {
        let toy = ToyBar(order: ["a0", sep, "a1", ctl])
        let config = ToyBar.config(hidden: ["a0"], visible: ["a1"])
        let bar = toy.gather(after: .none, failing: [toy.pid("a1")])
        XCTAssertFalse(bar.complete)
        let verdict = assess(config, bar, MoveHistory())
        guard case .stop(let issue) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(issue, WorkIssue(recovery: .retry, message: "A1: timed out"))
        XCTAssertEqual(verdict.boundary, .keep)
        XCTAssertNil(verdict.layout)
        XCTAssertEqual(verdict.history, MoveHistory())
    }

    func testRowFaultStopsWithTheFault() {
        var toy = ToyBar(order: ["a0", sep, "a1", ctl])
        toy.omitSeparator = true
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .stop(let issue) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(issue, WorkIssue(recovery: .retry, message: "Tuck's menu bar items not identified"))
        XCTAssertEqual(verdict.boundary, .keep)
    }

    // MARK: Rule 2

    /// Two icons can only resolve to one config id when they share an identity, and a
    /// complete bar never has that: the observation already stops at rule 1.
    func testSharedIdentityNeverReachesAliasingOrAMove() {
        var toy = ToyBar(order: ["a1", "a0", sep, ctl])
        toy.bundles["a1"] = "app.a0"
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .stop(let issue) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(issue, WorkIssue(recovery: .awaitChange, message: "app.a0: ambiguous identity"))
        XCTAssertEqual(verdict.boundary, .keep)
    }

    // MARK: Rule 3

    func testUnregisteredIconsAreRegisteredInObservedOrder() {
        let toy = ToyBar(order: ["a0", sep, "a1", ctl])
        let config = ToyBar.config(hidden: ["a0"], visible: ["a1"], unregistered: ["a1"])
        let verdict = assess(config, toy.gather(after: .none), MoveHistory())
        guard case .register(let items, let order) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(order, ["a0", "app.a1", "clock"])
        XCTAssertEqual(items["app.a1"], ItemMetadata(bundleID: "app.a1", label: "A1", item: nil, movable: true))
        XCTAssertEqual(items["clock"]?.movable, false)
        XCTAssertEqual(verdict.boundary, .keep)
    }

    // MARK: Rule 4

    func testUnverifiedMoveWaitsForTheNextObservation() {
        let toy = ToyBar(order: ["a1", "a0", sep, ctl])
        let config = ToyBar.config(hidden: ["a0"], visible: ["a1"])
        let bar = toy.gather(after: .none)
        let first = assess(config, bar, MoveHistory())
        guard case .move(let move, _) = first.next else { return XCTFail("\(first.next)") }
        let verdict = assess(config, toy.gather(after: bar), first.history.record(.began(move)))
        guard case .stop(let issue) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(issue, WorkIssue(recovery: .retry, message: "Waiting to verify previous move"))
        XCTAssertEqual(verdict.boundary, .keep)
        XCTAssertEqual(verdict.history.phase, .pending(move, reads: 1))
    }

    // MARK: Rule 5

    func testAbandoningAnUnblockHideMoveRevealsAndAwaitsChange() {
        var toy = ToyBar(order: ["a1", "a0", sep, ctl])
        let config = ToyBar.config(hidden: ["a0"], visible: ["a1"])
        let first = assess(config, toy.gather(after: .none), MoveHistory())
        guard case .move(let move, _) = first.next else { return XCTFail("\(first.next)") }
        XCTAssertEqual(move.purpose, .unblockHide)
        let struck = first.history.record(.refused(move, reason: "stuck", permanent: true))
        toy.hidden = true
        let verdict = assess(config, toy.gather(after: .none), struck)
        guard case .stop(let issue) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(issue, WorkIssue(recovery: .awaitChange, message: "stuck; icons left accessible"))
        XCTAssertEqual(verdict.boundary, .reveal)
    }

    // MARK: Rule 6

    func testHiddenBoundarySettlesBeforeMoving() {
        var toy = ToyBar(order: ["a1", "a0", sep, ctl])
        toy.hidden = true
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .settleThenGather = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(verdict.boundary, .reveal)
    }

    func testRequiredMoveOfAnotherAppsIconIsADragToJustLeftOfItsAnchor() {
        let toy = ToyBar(order: ["a1", "a0", sep, ctl])
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .move(let move, let subject) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(move.id, "a1")
        XCTAssertEqual(move.before, ctl)
        XCTAssertEqual(move.purpose, .unblockHide)
        let icon = frame(toy, "a1"), anchor = frame(toy, ctl)
        XCTAssertEqual(subject, .icon(Drag(from: CGPoint(x: icon.midX, y: icon.midY), to: CGPoint(x: anchor.minX - 2, y: icon.midY))))
        XCTAssertEqual(verdict.boundary, .reveal)
    }

    func testControlLeftOfTheSeparatorShiftsTheSeparator() {
        let toy = ToyBar(order: ["a0", ctl, sep, "a1"])
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .move(let move, let subject) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(move.id, sep)
        XCTAssertEqual(move.before, ctl)
        XCTAssertEqual(subject, .own(.separator, shift: frame(toy, ctl).minX - frame(toy, sep).maxX))
    }

    /// The planner never ends a move at the group end while the control is on the bar;
    /// the rule is kept for completeness: just left of the first fixed icon.
    func testMoveToTheGroupEndDropsJustLeftOfTheFirstFixedIcon() {
        let toy = ToyBar(order: ["a1", "a0", sep, ctl])
        let bar = toy.gather(after: .none)
        let move = Move(id: "a1", label: "A1", before: nil, purpose: .cosmetic, attempt: AttemptKey(order: [], target: [], rows: []))
        let icon = frame(toy, "a1")
        XCTAssertEqual(Roster(bar, items: ToyBar.config(hidden: ["a0", "a1"], visible: []).items).subject(for: move, reference: 0),
                       .reachable(.icon(Drag(from: CGPoint(x: icon.midX, y: icon.midY), to: CGPoint(x: frame(toy, "clock").minX - 1, y: icon.midY)))))
    }

    // MARK: Rule 7

    func testDoneHidesWhenAHiddenGroupIconIsPresent() {
        let toy = ToyBar(order: ["a0", sep, "a1", ctl])
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .done(nil) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertTrue(isHide(verdict.boundary))
        XCTAssertEqual(verdict.layout?.leaks, [])
    }

    func testDoneRevealsWhenNoHiddenGroupIconIsPresent() {
        let toy = ToyBar(order: [sep, "a0", "a1", ctl])
        let verdict = assess(ToyBar.config(hidden: [], visible: ["a0", "a1"]), toy.gather(after: .none), MoveHistory())
        guard case .done(nil) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(verdict.boundary, .reveal)
    }

    func testAbandoningATuckOrCosmeticMoveStillHidesWithTheNote() {
        for (order, purpose) in [(["a1", "a0", sep, ctl], Purpose.cosmetic), (["a0", sep, "a1", ctl], .tuck)] {
            let toy = ToyBar(order: order)
            let config = ToyBar.config(hidden: ["a0", "a1"], visible: [])
            let first = assess(config, toy.gather(after: .none), MoveHistory())
            guard case .move(let move, _) = first.next else { return XCTFail("\(first.next)") }
            XCTAssertEqual(move.purpose, purpose)
            let verdict = assess(config, toy.gather(after: .none), first.history.record(.refused(move, reason: "stuck", permanent: true)))
            guard case .done(let note) = verdict.next else { return XCTFail("\(verdict.next)") }
            XCTAssertEqual(note, "stuck")
            XCTAssertTrue(isHide(verdict.boundary))
        }
    }

    // MARK: Overlays and give-up paths

    func testShowHiddenOverlaysRevealOnEveryStop() {
        var config = ToyBar.config(hidden: ["a0"], visible: ["a1"], unregistered: ["a1"], showHidden: true)
        var toy = ToyBar(order: ["a1", "a0", sep, ctl])
        toy.hidden = true
        let incomplete = assess(config, toy.gather(after: .none, failing: [toy.pid("a0")]), MoveHistory())
        let register = assess(config, toy.gather(after: .none), MoveHistory())
        config = ToyBar.config(hidden: ["a0"], visible: ["a1"], showHidden: true)
        toy.hidden = false
        let bar = toy.gather(after: .none)
        let first = assess(config, bar, MoveHistory())
        guard case .move(let move, _) = first.next else { return XCTFail("\(first.next)") }
        let pending = assess(config, toy.gather(after: bar), first.history.record(.began(move)))
        let abandoned = assess(config, bar, first.history.record(.refused(move, reason: "stuck", permanent: true)))
        for verdict in [incomplete, register, pending, abandoned] {
            guard case .stop = verdict.next else {
                if case .register = verdict.next { XCTAssertEqual(verdict.boundary, .reveal); continue }
                return XCTFail("\(verdict.next)")
            }
            XCTAssertEqual(verdict.boundary, .reveal)
        }
    }

    func testIncompleteBarNeverYieldsHide() {
        let config = ToyBar.config(hidden: ["a0"], visible: ["a1"])
        for hidden in [false, true] {
            var toy = ToyBar(order: ["a0", sep, "a1", ctl], displays: [ToyBar.display(y: 0, width: 1512), ToyBar.display(y: -1117, width: 1920)])
            toy.hidden = hidden
            let whole = toy.gather(after: .none)
            XCTAssertTrue(isHide(assess(config, whole, MoveHistory()).boundary))
            var bars = [toy.gather(after: .none, failing: [toy.pid("a0")]), toy.gather(after: .none, observeOnly: true)]
            toy.omitSeparator = true
            bars.append(toy.gather(after: whole))
            toy.omitSeparator = false
            toy.restarts["a1"] = 1
            bars.append(toy.gather(after: whole, observeOnly: true))
            toy.ghosts = [StatusWindow(key: WindowKey(pid: toy.pid("a0"), number: 900),
                                       frame: CGRect(x: 700, y: 0, width: 30, height: 24), onScreen: true)]
            bars.append(toy.gather(after: whole, observeOnly: true))
            for bar in bars {
                XCTAssertFalse(bar.complete)
                XCTAssertEqual(assess(config, bar, MoveHistory()).boundary, .keep)
            }
        }
    }

    /// The icon sits behind the notch on the only display: the move is abandoned inside
    /// `assess`, without the shell, and the pass settles or stops by the move's purpose.
    func testUnreachableIconIsAbandonedInsideAssess() {
        let notched = [ToyBar.display(y: 0, width: 1512, notch: 72)]
        let toy = ToyBar(order: ["a1", "a0", sep, ctl], displays: notched)
        let reason = "Icon overflows the available menu bar; use a wider display"

        let cosmetic = ToyBar.config(hidden: ["a0", "a1"], visible: [])
        let settled = assess(cosmetic, toy.gather(after: .none), MoveHistory())
        guard case .done(let note) = settled.next, let move = settled.layout?.next else { return XCTFail("\(settled.next)") }
        XCTAssertEqual(note, reason)
        XCTAssertEqual(move.purpose, .cosmetic)
        XCTAssertEqual(settled.history.abandoned(move), reason)
        XCTAssertTrue(isHide(settled.boundary))

        let required = ToyBar.config(hidden: ["a0"], visible: ["a1"])
        let stopped = assess(required, toy.gather(after: .none), MoveHistory())
        guard case .stop(let issue) = stopped.next else { return XCTFail("\(stopped.next)") }
        XCTAssertEqual(issue, WorkIssue(recovery: .awaitChange, message: reason + "; icons left accessible"))
        XCTAssertEqual(stopped.boundary, .reveal)
    }

    func testReplicaOnAWiderDisplayIsDraggedWhenTheActiveRowIsNotched() {
        let toy = ToyBar(order: ["a1", "a0", sep, ctl],
                         displays: [ToyBar.display(y: 0, width: 1512, notch: 72), ToyBar.display(y: -1117, width: 1920)])
        let verdict = assess(ToyBar.config(hidden: ["a0"], visible: ["a1"]), toy.gather(after: .none), MoveHistory())
        guard case .move(_, .icon(let drag)) = verdict.next else { return XCTFail("\(verdict.next)") }
        let icon = frame(toy, "a1", row: 1), anchor = frame(toy, ctl, row: 1)
        XCTAssertEqual(drag, Drag(from: CGPoint(x: icon.midX, y: icon.midY), to: CGPoint(x: anchor.minX - 2, y: icon.midY)))
    }

    func testDisplayChangeReEnablesAnAbandonedMove() {
        var toy = ToyBar(order: ["a1", "a0", sep, ctl], displays: [ToyBar.display(y: 0, width: 1512, notch: 72)])
        let config = ToyBar.config(hidden: ["a0", "a1"], visible: [])
        var bar = toy.gather(after: .none)
        let abandoned = assess(config, bar, MoveHistory())
        guard case .done(.some) = abandoned.next else { return XCTFail("\(abandoned.next)") }

        bar = toy.gather(after: bar)
        let unchanged = assess(config, bar, abandoned.history)
        guard case .done(.some) = unchanged.next else { return XCTFail("\(unchanged.next)") }
        XCTAssertEqual(unchanged.history, abandoned.history)

        toy.displays = [ToyBar.display(y: 0, width: 1512)]
        bar = toy.gather(after: bar)
        XCTAssertEqual(bar.rows.rows, [0])
        let retried = assess(config, bar, unchanged.history)
        guard case .move(let move, .icon) = retried.next else { return XCTFail("\(retried.next)") }
        XCTAssertEqual(move.purpose, .cosmetic)
    }

    func testPassStepsAllowTheMoveBudgetPlusSettleAndFinalObservation() {
        XCTAssertEqual(Limits.passSteps(managed: 1), 6)
        XCTAssertEqual(Limits.passSteps(managed: 5), 12)
    }
}
