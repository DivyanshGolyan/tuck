import CoreGraphics
import Foundation

struct WindowKey: Hashable, Sendable {
    let pid: Int32
    let id: UInt32
}

/// No AX, display filtering, visibility filtering, or menu-item title heuristics.
/// The caller chooses a worker; this synchronous read never polls or retries.
struct WindowLayoutSnapshot: Sendable {
    struct Window: Sendable {
        let key: WindowKey
        let frame: CGRect
        let onScreen: Bool

        init(key: WindowKey, frame: CGRect, onScreen: Bool = false) {
            self.key = key; self.frame = frame; self.onScreen = onScreen
        }
    }
    let windows: [Window]
    var keys: Set<WindowKey> { Set(windows.map(\.key)) }

    static func read() throws -> WindowLayoutSnapshot {
        guard let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ReadFailure.unavailable
        }
        return try WindowLayoutSnapshot(records: records)
    }

    init(windows: [Window]) { self.windows = windows }

    /// Every status-layer window in an already fetched window list.
    init(records: [[String: Any]]) throws {
        let layer = Int(CGWindowLevelForKey(.statusWindow))
        var windows: [Window] = []
        for record in records where (record[kCGWindowLayer as String] as? Int) == layer {
            guard let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  let id = record[kCGWindowNumber as String] as? UInt32,
                  let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), usable(frame) else {
                throw ReadFailure.malformed
            }
            windows.append(Window(key: WindowKey(pid: pid, id: id), frame: frame,
                onScreen: (record[kCGWindowIsOnscreen as String] as? Bool) ?? false))
        }
        self.windows = windows
    }

    enum ReadFailure: Error {
        case unavailable, malformed
    }
}

/// A projection of AX-verified logical roles onto all anchored physical rows.
/// The caller may reuse this only for visibility changes of the same verified
/// placement config. Window IDs can exchange rows, but cannot exchange roles.
struct VerifiedVisibilityLayout: Sendable {
    let allStatusKeys: Set<WindowKey>
    let knownOrder: [WindowKey]
    let row: CGFloat

    private struct Role: Sendable {
        let source: WindowKey
        let members: Set<WindowKey>
        let managed: Bool
    }
    private let rows: [CGFloat]
    private let ownPID: Int32
    private let roles: [Role]
    private let untracked: [WindowKey: WindowLayoutSnapshot.Window]

    init?(before: Set<WindowKey>, after: WindowLayoutSnapshot, icons: [BarIcon]) {
        guard before == after.keys, !icons.isEmpty,
              after.windows.count == after.keys.count,
              after.windows.allSatisfy({ usable($0.frame) }),
              Set(icons.map(\.id)).count == icons.count,
              Set(icons.map { WindowKey(pid: $0.pid, id: $0.windowID) }).count == icons.count,
              icons.allSatisfy({ usable($0.frame) }),
              let first = icons.first,
              icons.allSatisfy({ abs($0.frame.minY - first.frame.minY) < 2 }),
              let control = icons.first(where: { $0.id == Inventory.controlID }),
              let separator = icons.first(where: { $0.id == Inventory.separatorID }),
              control.pid == separator.pid else { return nil }
        let ordered = icons.sorted { $0.frame.minX < $1.frame.minX }
        let managed = ordered.filter { $0.movable || $0.id == Inventory.controlID || $0.id == Inventory.separatorID }
        guard strictlyOrdered(managed.map { $0.frame.minX }) else { return nil }
        let windows = Dictionary(uniqueKeysWithValues: after.windows.map { ($0.key, $0) })
        let controlKey = WindowKey(pid: control.pid, id: control.windowID)
        let separatorKey = WindowKey(pid: separator.pid, id: separator.windowID)
        guard let currentControl = windows[controlKey], let currentSeparator = windows[separatorKey],
              abs(currentControl.frame.width - control.frame.width) < 2,
              abs(currentSeparator.frame.width - currentControl.frame.width) >= 2 else { return nil }

        // Only our two differently-sized items identify the control anchors.
        // Display bounds are not evidence: observed row translations can differ
        // from the display width. Extra non-menu panels need not have anchors.
        let anchors = after.windows.filter {
            $0.key.pid == control.pid && abs($0.frame.width - currentControl.frame.width) < 2
        }.sorted { $0.frame.minY < $1.frame.minY }
        let physicalRows = anchors.map { $0.frame.minY }
        guard !anchors.isEmpty,
              zip(physicalRows, physicalRows.dropFirst()).allSatisfy({ $1 - $0 >= 2 }) else { return nil }
        func rowIndex(_ window: WindowLayoutSnapshot.Window) -> Int? {
            physicalRows.firstIndex { abs(window.frame.minY - $0) < 2 }
        }
        // A menu-shaped row without our control is incomplete projection
        // evidence, not a row whose replicas can silently become untracked.
        // A dormant row (see isDormantRow) is not such a row: its windows stay
        // untracked, and may neither move nor come on screen.
        guard after.windows.allSatisfy({
            !(16...64).contains($0.frame.height) || rowIndex($0) != nil
                || isDormantRow($0, in: after, ownPID: control.pid)
        }) else { return nil }
        var fixed: [WindowKey: Role] = [:]
        var fixedWindows: [WindowLayoutSnapshot.Window] = []
        var used: Set<WindowKey> = []
        for icon in ordered where !icon.movable && icon.id != Inventory.controlID && icon.id != Inventory.separatorID {
            let key = WindowKey(pid: icon.pid, id: icon.windowID)
            guard let source = windows[key], let sourceRow = rowIndex(source) else { return nil }
            var candidates = after.windows.filter {
                $0.key.pid == key.pid && abs($0.frame.width - source.frame.width) < 2 && rowIndex($0) != nil
            }
            func onePerRow() -> Bool { Set(candidates.compactMap(rowIndex)).count == candidates.count }
            if !onePerRow() {
                // One process can own several near-equal-width windows on a row
                // (Control Centre's button beside a dormant Now Playing). Width
                // alone is then ambiguous; only the control-relative slot decides.
                let offset = source.frame.minX - anchors[sourceRow].frame.minX
                candidates = candidates.filter { candidate in
                    rowIndex(candidate).map { abs(candidate.frame.minX - anchors[$0].frame.minX - offset) < 2 } == true
                }
            }
            let members = Set(candidates.map(\.key))
            guard members.contains(key), onePerRow(), used.isDisjoint(with: members) else { return nil }
            fixed[key] = Role(source: key, members: members, managed: false)
            fixedWindows.append(contentsOf: candidates)
            used.formUnion(members)
        }
        func normalizedX(_ window: WindowLayoutSnapshot.Window) -> CGFloat? {
            var x = window.frame.minX
            for item in fixedWindows where rowIndex(item) == rowIndex(window) {
                if item.frame.maxX <= window.frame.minX {
                    x -= item.frame.width
                } else if item.frame.minX < window.frame.maxX {
                    return nil
                }
            }
            return x
        }
        // Fixed system indicators can occupy different slots on mirrored rows.
        // Remove only their uniquely identified widths before comparing offsets.
        var projected: [Role] = []
        for icon in ordered {
            let sourceKey = WindowKey(pid: icon.pid, id: icon.windowID)
            if let role = fixed[sourceKey] { projected.append(role); continue }
            guard let source = windows[sourceKey], let sourceRow = rowIndex(source),
                  let sourceX = normalizedX(source), let anchorX = normalizedX(anchors[sourceRow]) else { return nil }
            let relativeX = sourceX - anchorX
            let candidates = after.windows.filter { candidate in
                guard candidate.key.pid == source.key.pid,
                      abs(candidate.frame.width - source.frame.width) < 2,
                      let index = rowIndex(candidate),
                      let x = normalizedX(candidate), let controlX = normalizedX(anchors[index]) else { return false }
                return abs(x - controlX - relativeX) < 2
            }
            let memberRows = candidates.compactMap(rowIndex)
            let members = Set(candidates.map(\.key))
            guard members.contains(sourceKey), Set(memberRows).count == candidates.count,
                  candidates.count == physicalRows.count, used.isDisjoint(with: members) else { return nil }
            projected.append(Role(source: sourceKey, members: members, managed: true))
            used.formUnion(members)
        }

        let managedWindows = projected.filter(\.managed).flatMap { $0.members.compactMap { windows[$0] } }
        func occupiesManagedGap(_ window: WindowLayoutSnapshot.Window) -> Bool {
            let neighbours = managedWindows.filter { rowIndex($0) == rowIndex(window) }
            return neighbours.filter { abs($0.frame.maxX - window.frame.minX) < 2 }.count == 1
                && neighbours.filter { abs($0.frame.minX - window.frame.maxX) < 2 }.count == 1
        }
        for role in fixed.values {
            guard let source = windows[role.source], let sourceRow = rowIndex(source) else { return nil }
            let offset = source.frame.minX - anchors[sourceRow].frame.minX
            for key in role.members {
                guard let candidate = windows[key], let index = rowIndex(candidate) else { return nil }
                let sameOffset = abs(candidate.frame.minX - anchors[index].frame.minX - offset) < 2
                guard sameOffset || (occupiesManagedGap(source) && occupiesManagedGap(candidate)) else { return nil }
            }
        }

        // Unknowns never become logical roles, even if they resemble replicas.
        let unknown = after.windows.filter { !used.contains($0.key) }
        allStatusKeys = before
        knownOrder = ordered.map { WindowKey(pid: $0.pid, id: $0.windowID) }
        row = first.frame.minY
        rows = physicalRows
        ownPID = control.pid
        roles = projected
        untracked = Dictionary(uniqueKeysWithValues: unknown.map { ($0.key, $0) })
        guard matches(after) else { return nil }
    }

    func matches(_ snapshot: WindowLayoutSnapshot) -> Bool { mismatchReason(snapshot) == nil }

    func mismatchReason(_ snapshot: WindowLayoutSnapshot) -> String? {
        guard snapshot.keys == allStatusKeys else { return "status-window membership changed" }
        guard snapshot.windows.count == snapshot.keys.count,
              snapshot.windows.allSatisfy({ usable($0.frame) }) else { return "invalid window snapshot" }
        let windows = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.key, $0) })
        func rowIndex(_ window: WindowLayoutSnapshot.Window) -> Int? {
            rows.firstIndex { abs(window.frame.minY - $0) < 2 }
        }
        guard snapshot.windows.allSatisfy({
            !(16...64).contains($0.frame.height) || rowIndex($0) != nil
                || isDormantRow($0, in: snapshot, ownPID: ownPID)
        }) else { return "menu row has no control anchor" }
        var managedByRow = Array(repeating: [(WindowKey, CGFloat)](), count: rows.count)
        for role in roles {
            var occupied: Set<Int> = []
            for key in role.members {
                guard let window = windows[key], let index = rowIndex(window), occupied.insert(index).inserted else {
                    return "logical role row membership changed"
                }
                if role.managed { managedByRow[index].append((role.source, window.frame.minX)) }
                // A previously distinct dormant window must not become an
                // ambiguous same-process overlay of a trusted logical role.
                if snapshot.windows.contains(where: {
                    !role.members.contains($0.key) && $0.key.pid == key.pid &&
                    rowIndex($0) == index && abs($0.frame.width - window.frame.width) < 2 &&
                    abs($0.frame.minX - window.frame.minX) < 2
                }) { return "ambiguous logical role geometry" }
            }
            if role.managed && occupied.count != rows.count { return "logical role replica missing" }
        }
        let managedOrder = roles.filter(\.managed).map(\.source)
        for projected in managedByRow {
            let ordered = projected.sorted { $0.1 < $1.1 }
            guard strictlyOrdered(ordered.map { $0.1 }), ordered.map({ $0.0 }) == managedOrder else {
                return "known window order changed"
            }
        }
        for (key, previous) in untracked {
            guard let window = windows[key] else { return "unknown window identity" }
            guard previous.onScreen == window.onScreen else { return "untracked visibility changed" }
            guard previous.frame.minY == window.frame.minY else { return "untracked row changed" }
            if rowIndex(previous) != nil {
                guard previous.frame == window.frame else { return "untracked geometry changed: pid=\(key.pid) window=\(key.id) \(previous.frame) -> \(window.frame)" }
                if window.onScreen && (16...64).contains(window.frame.height) {
                    return "untracked active menu-bar window"
                }
            }
        }
        return nil
    }
}

/// Stale replicas can linger at the menu row of a display arrangement that no
/// longer exists. Such a row shows nothing and holds none of our own items, so
/// it is neither a physical bar nor a partially built projection of one.
private func isDormantRow(_ window: WindowLayoutSnapshot.Window, in snapshot: WindowLayoutSnapshot, ownPID: Int32) -> Bool {
    !snapshot.windows.contains {
        abs($0.frame.minY - window.frame.minY) < 2 && ($0.onScreen || $0.key.pid == ownPID)
    }
}

private func usable(_ frame: CGRect) -> Bool {
    frame.origin.x.isFinite && frame.origin.y.isFinite &&
    frame.size.width.isFinite && frame.size.height.isFinite &&
    frame.size.width > 0 && frame.size.height > 0
}

private func strictlyOrdered(_ values: [CGFloat]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
}
