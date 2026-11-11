import CoreGraphics
import Foundation

// MARK: - Bounds

/// Every numeric bound of the middle layer.
public enum Limits {
    /// Unchanged observations after a posted move before it counts as having had no effect.
    public static let unchangedReads = 3
    /// Strikes on one attempt key before its moves are abandoned.
    public static let attempts = 2
    /// Moves one pass may post.
    public static func passSteps(managed: Int) -> Int { max(4, 2 * managed) }
}

// MARK: - Layout analysis

public enum LayoutError: Error, Equatable, CustomStringConvertible {
    case duplicateID(String)
    case separatorInPlacement
    case missingSeparator

    public var description: String {
        switch self {
        case .duplicateID(let id): return "Duplicate layout ID '\(id)'."
        case .separatorInPlacement: return "The separator cannot also be a placed item."
        case .missingSeparator: return "The separator must be present in the observed layout."
        }
    }
}

public enum Purpose: Equatable, Sendable {
    /// Removes a leak. Abandoning it blocks hiding.
    case unblockHide
    /// Moves a stray into the hidden group. Abandoning it leaves the icon visible.
    case tuck
    /// Order inside a group. Abandoning it changes nothing but the note.
    case cosmetic
}

/// The evidence a move was planned against. Any change of observed order, placement
/// or display rows is a new key, so strikes never need a manual reset.
struct AttemptKey: Hashable, Sendable {
    let order: [String]
    let target: [String]
    let rows: [CGFloat]
}

public struct Move: Equatable, Sendable {
    public let id: String
    public let label: String
    /// Insert immediately before this id, or at the end when nil.
    public let before: String?
    public let purpose: Purpose
    let attempt: AttemptKey
}

/// The observed managed order and what it lacks. Target order: hidden ids present,
/// separator, visible ids present, control. Observed ids outside the placement are
/// never moved or used as anchors.
public struct Layout: Equatable, Sendable {
    /// The observed order this layout was computed from.
    public let order: [String]
    public let target: [String]
    /// Visible-group ids (and the control) left of the separator. Hiding is unsafe
    /// while non-empty.
    public let leaks: [String]
    /// Hidden-group ids right of the separator. They merely stay visible.
    public let strays: [String]
    /// Moves by purpose, applicable one after another from `order`. Only the first
    /// move of the first non-empty list is ever executed; the shell then replans.
    public let required: [Move]
    public let tuck: [Move]
    public let cosmetic: [Move]

    public var next: Move? { required.first ?? tuck.first ?? cosmetic.first }

    /// `visible` excludes the control, which always ends the visible group.
    public init(order: [String], hidden: [String], visible: [String], rows: [CGFloat],
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
        let key = AttemptKey(order: order, target: partition.target, rows: rows)
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
    public func observe(order: [String], goalMet: Bool) -> MoveHistory {
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
    public func abandoned(_ move: Move) -> String? { abandoned(move.attempt) }

    func abandoned(_ key: AttemptKey) -> String? {
        guard let strikes, strikes.key == key, strikes.count >= Limits.attempts else { return nil }
        return strikes.reason
    }

    private mutating func strike(_ key: AttemptKey, reason: String, permanent: Bool) {
        let count = strikes.map { $0.key == key ? $0.count : 0 } ?? 0
        strikes = Strikes(key: key, count: permanent ? Limits.attempts : min(count + 1, Limits.attempts), reason: reason)
    }
}
