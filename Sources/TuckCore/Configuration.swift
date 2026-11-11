import Foundation

public struct ItemMetadata: Codable, Equatable, Sendable {
    public var bundleID: String
    public var label: String
    public var item: String?
    /// Descriptive adapter information, not a user override of platform constraints.
    public var movable: Bool?

    public init(bundleID: String, label: String, item: String? = nil, movable: Bool? = nil) {
        self.bundleID = bundleID
        self.label = label
        self.item = item
        self.movable = movable
    }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case duplicatePlacement(String)
    case unknownItem(String)
    case missingPlacement(String)
    case reservedID(String)
    case emptyMetadata(String, String)
    case duplicateSelector(String, String)
    case emptyID

    public var description: String {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported configuration version \(version); expected 1."
        case .duplicatePlacement(let id): return "Item '\(id)' appears more than once in visible/hidden."
        case .unknownItem(let id): return "Placement references '\(id)', but items has no metadata for it."
        case .missingPlacement(let id): return "Item '\(id)' must appear in visible or hidden."
        case .reservedID(let id): return "Item ID '\(id)' is reserved for Tuck controls."
        case .emptyMetadata(let id, let field): return "Item '\(id)' has an empty \(field)."
        case .duplicateSelector(let first, let second): return "Items '\(first)' and '\(second)' have the same bundleID/item selector."
        case .emptyID: return "Item IDs must not be empty."
        }
    }
}

public struct TuckConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var visible: [String]
    public var hidden: [String]
    public var items: [String: ItemMetadata]
    public var showHidden: Bool

    public init(version: Int = 1, visible: [String] = [], hidden: [String] = [], items: [String: ItemMetadata] = [:], showHidden: Bool = false) {
        self.version = version
        self.visible = visible
        self.hidden = hidden
        self.items = items
        self.showHidden = showHidden
    }

    private enum CodingKeys: String, CodingKey {
        case version, visible, hidden, items, showHidden
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        visible = try values.decode([String].self, forKey: .visible)
        hidden = try values.decode([String].self, forKey: .hidden)
        items = try values.decode([String: ItemMetadata].self, forKey: .items)
        // Only absence is legacy-compatible; null and incorrect types are errors.
        showHidden = values.contains(.showHidden) ? try values.decode(Bool.self, forKey: .showHidden) : false
    }

    public func validate() throws {
        guard version == 1 else { throw ConfigurationError.unsupportedVersion(version) }
        var seen = Set<String>()
        for id in visible + hidden {
            guard !id.isEmpty else { throw ConfigurationError.emptyID }
            guard seen.insert(id).inserted else { throw ConfigurationError.duplicatePlacement(id) }
            guard items[id] != nil else { throw ConfigurationError.unknownItem(id) }
        }
        var selectors: [Selector: String] = [:]
        for id in items.keys.sorted() {
            guard !id.isEmpty else { throw ConfigurationError.emptyID }
            guard id != "__tuck_separator__" && id != "__tuck_control__" else { throw ConfigurationError.reservedID(id) }
            guard seen.contains(id) else { throw ConfigurationError.missingPlacement(id) }
            let metadata = items[id]!
            guard !metadata.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.emptyMetadata(id, "bundleID") }
            guard !metadata.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError.emptyMetadata(id, "label") }
            let selector = Selector(bundleID: metadata.bundleID, item: metadata.item)
            if let previous = selectors[selector] { throw ConfigurationError.duplicateSelector(previous, id) }
            selectors[selector] = id
        }
    }

    /// Registers only unknown IDs, preserving existing metadata and relative order.
    /// By default new IDs append in supplied order, then lexical order. Opting into
    /// observed positions inserts each observed new ID before the next observed ID
    /// already in visible; hidden items are never anchors. Unobserved IDs append.
    /// The caller must exclude ambiguous discoveries.
    @discardableResult
    public mutating func register(_ discovered: [String: ItemMetadata], orderedIDs: [String]? = nil, preserveObservedPositions: Bool = false) throws -> Bool {
        try validate()
        let unknown = Set(discovered.keys.filter { items[$0] == nil })
        var appended = Set<String>()
        let ordered = (orderedIDs ?? []).filter { unknown.contains($0) && appended.insert($0).inserted }
        let newIDs = ordered + unknown.subtracting(appended).sorted()
        guard !newIDs.contains("") else { throw ConfigurationError.emptyID }
        var candidate = self
        var anchors: [String: String] = [:]
        if preserveObservedPositions {
            let existingVisible = Set(visible)
            var observedOnce = Set<String>()
            let observed = (orderedIDs ?? []).filter { observedOnce.insert($0).inserted }
            var nextVisible: String?
            for id in observed.reversed() {
                if existingVisible.contains(id) {
                    nextVisible = id
                } else if unknown.contains(id), let nextVisible {
                    anchors[id] = nextVisible
                }
            }
        }
        for id in newIDs {
            candidate.items[id] = discovered[id]
            if let anchor = anchors[id], let index = candidate.visible.firstIndex(of: anchor) {
                candidate.visible.insert(id, at: index)
            } else {
                candidate.visible.append(id)
            }
        }
        try candidate.validate()
        self = candidate
        return !newIDs.isEmpty
    }
}

private struct Selector: Hashable {
    let bundleID: String
    let item: String?
}
