import CoreGraphics
import Foundation

// MARK: - Bounds

/// Every numeric bound of the middle layer.
public enum Limits {
    /// Unchanged observations after a posted move before it counts as having had no effect.
    static let unchangedReads = 3
    /// Strikes on one attempt key before its moves are abandoned.
    static let attempts = 2
    /// Gather-and-assess iterations one pass may run: a budget of max(4, 2 x managed)
    /// moves, plus the reveal settle and the final observation.
    public static func passSteps(managed: Int) -> Int { max(4, 2 * managed) + 2 }
}

// MARK: - Assess

/// Decides the whole pass from one observation. Every input yields a verdict.
///
/// Precedence, first match wins:
///  1. bar incomplete                       -> stop(first retry issue, else first issue); boundary keep
///  2. config alias collision               -> stop(retry "Ambiguous config alias: <id>")
///  3. icons not in config.items            -> register(discovered, observed order)
///  4. the observation leaves a move pending -> stop(retry "Waiting to verify previous move")
///  5. leaks, first required move abandoned -> stop(awaitChange "<reason>; icons left accessible"); boundary reveal
///  6. a move left, not abandoned:
///       boundary hidden on the bar         -> settleThenGather; boundary reveal
///       no hittable replica                -> strike its key to the limit, continue at 5 or 7
///       otherwise                          -> move(first by purpose); boundary reveal
///  7. otherwise                            -> done(note: abandoned reason or nil); boundary
///                                             hide iff !showHidden and a hidden-group icon is
///                                             present, else reveal
/// On 1-4 the boundary is `.reveal` when config.showHidden: a reveal never waits.
public func assess(_ config: TuckConfig, _ bar: MenuBar, _ history: MoveHistory) -> Verdict {
    let held: Boundary = config.showHidden ? .reveal : .keep
    guard bar.complete, let reference = bar.referenceRow else {
        let issue = bar.rows.fault.map { WorkIssue(recovery: .retry, message: $0) }
            ?? bar.issues.first { $0.recovery == .retry } ?? bar.issues.first
            ?? WorkIssue(recovery: .retry, message: "Waiting for a coherent active menu bar")
        return Verdict(boundary: held, next: .stop(issue), history: history, layout: nil)
    }
    let roster = Roster(bar, items: config.items)
    if let issue = roster.aliases?.issue {
        return Verdict(boundary: held, next: .stop(issue), history: history, layout: nil)
    }
    if roster.icons.contains(where: { config.items[$0.id] == nil }) {
        let discovered = Dictionary(uniqueKeysWithValues: roster.icons.map { ($0.id, $0.metadata) })
        return Verdict(boundary: held, next: .register(discovered, order: roster.icons.map(\.id)), history: history, layout: nil)
    }

    let available = Set(roster.icons.filter(\.role.movable).map(\.id))
    let hidden = config.hidden.filter(available.contains)
    let layout: Layout
    do {
        layout = try Layout(order: roster.order, hidden: hidden, visible: config.visible.filter(available.contains),
                            rows: bar.rows.rows, displays: bar.rows.displays,
                            label: { OwnItem(rawValue: $0) != nil ? "Tuck's own item" : config.items[$0]?.label ?? $0 })
    } catch {
        return Verdict(boundary: held, next: .stop(WorkIssue(recovery: .awaitChange, message: String(describing: error))),
                       history: history, layout: nil)
    }

    var history = history.observe(order: layout.order, goalMet: layout.next == nil)
    if history.pending {
        return Verdict(boundary: held, next: .stop(WorkIssue(recovery: .retry, message: "Waiting to verify previous move")),
                       history: history, layout: layout)
    }
    if let planned = layout.next, history.abandoned(planned) == nil {
        guard bar.rows.boundaryRevealed else {
            return Verdict(boundary: .reveal, next: .settleThenGather, history: history, layout: layout)
        }
        switch roster.subject(for: planned, reference: reference) {
        case .reachable(let subject):
            return Verdict(boundary: .reveal, next: .move(planned, subject), history: history, layout: layout)
        case .unreachable(let reason):
            history = history.record(.refused(planned, reason: reason, permanent: true))
        }
    }
    var note: String?
    if let planned = layout.next, let reason = history.abandoned(planned) {
        guard planned.purpose != .unblockHide else {
            return Verdict(boundary: .reveal, next: .stop(WorkIssue(recovery: .awaitChange, message: reason + "; icons left accessible")),
                           history: history, layout: layout)
        }
        note = reason
    }
    assert(layout.leaks.isEmpty, "Only an unblockHide move removes a leak")
    let boundary: Boundary
    if !config.showHidden, !hidden.isEmpty, let proof = Separated(layout) { boundary = .hide(proof) } else { boundary = .reveal }
    return Verdict(boundary: boundary, next: .done(note: note), history: history, layout: layout)
}

// MARK: - Verdict

public struct Verdict: Sendable {
    /// What the separator must be after this step. The shell applies it before `next`.
    public let boundary: Boundary
    public let next: Next
    /// The history with this observation folded in. The shell stores it unconditionally.
    public let history: MoveHistory
    /// nil when the bar was incomplete, ambiguous or unregistered.
    public let layout: Layout?
}

public enum Boundary: Equatable, Sendable {
    case keep
    case reveal
    case hide(Separated)
}

/// Proof that no visible-group icon is left of the separator in a complete observed bar.
public struct Separated: Equatable, Sendable {
    fileprivate init?(_ layout: Layout) {
        guard layout.leaks.isEmpty else { return nil }
    }
}

public enum Next: Sendable {
    /// The pass applied. `note` names an abandoned order, as `lastError`.
    case done(note: String?)
    case stop(WorkIssue)
    /// Write these icons through ConfigStore.registerSnapshot, then wait for the watcher.
    case register([String: ItemMetadata], order: [String])
    /// The boundary is about to be revealed; let WindowServer settle, then gather.
    case settleThenGather
    /// Perform exactly this move, then gather. Never returned while a move is pending.
    case move(Move, Subject)
}

/// How the shell performs a move, resolved against this observation's frames.
public enum Subject: Equatable, Sendable {
    /// Tuck's own item: lower its preferred position by `shift` points.
    case own(OwnItem, shift: CGFloat)
    /// Another app's icon: a Command-drag between two hittable points.
    case icon(Drag)
}

public struct Drag: Equatable, Sendable {
    public let from: CGPoint
    public let to: CGPoint
}

// MARK: - Roster

/// Other apps' icons under config ids, left to right on the reference row.
public struct Roster: Sendable {
    public struct Icon: Sendable {
        public let id: String
        public let role: Role
        /// On the reference row, else on the first row the icon has a window on.
        public let frame: CGRect
        let onReference: Bool
        var metadata: ItemMetadata {
            ItemMetadata(bundleID: role.identity.bundle, label: role.label, item: role.identity.item, movable: role.movable)
        }
    }

    public let icons: [Icon]
    /// Ids more than one icon resolved to; their icons are left out of `icons`.
    public var collisions: [String] { aliases?.collisions ?? [] }
    let aliases: Aliases?
    private let bar: MenuBar

    /// Without `items`, ids are identity keys.
    public init(_ bar: MenuBar, items: [String: ItemMetadata]?) {
        self.bar = bar
        let reference = bar.referenceRow
        let located = bar.roles.compactMap { role -> (role: Role, frame: CGRect, onReference: Bool)? in
            for row in (reference.map { [$0] } ?? []) + Array(bar.rows.rows.indices) {
                if let frame = bar.frame(of: role, row: row) { return (role, frame, row == reference) }
            }
            return nil
        }
        let aliases = items.map { Aliases(located.map(\.role.identity), items: $0) }
        icons = located.enumerated().compactMap { index, entry in
            let id = aliases == nil ? entry.role.identity.key : aliases!.ids[index]
            return id.map { Icon(id: $0, role: entry.role, frame: entry.frame, onReference: entry.onReference) }
        }
        self.aliases = aliases
    }

    /// Movable icons and Tuck's own items on the reference row, left to right.
    var order: [String] {
        guard let row = bar.referenceRow else { return [] }
        let own = OwnItem.allCases.map { ($0.id, ownFrame($0, row: row).minX) }
        return (icons.filter { $0.role.movable && $0.onReference }.map { ($0.id, $0.frame.minX) } + own)
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    private func ownFrame(_ item: OwnItem, row: Int) -> CGRect {
        (item == .separator ? bar.rows.separator : bar.rows.control)[row].frame
    }

    private func frame(of id: String, row: Int) -> CGRect? {
        if let own = OwnItem(rawValue: id) { return ownFrame(own, row: row) }
        return icons.first { $0.id == id }.flatMap { bar.frame(of: $0.role, row: row) }
    }

    /// Just left of the first fixed icon right of every managed icon on the row.
    private func rightEdge(row: Int) -> CGFloat {
        let managed = icons.filter(\.role.movable).compactMap { bar.frame(of: $0.role, row: row) }
            + OwnItem.allCases.map { ownFrame($0, row: row) }
        let right = managed.map(\.maxX).max() ?? 0
        let fixed = icons.filter { !$0.role.movable }.compactMap { bar.frame(of: $0.role, row: row)?.minX }.filter { $0 >= right - 1 }
        return (fixed.min() ?? right) - 1
    }

    enum Resolution: Equatable { case reachable(Subject), unreachable(String) }

    /// Own items shift on the reference row. Another app's icon is dragged on the
    /// reference row, else on a wider display's row: the first replica whose midpoint
    /// and drop point are right of the display's usable left edge (the notch) and on it.
    func subject(for move: Move, reference: Int) -> Resolution {
        if let own = OwnItem(rawValue: move.id) {
            let target = move.before.flatMap { frame(of: $0, row: reference)?.minX } ?? rightEdge(row: reference)
            return .reachable(.own(own, shift: target - ownFrame(own, row: reference).maxX))
        }
        let rows = bar.rows
        // Mirrored displays share a row; each is tried with its own usable edge.
        let replicas = rows.rows.indices.flatMap { row -> [(row: Int, window: CGRect, display: Display)] in
            guard let window = frame(of: move.id, row: row) else { return [] }
            return rows.displays.filter {
                abs($0.frame.minY - window.minY) < 2 && $0.frame.minX <= window.midX && window.midX < $0.frame.maxX
            }.map { (row, window, $0) }
        }.sorted { ($0.row == reference ? 0 : 1, -$0.display.frame.width, $0.row) < ($1.row == reference ? 0 : 1, -$1.display.frame.width, $1.row) }
        guard !replicas.isEmpty else { return .unreachable("Menu bar display unavailable") }
        for replica in replicas {
            let end: CGFloat?
            if let before = move.before { end = frame(of: before, row: replica.row).map { $0.minX - 2 } } else { end = rightEdge(row: replica.row) }
            guard let end else { continue }
            let from = CGPoint(x: replica.window.midX, y: replica.window.midY)
            let to = CGPoint(x: end, y: replica.window.midY)
            let usable = replica.display.usableLeft
            guard from.x >= usable, to.x >= usable, replica.display.frame.contains(from), replica.display.frame.contains(to) else { continue }
            return .reachable(.icon(Drag(from: from, to: to)))
        }
        return .unreachable("Icon overflows the available menu bar; use a wider display")
    }
}

// MARK: - Config ids

/// Config ids for observed icons, in observation order. An icon takes the id of the one
/// config item with its bundle and item; otherwise its identity key, suffixed "#2",
/// "#3", ... past every id already in use. Icons that end on one id are all dropped.
struct Aliases: Equatable, Sendable {
    /// Per icon; nil for an icon whose id collided with another icon's.
    let ids: [String?]
    /// Ids more than one icon resolved to, sorted.
    let collisions: [String]

    init(_ icons: [IconIdentity], items: [String: ItemMetadata]) {
        var allocated = Set(items.keys)
        let resolved = icons.map { icon -> String in
            let matches = items.filter { $0.value.bundleID == icon.bundle && $0.value.item == icon.item }
            if matches.count == 1 { return matches.first!.key }
            var candidate = icon.key
            var suffix = 2
            while allocated.contains(candidate) { candidate = icon.key + "#" + String(suffix); suffix += 1 }
            allocated.insert(candidate)
            return candidate
        }
        let counts = Dictionary(resolved.map { ($0, 1) }, uniquingKeysWith: +)
        ids = resolved.map { counts[$0] == 1 ? $0 : nil }
        collisions = counts.filter { $0.value > 1 }.keys.sorted()
    }

    /// Why the observation cannot be used under this config; nil when every icon has its own id.
    var issue: WorkIssue? {
        collisions.isEmpty ? nil : WorkIssue(recovery: .retry,
            message: collisions.map { "Ambiguous config alias: " + $0 }.joined(separator: "; "))
    }
}

// MARK: - Layout analysis

enum LayoutError: Error, Equatable, CustomStringConvertible {
    case duplicateID(String)
    case separatorInPlacement
    case missingSeparator

    var description: String {
        switch self {
        case .duplicateID(let id): return "Duplicate layout ID '\(id)'."
        case .separatorInPlacement: return "The separator cannot also be a placed item."
        case .missingSeparator: return "The separator must be present in the observed layout."
        }
    }
}

enum Purpose: Equatable, Sendable {
    /// Removes a leak. Abandoning it blocks hiding.
    case unblockHide
    /// Moves a stray into the hidden group. Abandoning it leaves the icon visible.
    case tuck
    /// Order inside a group. Abandoning it changes nothing but the note.
    case cosmetic
}

/// The evidence a move was planned against. Any change of observed order, placement,
/// menu rows or displays is a new key, so strikes never need a manual reset. Displays
/// count on their own: a wider display can replace a narrow one at the same height.
struct AttemptKey: Equatable, Sendable {
    let order: [String]
    let target: [String]
    let rows: [CGFloat]
    let displays: [Display]

    init(order: [String], target: [String], rows: [CGFloat], displays: [Display] = []) {
        self.order = order; self.target = target; self.rows = rows
        self.displays = displays.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }
}

/// One planned move. The shell sees only its label; how to perform it is the `Subject`.
public struct Move: Equatable, Sendable {
    let id: String
    public let label: String
    /// Insert immediately before this id, or at the end when nil.
    let before: String?
    let purpose: Purpose
    let attempt: AttemptKey
}

/// The observed managed order and what it lacks. Target order: hidden ids present,
/// separator, visible ids present, control. Observed ids outside the placement are
/// never moved or used as anchors.
public struct Layout: Equatable, Sendable {
    /// The observed order this layout was computed from.
    public let order: [String]
    let target: [String]
    /// Visible-group ids (and the control) left of the separator. Hiding is unsafe
    /// while non-empty.
    let leaks: [String]
    /// Hidden-group ids right of the separator. They merely stay visible.
    let strays: [String]
    /// Moves by purpose, applicable one after another from `order`. Only the first
    /// move of the first non-empty list is ever executed; the shell then replans.
    let required: [Move]
    let tuck: [Move]
    let cosmetic: [Move]

    var next: Move? { required.first ?? tuck.first ?? cosmetic.first }

    /// `visible` excludes the control, which always ends the visible group.
    init(order: [String], hidden: [String], visible: [String], rows: [CGFloat], displays: [Display] = [],
                label: (String) -> String = { $0 }) throws {
        var placed: Set<String> = [OwnItem.control.id]
        for id in hidden + visible {
            guard id != OwnItem.separator.id else { throw LayoutError.separatorInPlacement }
            guard placed.insert(id).inserted else { throw LayoutError.duplicateID(id) }
        }
        var present = Set<String>()
        for id in order {
            guard present.insert(id).inserted else { throw LayoutError.duplicateID(id) }
        }
        guard present.contains(OwnItem.separator.id) else { throw LayoutError.missingSeparator }
        let partition = Partition(order: order, hidden: hidden, visible: visible)
        let key = AttemptKey(order: order, target: partition.target, rows: rows, displays: displays)
        let planned = plan(order: order, hidden: hidden, visible: visible)
        self.order = order
        target = partition.target
        leaks = partition.leaks(in: order)
        strays = partition.strays(in: order)
        required = planned.required.map { Move(id: $0.id, label: label($0.id), before: $0.before, purpose: .unblockHide, attempt: key) }
        tuck = planned.tuck.map { Move(id: $0.id, label: label($0.id), before: $0.before, purpose: .tuck, attempt: key) }
        cosmetic = planned.cosmetic.map { Move(id: $0.id, label: label($0.id), before: $0.before, purpose: .cosmetic, attempt: key) }
    }
}

// MARK: - Planning

struct PlannedMove: Equatable { let id: String; let before: String? }

/// The placement groups restricted to ids present in an observed order.
private struct Partition {
    let target: [String]
    let hidden: Set<String>
    let visible: Set<String>
    let rank: [String: Int]

    init(order: [String], hidden: [String], visible: [String]) {
        let present = Set(order)
        let control = OwnItem.control.id
        let hiddenPresent = hidden.filter(present.contains)
        let visiblePresent = visible.filter(present.contains) + (present.contains(control) ? [control] : [])
        target = hiddenPresent + [OwnItem.separator.id] + visiblePresent
        self.hidden = Set(hiddenPresent)
        self.visible = Set(visiblePresent)
        rank = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($0.element, $0.offset) })
    }

    func leaks(in order: [String]) -> [String] {
        let boundary = order.firstIndex(of: OwnItem.separator.id) ?? order.count
        return order[..<boundary].filter(visible.contains)
    }

    func strays(in order: [String]) -> [String] {
        guard let boundary = order.firstIndex(of: OwnItem.separator.id) else { return [] }
        return order[(boundary + 1)...].filter(hidden.contains)
    }

    func projection(_ order: [String]) -> [String] { order.filter { rank[$0] != nil } }

    func successor(of id: String) -> String? {
        let index = rank[id]! + 1
        return index < target.count ? target[index] : nil
    }

    /// A move that strictly reduces the number of leaks.
    func unblocking(_ order: [String], leaks: [String]) -> PlannedMove {
        if leaks.contains(OwnItem.control.id) {
            return PlannedMove(id: OwnItem.separator.id, before: order.first(where: visible.contains))
        }
        // Every target successor of the rightmost-in-target leak is right of the separator.
        let last = leaks.max { rank[$0]! < rank[$1]! }!
        return PlannedMove(id: last, before: successor(of: last))
    }
}

func applying(_ move: PlannedMove, to order: [String]) -> [String] {
    var result = order
    result.removeAll { $0 == move.id }
    let index = move.before.flatMap { result.firstIndex(of: $0) } ?? result.count
    result.insert(move.id, at: index)
    return result
}

/// Phased planner. Each list continues from the order the previous lists leave.
///  required: if the control is left of the separator, move the separator before the
///            leftmost visible-group item; else insert the rightmost-in-target leak
///            before its target successor. Each move strictly reduces the leaks.
///  tuck:     strays in reverse target order, each inserted before its target successor
///            (a hidden id or the separator), which is then left of the separator.
///  cosmetic: per side, a longest increasing subsequence of target ranks stays; the
///            rest move within their side. The separator and the control never move.
/// Inputs must already be validated by `Layout.init`.
func plan(order: [String], hidden: [String], visible: [String]) -> (required: [PlannedMove], tuck: [PlannedMove], cosmetic: [PlannedMove]) {
    let partition = Partition(order: order, hidden: hidden, visible: visible)
    var current = order

    var required: [PlannedMove] = []
    var leaks = partition.leaks(in: current)
    while !leaks.isEmpty && required.count <= partition.visible.count {
        let move = partition.unblocking(current, leaks: leaks)
        current = applying(move, to: current)
        let after = partition.leaks(in: current)
        assert(after.count < leaks.count, "A required move must reduce the leaks")
        leaks = after
        required.append(move)
    }

    var tuck: [PlannedMove] = []
    for stray in partition.strays(in: current).sorted(by: { partition.rank[$0]! > partition.rank[$1]! }) {
        let move = PlannedMove(id: stray, before: partition.successor(of: stray))
        current = applying(move, to: current)
        assert(partition.leaks(in: current).count == leaks.count, "A tuck move must not change the leaks")
        tuck.append(move)
    }
    assert(partition.strays(in: current).isEmpty)

    let projected = partition.projection(current)
    let control = OwnItem.control.id
    let controlIndex = projected.firstIndex(of: control) ?? projected.count
    var retained: Set<String> = [OwnItem.separator.id, control]
    retained.formUnion(increasingRun(projected.filter(partition.hidden.contains), rank: partition.rank))
    retained.formUnion(increasingRun(projected[..<controlIndex].filter { partition.visible.contains($0) && $0 != control },
                                     rank: partition.rank))
    var cosmetic: [PlannedMove] = []
    var anchor: String?
    for id in partition.target.reversed() {
        if !retained.contains(id) {
            let move = PlannedMove(id: id, before: anchor)
            current = applying(move, to: current)
            assert(partition.leaks(in: current).count == leaks.count, "A cosmetic move must not change the leaks")
            cosmetic.append(move)
        }
        anchor = id
    }
    assert(partition.projection(current) == partition.target, "The plan must reach the target")
    assert(partition.projection(order) != partition.target || required.isEmpty && tuck.isEmpty && cosmetic.isEmpty)
    return (required, tuck, cosmetic)
}

/// One deterministic longest subsequence of `ids` with increasing rank (patience sort).
private func increasingRun(_ ids: [String], rank: [String: Int]) -> Set<String> {
    let values = ids.map { rank[$0]! }
    var tails: [Int] = []
    var predecessors = Array(repeating: -1, count: ids.count)
    for i in values.indices {
        var low = 0
        var high = tails.count
        while low < high {
            let mid = (low + high) / 2
            if values[tails[mid]] < values[i] { low = mid + 1 } else { high = mid }
        }
        if low > 0 { predecessors[i] = tails[low - 1] }
        if low == tails.count { tails.append(i) } else { tails[low] = i }
    }
    var run = Set<String>()
    var cursor = tails.last ?? -1
    while cursor >= 0 {
        run.insert(ids[cursor])
        cursor = predecessors[cursor]
    }
    return run
}

// MARK: - Move history

/// The one state machine for move outcomes.
///
/// States:   idle | pending(move, reads), plus one strike slot
/// Inputs:   record(.began)    shell, when the effect reached the OS (mouse-down / rebuild)
///           record(.refused)  shell, when nothing was posted
///           observe(order)    once per gather
///
///   idle     --began(m)----------------------------------> pending(m, reads 0)
///   pending  --began-------------------------------------> assertion
///   pending  --observe(order != m's order, or goal met)--> idle                         (verified)
///   pending  --observe(unchanged), reads+1 < limit-------> pending(reads+1)              (wait)
///   pending  --observe(unchanged), reads+1 == limit------> idle, strike(m.attempt)       (no effect)
///   any      --refused(m, permanent)---------------------> same phase, strike(m.attempt, to limit if permanent)
///   idle     --observe-----------------------------------> idle
///
/// Strikes live in one slot keyed by `AttemptKey`; a strike on a different key
/// replaces the slot.
public struct MoveHistory: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case pending(Move, reads: Int)
    }
    struct Strikes: Equatable, Sendable { let key: AttemptKey; let count: Int; let reason: String }

    private(set) var phase: Phase = .idle
    private(set) var strikes: Strikes?

    public init() {}

    public enum Outcome: Sendable {
        case began(Move)
        case refused(Move, reason: String, permanent: Bool)
    }

    public func record(_ outcome: Outcome) -> MoveHistory {
        var next = self
        switch outcome {
        case .began(let move):
            assert(!pending, "A move began while an earlier move's outcome is unknown")
            next.phase = .pending(move, reads: 0)
        case .refused(let move, let reason, let permanent):
            next.strike(move.attempt, reason: reason, permanent: permanent)
        }
        return next
    }

    /// True while a posted move's effect is unverified.
    public var pending: Bool { if case .pending = phase { return true }; return false }

    /// Fold one observation of the managed order in. `goalMet` means the order equals the target.
    func observe(order: [String], goalMet: Bool) -> MoveHistory {
        guard case .pending(let move, let reads) = phase else { return self }
        var next = self
        if goalMet || order != move.attempt.order {
            next.phase = .idle
        } else if reads + 1 < Limits.unchangedReads {
            next.phase = .pending(move, reads: reads + 1)
        } else {
            next.phase = .idle
            next.strike(move.attempt, reason: "Could not move \(move.label); order left unchanged", permanent: false)
        }
        return next
    }

    /// The recorded reason once the move's attempt key has `Limits.attempts` strikes.
    func abandoned(_ move: Move) -> String? { abandoned(move.attempt) }

    func abandoned(_ key: AttemptKey) -> String? {
        guard let strikes, strikes.key == key, strikes.count >= Limits.attempts else { return nil }
        return strikes.reason
    }

    private mutating func strike(_ key: AttemptKey, reason: String, permanent: Bool) {
        let count = strikes.map { $0.key == key ? $0.count : 0 } ?? 0
        strikes = Strikes(key: key, count: permanent ? Limits.attempts : min(count + 1, Limits.attempts), reason: reason)
    }
}
