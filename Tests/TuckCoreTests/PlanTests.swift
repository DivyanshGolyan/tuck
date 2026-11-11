import XCTest
@testable import TuckCore

final class PlanTests: XCTestCase {
    let separator = OwnItem.separator.id
    let control = OwnItem.control.id
    let rows: [CGFloat] = [0]

    func permutations(_ values: [String]) -> [[String]] {
        if values.isEmpty { return [[]] }
        return values.enumerated().flatMap { index, element in
            var rest = values
            rest.remove(at: index)
            return permutations(rest).map { [element] + $0 }
        }
    }

    func apply(_ move: Move, to order: [String]) -> [String] {
        var result = order
        result.remove(at: result.firstIndex(of: move.id)!)
        let insertion = move.before.map { result.firstIndex(of: $0)! } ?? result.count
        result.insert(move.id, at: insertion)
        return result
    }

    func leakCount(_ order: [String], visibleGroup: Set<String>) -> Int {
        order[..<order.firstIndex(of: separator)!].filter(visibleGroup.contains).count
    }

    /// Every order of up to six managed ids (separator always, control optional) and
    /// every hidden/visible split, replanning after each move as the shell does.
    func testExhaustiveReplanningReachesTargetSafely() throws {
        var cases = 0
        for withControl in [true, false] {
            let own = withControl ? [separator, control] : [separator]
            for count in 0...(6 - own.count) {
                let ids = Array(["a", "b", "c", "d", "e"].prefix(count))
                for mask in 0..<(1 << count) {
                    let hidden = ids.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                    let visible = ids.filter { !hidden.contains($0) }
                    let target = hidden + [separator] + visible + (withControl ? [control] : [])
                    let visibleGroup = Set(visible + [control])
                    for observed in permutations(ids + own) {
                        cases += 1
                        try check(observed, hidden: hidden, visible: visible, target: target, visibleGroup: visibleGroup)
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 20_000)
    }

    func check(_ observed: [String], hidden: [String], visible: [String], target: [String], visibleGroup: Set<String>) throws {
        let first = try Layout(order: observed, hidden: hidden, visible: visible, rows: rows)
        XCTAssertEqual(first.target, target)
        XCTAssertEqual(first.leaks.count, leakCount(observed, visibleGroup: visibleGroup))
        if observed == target {
            XCTAssertEqual(first.required + first.tuck + first.cosmetic, [], "\(observed)")
        }
        XCTAssertEqual(first.required.isEmpty, first.leaks.isEmpty)
        var listed = observed
        for move in first.required + first.tuck + first.cosmetic { listed = apply(move, to: listed) }
        XCTAssertEqual(listed, target, "listed plan from \(observed)")

        let bound = first.required.count + first.tuck.count + first.cosmetic.count
        var order = observed
        var layout = first
        var steps = 0
        while let move = layout.next {
            steps += 1
            guard steps <= bound else { return XCTFail("more than \(bound) steps from \(observed)") }
            XCTAssertNotEqual(move.purpose == .unblockHide, layout.required.isEmpty)
            let before = leakCount(order, visibleGroup: visibleGroup)
            order = apply(move, to: order)
            let after = leakCount(order, visibleGroup: visibleGroup)
            switch move.purpose {
            case .unblockHide: XCTAssertLessThan(after, before, "\(move) from \(observed)")
            case .tuck, .cosmetic: XCTAssertEqual(after, 0, "\(move) from \(observed)")
            }
            if move.purpose == .cosmetic { XCTAssertTrue(move.id != separator && move.id != control) }
            layout = try Layout(order: order, hidden: hidden, visible: visible, rows: rows)
        }
        XCTAssertEqual(order, target, "from \(observed)")
        XCTAssertTrue(layout.leaks.isEmpty && layout.strays.isEmpty)
    }

    func testLeaksAndStraysAreReportedInObservedOrder() throws {
        let layout = try Layout(order: ["v", control, "h", separator, "g"], hidden: ["h", "g"], visible: ["v"], rows: rows)
        XCTAssertEqual(layout.leaks, ["v", control])
        XCTAssertEqual(layout.strays, ["g"])
        XCTAssertEqual(layout.target, ["h", "g", separator, "v", control])
        XCTAssertEqual(layout.next?.purpose, .unblockHide)
        XCTAssertEqual(layout.next?.id, separator)
    }

    func testOfflineIDsIgnoredAndUnknownIDsNeverMovedOrAnchors() throws {
        let observed = ["unknown", "b", separator, "a", "other", control]
        let layout = try Layout(order: observed, hidden: ["a", "offline"], visible: ["b"], rows: rows)
        XCTAssertEqual(layout.target, ["a", separator, "b", control])
        var order = observed
        var current = layout
        while let move = current.next {
            for id in ["unknown", "offline", "other"] {
                XCTAssertNotEqual(move.id, id)
                XCTAssertNotEqual(move.before, id)
            }
            order = apply(move, to: order)
            current = try Layout(order: order, hidden: ["a", "offline"], visible: ["b"], rows: rows)
        }
        XCTAssertEqual(order.filter { $0 != "unknown" && $0 != "other" }, ["a", separator, "b", control])
    }

    func testInvalidInputsAreRejected() {
        func error(_ body: () throws -> Layout) -> LayoutError? {
            do { _ = try body(); return nil } catch { return error as? LayoutError }
        }
        XCTAssertEqual(error { try Layout(order: [separator], hidden: ["a"], visible: ["a"], rows: rows) }, .duplicateID("a"))
        XCTAssertEqual(error { try Layout(order: [separator, separator], hidden: [], visible: [], rows: rows) }, .duplicateID(separator))
        XCTAssertEqual(error { try Layout(order: [separator], hidden: [separator], visible: [], rows: rows) }, .separatorInPlacement)
        XCTAssertEqual(error { try Layout(order: [separator], hidden: [], visible: [control], rows: rows) }, .duplicateID(control))
        XCTAssertEqual(error { try Layout(order: [], hidden: [], visible: [], rows: rows) }, .missingSeparator)
    }

    func testMovesCarryTheirAttemptKeyAndLabel() throws {
        let layout = try Layout(order: ["b", "a", separator, control], hidden: ["a", "b"], visible: [], rows: [0, 1080],
                                label: { "label " + $0 })
        let move = try XCTUnwrap(layout.next)
        XCTAssertEqual(move.purpose, .cosmetic)
        XCTAssertEqual(move.label, "label " + move.id)
        XCTAssertEqual(move.attempt, AttemptKey(order: layout.order, target: layout.target, rows: [0, 1080]))
    }
}
