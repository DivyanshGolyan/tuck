import Foundation

public struct LayoutMove: Equatable, Sendable {
    public let id: String
    /// Insert immediately before this ID, or at the end when nil.
    public let before: String?
    public init(id: String, before: String?) { self.id = id; self.before = before }
}

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

public enum LayoutPlanner {
    /// Plans the minimum number of single-item moves in the managed projection of
    /// observed order. Offline desired IDs are ignored. Unknown observed IDs are never
    /// moved or used as anchors; their absolute position is not part of the goal.
    /// Apply the returned moves in order, removing each ID before inserting it.
    public static func plan(hidden: [String], visible: [String], observed: [String], separatorID: String) throws -> [LayoutMove] {
        var placed = Set<String>()
        for id in hidden + visible {
            guard id != separatorID else { throw LayoutError.separatorInPlacement }
            guard placed.insert(id).inserted else { throw LayoutError.duplicateID(id) }
        }
        var present = Set<String>()
        for id in observed {
            guard present.insert(id).inserted else { throw LayoutError.duplicateID(id) }
        }
        guard present.contains(separatorID) else { throw LayoutError.missingSeparator }
        let target = hidden.filter { present.contains($0) } + [separatorID] + visible.filter { present.contains($0) }
        let ranks = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($0.element, $0.offset) })
        let current = observed.filter { ranks[$0] != nil }
        let values = current.map { ranks[$0]! }
        // Patience sorting records one deterministic longest increasing subsequence.
        // Those items remain fixed; every other item must move in any valid plan.
        var tails: [Int] = []
        var predecessors = Array(repeating: -1, count: current.count)
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
        var retained = Set<String>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            retained.insert(current[cursor])
            cursor = predecessors[cursor]
        }
        var moves: [LayoutMove] = []
        var anchor: String?
        for id in target.reversed() {
            if !retained.contains(id) { moves.append(LayoutMove(id: id, before: anchor)) }
            anchor = id
        }
        return moves
    }
}
