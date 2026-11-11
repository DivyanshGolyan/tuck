import CoreGraphics
import XCTest
@testable import TuckCore

/// Deterministic, seedable, no dependency.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func chance(_ probability: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < probability }
}

/// The OS at toy scale: an order of icons rendered right-aligned on 1-3 stacked displays,
/// each row anchored by Tuck's control, a clock right of everything, and Command-drags
/// applied by hit-testing the drag's points. Icon ids are "a0", "a1", ...; their config
/// ids are the same, their bundles "app.<id>".
struct ToyBar {
    static let ownPID: Int32 = 900
    static let clockPID: Int32 = 50
    static let clock = IconIdentity(bundle: "com.apple.controlcenter", item: "Clock")
    static let separator = OwnItem.separator.id
    static let control = OwnItem.control.id

    var order: [String]
    var displays: [Display]
    var hidden = false
    /// Index into `displays` of the row AX reports frames on.
    var activeRow = 0
    var restarts: [String: Int] = [:]
    var bundles: [String: String] = [:]
    /// An app that renamed its status item keeps its windows; only AX shows the change.
    var items: [String: String] = [:]
    var ghosts: [StatusWindow] = []
    var omitSeparator = false
    /// A move whose effect becomes visible only at a later gather.
    private var late: (id: String, before: String?, gathers: Int)?

    init(order: [String], displays: [Display]? = nil) {
        self.order = order
        self.displays = displays ?? [Display(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), usableLeft: 180)]
    }

    static func display(y: CGFloat, width: CGFloat, notch: CGFloat? = nil) -> Display {
        let frame = CGRect(x: 0, y: y, width: width, height: 900)
        return Display(frame: frame, usableLeft: notch.map { frame.maxX - $0 } ?? frame.minX + 180)
    }

    static func config(hidden: [String], visible: [String], unregistered: Set<String> = [], showHidden: Bool = false) -> TuckConfig {
        var items = Dictionary(uniqueKeysWithValues: (hidden + visible).map { ($0, ItemMetadata(bundleID: "app." + $0, label: $0.uppercased())) })
        items["clock"] = ItemMetadata(bundleID: clock.bundle, label: "Clock", item: clock.item)
        for id in unregistered { items[id] = nil }
        return TuckConfig(visible: visible.filter { items[$0] != nil } + (items["clock"] == nil ? [] : ["clock"]),
                          hidden: hidden.filter { items[$0] != nil }, items: items, showHidden: showHidden)
    }

    var apps: [String] { order.filter { OwnItem(rawValue: $0) == nil } }
    func pid(_ id: String) -> Int32 { 100 + Int32(id.dropFirst())! }
    func bundle(_ id: String) -> String { bundles[id] ?? "app." + id }
    func identity(_ id: String) -> IconIdentity { id == "clock" ? Self.clock : IconIdentity(bundle: bundle(id), item: items[id]) }
    func id(of pid: Int32) -> String { pid == Self.clockPID ? "clock" : apps.first { self.pid($0) == pid }! }

    private func width(_ id: String) -> CGFloat {
        id == Self.separator ? (hidden ? 10_000 : 4) : id == Self.control ? 20 : 30
    }

    private func number(_ id: String, row: Int) -> UInt32 {
        switch id {
        case Self.separator: return row == 0 ? 10 : UInt32(20 + row * 2)
        case Self.control: return row == 0 ? 11 : UInt32(21 + row * 2)
        case "clock": return UInt32(1 + row)
        default: return UInt32(1 + row + 10 * restarts[id, default: 0])
        }
    }

    func key(_ id: String, row: Int) -> WindowKey {
        let pid = OwnItem(rawValue: id) != nil ? Self.ownPID : id == "clock" ? Self.clockPID : pid(id)
        return WindowKey(pid: pid, number: number(id, row: row))
    }

    /// Managed icons and the clock on one row, left to right.
    func frames(row: Int) -> [(id: String, frame: CGRect)] {
        let display = displays[row].frame
        var x = display.maxX - 10 - 40
        var result = [(id: "clock", frame: CGRect(x: x, y: display.minY, width: 40, height: 24))]
        for id in order.reversed() {
            x -= width(id)
            result.insert((id, CGRect(x: x, y: display.minY, width: width(id), height: 24)), at: 0)
        }
        return result
    }

    func list() -> WindowList {
        var windows = ghosts
        for row in displays.indices {
            let display = displays[row].frame
            for (id, frame) in frames(row: row) where !(omitSeparator && id == Self.separator) {
                let title = row == 0 ? OwnItem(rawValue: id)?.title ?? "" : ""
                windows.append(StatusWindow(key: key(id, row: row), frame: frame,
                                            onScreen: frame.minX >= display.minX && frame.maxX <= display.maxX, title: title))
            }
        }
        return WindowList(skippingMalformed: windows)
    }

    func rows() -> MenuRows { MenuRows(list(), ownPID: Self.ownPID, displays: displays) }

    var running: [AppProcess] {
        apps.map { AppProcess(pid: pid($0), bundle: bundle($0), name: $0.uppercased(), incarnation: String(restarts[$0, default: 0])) }
            + [AppProcess(pid: Self.clockPID, bundle: Self.clock.bundle, name: "Control Centre", incarnation: "0")]
    }

    /// What AX would say about the apps the core asked for, on the active row.
    func readings(for stale: [Int32: String], failing: Set<Int32> = []) -> [AppReading] {
        running.filter { stale[$0.pid] != nil }.map { app in
            if failing.contains(app.pid) { return .failed(app, WorkIssue(recovery: .retry, message: "timed out")) }
            let id = id(of: app.pid)
            return AppReading(app: app, outcome: .clean([AppReading.BoundIcon(
                identity: identity(id), label: id == "clock" ? "Clock" : app.name, movable: id != "clock",
                window: key(id, row: activeRow), element: 0)]))
        }
    }

    /// The shell's gather: one list, one survey, AX only for stale apps (none in observe-only reach).
    func gather(after previous: MenuBar, failing: Set<Int32> = [], observeOnly: Bool = false) -> MenuBar {
        let survey = previous.survey(rows(), running: running)
        return MenuBar.observe(survey, readings: observeOnly ? [] : readings(for: survey.stale, failing: failing))
    }

    /// The shell's audit after an applied pass: re-read `bar.auditTarget` on the bar's
    /// own rows and fold the reading back in.
    func audit(_ bar: MenuBar, failing: Bool = false) -> MenuBar {
        guard let target = bar.auditTarget else { return bar }
        let survey = bar.survey(bar.rows, running: running)
        return MenuBar.observe(survey, readings: readings(for: [target.pid: "audit"], failing: failing ? [target.pid] : []))
    }

    mutating func apply(_ boundary: Boundary) {
        switch boundary {
        case .keep: break
        case .reveal: hidden = false
        case .hide: hidden = true
        }
    }

    /// Hit-tests the move's points as WindowServer would and returns the id it grabbed.
    /// The effect lands now, at the second gather from now (`late`), or never (`drop`).
    mutating func perform(_ subject: Subject, drop: Bool = false, late isLate: Bool = false) -> String? {
        let grabbed: String
        let dropX: CGFloat
        let row: [(id: String, frame: CGRect)]
        switch subject {
        case .own(let item, let shift):
            row = frames(row: 0).filter { $0.id != "clock" }
            let own = row.first { $0.id == item.id }!
            grabbed = item.id
            dropX = own.frame.maxX + shift - 2
        case .icon(let drag):
            guard let index = displays.indices.first(where: { abs(drag.from.y - displays[$0].frame.minY - 12) < 1 }),
                  drag.from.x >= displays[index].usableLeft, drag.to.x >= displays[index].usableLeft else { return nil }
            row = frames(row: index).filter { $0.id != "clock" }
            guard let hit = row.first(where: { $0.frame.minX <= drag.from.x && drag.from.x < $0.frame.maxX }),
                  OwnItem(rawValue: hit.id) == nil else { return nil }
            grabbed = hit.id
            dropX = drag.to.x
        }
        let others = row.filter { $0.id != grabbed }
        let before = others.first { $0.frame.midX > dropX }?.id
        if isLate { late = (grabbed, before, 2) } else if !drop { place(grabbed, before: before) }
        return grabbed
    }

    /// Lets a late effect land; called at the start of every gather.
    mutating func tick() {
        guard let pending = late else { return }
        if pending.gathers > 1 { late = (pending.id, pending.before, pending.gathers - 1); return }
        late = nil
        place(pending.id, before: pending.before)
    }

    mutating func place(_ id: String, before: String?) {
        order.removeAll { $0 == id }
        order.insert(id, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count)
    }
}

/// One seeded run of the shell loop against a ToyBar with injected faults. Drives the
/// real MenuBar.observe, assess and MoveHistory.record exactly as Reconciler.run does.
struct Simulation {
    let seed: UInt64
    private var rng: SplitMix64
    private(set) var toy: ToyBar
    private(set) var config: TuckConfig
    private var bar = MenuBar.none
    private var history = MoveHistory()
    private var failures: [String] = []

    private let faultSteps: Int
    private let notched: Bool
    private var rates: [String: Double] = [:]
    private var dropped = 0, refused = 0, renames = 0
    /// Set by a disagreeing audit: the pass it requests does not audit, as in Reconciler.
    private var auditHeld = false
    private(set) var audits = 0, auditMismatches = 0, auditFailures = 0

    init(seed: UInt64) {
        self.seed = seed
        var rng = SplitMix64(state: seed)
        let ids = (0..<Int.random(in: 1...6, using: &rng)).map { "a\($0)" }
        let hidden = ids.filter { _ in rng.chance(0.5) }.shuffled(using: &rng)
        let visible = ids.filter { !hidden.contains($0) }.shuffled(using: &rng)
        notched = rng.chance(0.3)
        let ys: [CGFloat] = [0, -1117, 1440]
        var displays: [Display] = []
        for row in 0..<Int.random(in: 1...3, using: &rng) {
            let width = [1280, 1512, 1920][Int.random(in: 0...2, using: &rng)]
            let notch = notched && (row == 0 || rng.chance(0.5)) ? CGFloat(Int.random(in: 110...240, using: &rng)) : nil
            displays.append(ToyBar.display(y: ys[row], width: CGFloat(width), notch: notch))
        }
        toy = ToyBar(order: (ids + [ToyBar.separator, ToyBar.control]).shuffled(using: &rng), displays: displays)
        toy.hidden = rng.chance(0.5)
        toy.activeRow = Int.random(in: 0..<displays.count, using: &rng)
        let unregistered = Set((ids + ["clock"]).filter { _ in rng.chance(0.15) })
        config = ToyBar.config(hidden: hidden, visible: visible, unregistered: unregistered, showHidden: rng.chance(0.2))
        faultSteps = Int.random(in: 0...24, using: &rng)
        for name in ["drop", "late", "reorder", "restart", "ghost", "active", "ax", "list", "rows", "refuse", "observeOnly",
                     "rename", "auditFail"] {
            rates[name] = rng.chance(0.5) ? Double(Int.random(in: 0...30, using: &rng)) / 100 : 0
        }
        self.rng = rng
    }

    private mutating func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    private mutating func fault(_ name: String, _ faulty: Bool) -> Bool { faulty && rng.chance(rates[name]!) }

    private func toyID(_ configID: String) -> String? {
        if OwnItem(rawValue: configID) != nil { return configID }
        guard let bundle = config.items[configID]?.bundleID else { return nil }
        return toy.apps.first { toy.bundle($0) == bundle }
    }

    /// The truth: visible-group icons left of the separator in the toy's own order.
    private func trueLeaks() -> [String] {
        let present = Set(toy.apps)
        let visible = Set(config.visible.compactMap(toyID).filter(present.contains) + [ToyBar.control])
        return toy.order.prefix { $0 != ToyBar.separator }.filter(visible.contains)
    }

    private func leaks(_ order: [String], _ layout: Layout) -> Int {
        let visible = Set(layout.target.drop { $0 != OwnItem.separator.id }.dropFirst())
        return order.prefix { $0 != OwnItem.separator.id }.filter(visible.contains).count
    }

    private mutating func externalEvents(_ faulty: Bool) {
        if fault("reorder", faulty), let id = toy.order.randomElement(using: &rng) {
            toy.place(id, before: toy.order.filter { $0 != id }.randomElement(using: &rng))
        }
        if fault("restart", faulty), let id = toy.apps.randomElement(using: &rng) { toy.restarts[id, default: 0] += 1 }
        if fault("rename", faulty), let id = toy.apps.randomElement(using: &rng) {
            renames += 1
            toy.items[id] = "r\(renames)"
        }
        if fault("active", faulty) { toy.activeRow = Int.random(in: 0..<toy.displays.count, using: &rng) }
        if fault("ghost", faulty), let id = toy.apps.randomElement(using: &rng) {
            if toy.ghosts.isEmpty {
                let display = toy.displays[Int.random(in: 0..<toy.displays.count, using: &rng)].frame
                toy.ghosts = [StatusWindow(key: WindowKey(pid: toy.pid(id), number: 900),
                                           frame: CGRect(x: display.minX - 500, y: display.minY, width: 30, height: 24), onScreen: false)]
            } else {
                toy.ghosts = []
            }
        }
    }

    /// Safety, on every step.
    private mutating func checkSafety(_ verdict: Verdict) {
        if case .hide = verdict.boundary {
            expect(bar.complete, "S2: hide from an incomplete bar")
            expect(verdict.layout?.leaks == [], "S1: hide with leaks \(verdict.layout?.leaks ?? [])")
            let truth = trueLeaks()
            expect(truth.isEmpty, "S1: hide while \(truth) is left of the separator")
            expect(!config.showHidden, "hide while showHidden")
        }
        guard case .move(let move, let subject) = verdict.next, let layout = verdict.layout else { return }
        expect(bar.complete, "S2: move from an incomplete bar")
        expect(!verdict.history.pending, "S3: move while another is pending")
        expect(bar.rows.boundaryRevealed && !toy.hidden, "S4: move while the boundary is hidden")
        if move.purpose != .unblockHide {
            expect(layout.leaks.isEmpty, "S5: \(move.purpose) move while leaks remain")
            expect(leaks(applying(PlannedMove(id: move.id, before: move.before), to: layout.order), layout) == 0,
                   "S5: \(move.purpose) move creates a leak")
        }
        expect(layout.target.contains(move.id) && move.before.map(layout.target.contains) != false,
               "S6: move of or to an unplaced icon \(move)")
        switch subject {
        case .own(let item, _): expect(item.id == move.id, "S6: own shift for \(move.id)")
        case .icon: expect(OwnItem(rawValue: move.id) == nil, "S6: drag of an own item")
        }
    }

    mutating func run() -> [String] {
        var steps = 0, postedSinceChange = 0, pendingReads = 0
        var lastOrder: [String]?
        var terminal: Verdict?
        for step in 0..<1_000 {
            let faulty = step < faultSteps
            externalEvents(faulty)
            toy.tick()
            if fault("list", faulty) { steps = 0; continue }
            toy.omitSeparator = fault("rows", faulty)
            let observeOnly = steps == 0 && !config.showHidden && fault("observeOnly", true)
            let failing: Set<Int32> = fault("ax", faulty) ? Set(toy.running.map(\.pid).shuffled(using: &rng).prefix(1)) : []
            bar = toy.gather(after: bar, failing: failing, observeOnly: observeOnly)
            toy.omitSeparator = false
            let verdict = assess(config, bar, history)
            if !bar.complete, case .hide = verdict.boundary { expect(false, "S2: an incomplete bar yields hide") }
            checkSafety(verdict)
            history = verdict.history
            if let layout = verdict.layout {
                if layout.order != lastOrder { lastOrder = layout.order; postedSinceChange = 0 }
                pendingReads = history.pending ? pendingReads + 1 : 0
                expect(pendingReads < Limits.unchangedReads, "L3: a move stayed pending for \(pendingReads) observations")
            }
            if observeOnly {
                if case .done = verdict.next { toy.apply(verdict.boundary) }
                continue
            }
            toy.apply(verdict.boundary)
            steps += 1
            let budget = Limits.passSteps(managed: verdict.layout?.order.count ?? 0)
            switch verdict.next {
            case .done:
                steps = 0
                if auditHeld { auditHeld = false } else if audit(faulty) { auditHeld = true; break }
                if !faulty { terminal = verdict }
            case .stop(let issue):
                steps = 0
                if !faulty && issue.recovery == .awaitChange { terminal = verdict }
            case .register(let items, let order):
                steps = 0
                do { try config.register(items, orderedIDs: order, preserveObservedPositions: true) }
                catch { expect(false, "registration failed: \(error)") }
            case .settleThenGather:
                if steps >= budget { steps = 0 }
            case .move(let move, let subject):
                if steps >= budget { steps = 0; break }
                if fault("refuse", faulty) {
                    refused += 1
                    history = history.record(.refused(move, reason: "refused", permanent: true))
                    break
                }
                postedSinceChange += 1
                expect(postedSinceChange <= Limits.attempts, "S7: \(postedSinceChange) moves posted on one observed order")
                let drop = fault("drop", faulty)
                if drop { dropped += 1 }
                let grabbed = toy.perform(subject, drop: drop, late: fault("late", faulty))
                expect(grabbed != nil && grabbed == toyID(move.id), "S6: the drag for \(move.id) grabbed \(grabbed ?? "nothing")")
                history = history.record(.began(move))
            }
            if terminal != nil { break }
        }
        checkLiveness(terminal)
        return failures
    }

    /// The post-apply audit, checked every time it runs: a failed read makes the app stale
    /// on the next list, a disagreement happens exactly when the carried identity is no
    /// longer what AX says and leaves AX's identity bound, and an agreement changes
    /// nothing but whose turn is next. True when it asks for another pass.
    private mutating func audit(_ faulty: Bool) -> Bool {
        guard let target = bar.auditTarget else { return false }
        let before = bar
        let failing = fault("auditFail", faulty)
        bar = toy.audit(before, failing: failing)
        audits += 1
        let truth = toy.identity(toy.id(of: target.pid))
        let carried = before.roles.filter { $0.pid == target.pid }.map(\.identity)
        if failing {
            auditFailures += 1
            expect(bar.auditMismatches == before.auditMismatches, "audit: a failed read counted as a mismatch")
            expect(bar.survey(toy.rows(), running: toy.running).stale[target.pid] != nil,
                   "audit: a failed audit left \(target.name) reusable")
            return false
        }
        if bar.auditMismatches > before.auditMismatches {
            auditMismatches += 1
            expect(carried != [truth], "audit: a mismatch for a binding that matched AX")
            expect(bar.roles.filter { $0.pid == target.pid }.map(\.identity) == [truth], "audit: a mismatch left \(carried) bound")
            return true
        }
        expect(carried == [truth], "audit: agreed with \(carried) while AX says \(truth)")
        expect(bar.order == before.order && bar.issues == before.issues && bar.reusable == before.reusable
               && bar.roles.map(\.identity) == before.roles.map(\.identity), "audit: an agreeing audit changed the bar")
        expect(bar.auditTarget?.pid != target.pid || before.bindings.values.filter(\.reusable).count == 1,
               "audit: the target did not rotate")
        return false
    }

    /// Liveness, once per run, after the last fault.
    private mutating func checkLiveness(_ terminal: Verdict?) {
        guard let terminal, let layout = terminal.layout else {
            return expect(false, "did not settle within the step bound")
        }
        let clean = dropped == 0 && refused == 0 && !notched
        switch terminal.next {
        case .done(let note):
            let hiddenPresent = layout.target.first != OwnItem.separator.id
            let hides: Bool
            if case .hide = terminal.boundary { hides = true } else { hides = false }
            expect(hides == (!config.showHidden && hiddenPresent), "L2: done with boundary \(terminal.boundary)")
            expect(note != nil || layout.order == layout.target, "done without a note away from the target")
            if clean { expect(note == nil && layout.order == layout.target, "L1: settled at \(layout.order), note \(note ?? "nil")") }
        case .stop(let issue):
            expect(!clean, "L1: a clean run stopped: \(issue.message)")
            expect(!layout.leaks.isEmpty && terminal.boundary == .reveal, "awaitChange without a leak, or not revealed")
        default:
            expect(false, "terminal verdict \(terminal.next)")
        }
        // Replay: the same observation again plans nothing new and reads no app.
        for _ in 0..<2 {
            let rows = toy.rows()
            if case .done = terminal.next {
                expect(bar.survey(rows, running: toy.running).stale.isEmpty, "replay reads an app")
            }
            bar = toy.gather(after: bar)
            let again = assess(config, bar, history)
            history = again.history
            expect(again.boundary == terminal.boundary, "replay changed the boundary")
            switch (again.next, terminal.next) {
            case (.done(let a), .done(let b)): expect(a == b, "replay changed the note")
            case (.stop(let a), .stop(let b)): expect(a == b, "replay changed the stop")
            default: expect(false, "replay planned \(again.next)")
            }
        }
    }
}

final class SimulatedBarTests: XCTestCase {
    func testSeededRunsKeepSafetyAndSettle() {
        var audits = 0, mismatches = 0, failures = 0
        for seed in UInt64(0)..<300 {
            var simulation = Simulation(seed: seed)
            let found = simulation.run()
            if let first = found.first {
                XCTFail("seed \(seed): \(first) (\(found.count) failures; rerun Simulation(seed: \(seed)).run())")
            }
            audits += simulation.audits; mismatches += simulation.auditMismatches; failures += simulation.auditFailures
        }
        // Every audit outcome ran somewhere in the seeds.
        XCTAssertGreaterThan(mismatches, 0)
        XCTAssertGreaterThan(failures, 0)
        XCTAssertGreaterThan(audits, mismatches + failures)
    }

    func testReplayingAPassPlansNothing() {
        var toy = ToyBar(order: ["a1", "a0", ToyBar.separator, ToyBar.control], displays: [ToyBar.display(y: 0, width: 1512), ToyBar.display(y: -1117, width: 1920)])
        let config = ToyBar.config(hidden: ["a0", "a1"], visible: [])
        var bar = MenuBar.none, history = MoveHistory(), moves = 0
        while true {
            bar = toy.gather(after: bar)
            let verdict = assess(config, bar, history)
            history = verdict.history
            toy.apply(verdict.boundary)
            if case .move(let move, let subject) = verdict.next {
                _ = toy.perform(subject); history = history.record(.began(move)); moves += 1
                continue
            }
            if case .done = verdict.next { break }
            XCTAssertLessThan(moves, 5)
        }
        XCTAssertEqual(toy.order, ["a0", "a1", ToyBar.separator, ToyBar.control])
        for _ in 0..<2 {
            XCTAssertEqual(bar.survey(toy.rows(), running: toy.running).stale, [:])
            bar = toy.gather(after: bar)
            let verdict = assess(config, bar, history)
            XCTAssertEqual(verdict.history, history)
            guard case .done(nil) = verdict.next, case .hide = verdict.boundary else { return XCTFail("\(verdict.next)") }
        }
    }

    func testObserveOnlyPassHidesWithoutReadingAnyApp() {
        var toy = ToyBar(order: ["a0", ToyBar.separator, "a1", ToyBar.control])
        var config = ToyBar.config(hidden: ["a0"], visible: ["a1"], showHidden: true)
        var bar = toy.gather(after: .none)
        var verdict = assess(config, bar, MoveHistory())
        guard case .done = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertEqual(verdict.boundary, .reveal)

        config.showHidden = false
        XCTAssertEqual(bar.survey(toy.rows(), running: toy.running).stale, [:])
        bar = toy.gather(after: bar, observeOnly: true)
        XCTAssertTrue(bar.complete)
        verdict = assess(config, bar, verdict.history)
        guard case .done(nil) = verdict.next, case .hide = verdict.boundary else { return XCTFail("\(verdict.next)") }
        toy.apply(verdict.boundary)

        // A ghost that comes on screen on the bar must be read; observe-only cannot read it.
        toy.ghosts = [StatusWindow(key: WindowKey(pid: toy.pid("a1"), number: 900),
                                   frame: CGRect(x: 600, y: 0, width: 30, height: 24), onScreen: true)]
        bar = toy.gather(after: bar, observeOnly: true)
        XCTAssertFalse(bar.complete)
        verdict = assess(config, bar, verdict.history)
        guard case .stop(let issue) = verdict.next else { return XCTFail("\(verdict.next)") }
        XCTAssertTrue(issue.message.contains("not read"), issue.message)
        XCTAssertEqual(verdict.boundary, .keep)
    }

    func testActiveRowChangeNeedsNoRead() {
        var toy = ToyBar(order: ["a0", ToyBar.separator, "a1", ToyBar.control],
                         displays: [ToyBar.display(y: 0, width: 1512), ToyBar.display(y: -1117, width: 1920)])
        let bar = toy.gather(after: .none)
        XCTAssertTrue(bar.complete)
        toy.activeRow = 1
        XCTAssertEqual(bar.survey(toy.rows(), running: toy.running).stale, [:])
        let next = toy.gather(after: bar)
        XCTAssertTrue(next.complete)
        XCTAssertEqual(next.order, bar.order)
    }
}
