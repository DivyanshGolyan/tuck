import CoreGraphics
import Foundation

// MARK: - Window list

public struct WindowKey: Hashable, Sendable {
    public let pid: Int32
    public let number: UInt32
    public init(pid: Int32, number: UInt32) { self.pid = pid; self.number = number }
}

/// One status-layer window, already parsed from a CG dictionary at the edge.
public struct StatusWindow: Hashable, Sendable {
    public let key: WindowKey
    public let frame: CGRect
    public let onScreen: Bool
    /// Public CG title. Empty for most third-party items; Tuck's own windows carry
    /// `OwnItem.separator.title` / `OwnItem.control.title` on their source window.
    public let title: String
    public init(key: WindowKey, frame: CGRect, onScreen: Bool, title: String = "") {
        self.key = key; self.frame = frame; self.onScreen = onScreen; self.title = title
    }
}

/// Every well-formed status-layer window in one CGWindowListCopyWindowInfo result:
/// keys unique, frames finite and positive. The only parser of the CG list is
/// `WindowList.read()` in Tuck/Pass.swift.
public struct WindowList: Sendable {
    /// "Could not read" is never "nothing there".
    public enum Fault: Error, Equatable, Sendable { case unavailable, malformed }
    public let windows: [StatusWindow]

    /// The well-formed subset: usable frames, first window per key.
    public init(skippingMalformed windows: [StatusWindow]) {
        var seen = Set<WindowKey>()
        self.windows = windows.filter { Self.usable($0.frame) && seen.insert($0.key).inserted }
    }

    private static func usable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.size.width.isFinite && frame.size.height.isFinite &&
        frame.size.width > 0 && frame.size.height > 0
    }
}

// MARK: - Tuck's own items

public enum OwnItem: String, CaseIterable, Sendable {
    case separator = "__tuck_separator__"
    case control = "__tuck_control__"
    public var id: String { rawValue }
    /// The CG public title AppKit gives the source window (from the autosave name).
    public var title: String { self == .separator ? "TuckSeparator" : "TuckControl" }
}

// MARK: - Displays and rows

public struct Display: Equatable, Sendable {
    public let frame: CGRect
    /// Leftmost x a synthetic click can hit in this display's menu row (right of the
    /// notch when there is one).
    public let usableLeft: CGFloat
    public init(frame: CGRect, usableLeft: CGFloat) { self.frame = frame; self.usableLeft = usableLeft }
}

let menuHeights: ClosedRange<CGFloat> = 16...64

/// The anchored menu rows of one window list. A row exists exactly where Tuck's control
/// has a window. Display bounds are not evidence: observed row translations can differ
/// from display geometry, and our own control is the only anchor we can identify.
///
/// Every window is on an anchored row (`row(of:) != nil`), on a dormant row (nothing
/// on screen there and none of Tuck's windows: a stale display arrangement), or
/// outside (not menu-height). A menu-height window anywhere else sets `fault`.
public struct MenuRows: Sendable {
    let list: WindowList
    let ownPID: Int32
    let displays: [Display]
    /// Row minY values, ascending, at least 2pt apart. Non-empty when `fault == nil`.
    public let rows: [CGFloat]
    /// Tuck's separator and control, one window per row, index-aligned with `rows`.
    public let separator: [StatusWindow]
    public let control: [StatusWindow]
    /// Non-nil means the list cannot describe a bar this pass. A bar built on it is incomplete.
    public let fault: String?
    /// The read behind `list` dropped malformed status records. A full pass may still
    /// use the rest; an observe-only hide must not.
    public let skippedMalformed: Bool
    private let byKey: [WindowKey: StatusWindow]
    private let byPID: [Int32: [StatusWindow]]

    public init(_ list: WindowList, ownPID: Int32, displays: [Display], skippedMalformed: Bool = false) {
        self.list = list
        self.ownPID = ownPID
        self.displays = displays
        self.skippedMalformed = skippedMalformed
        var byKey: [WindowKey: StatusWindow] = [:]
        var byPID: [Int32: [StatusWindow]] = [:]
        byKey.reserveCapacity(list.windows.count)
        for window in list.windows {
            byKey[window.key] = window
            byPID[window.key.pid, default: []].append(window)
        }
        self.byKey = byKey
        self.byPID = byPID
        (rows, separator, control, fault) = Self.anchor(list, own: byPID[ownPID] ?? [], ownPID: ownPID)
    }

    private static func anchor(_ list: WindowList, own: [StatusWindow], ownPID: Int32)
        -> (rows: [CGFloat], separator: [StatusWindow], control: [StatusWindow], fault: String?) {
        func failure(_ reason: String) -> ([CGFloat], [StatusWindow], [StatusWindow], String?) { ([], [], [], reason) }
        let controls = own.filter { $0.title == OwnItem.control.title }
        guard controls.count == 1, own.filter({ $0.title == OwnItem.separator.title }).count == 1,
              let source = controls.first else { return failure("Tuck's menu bar items not identified") }
        // Only our two differently sized items identify the control anchors; a
        // separator as wide as the control makes two anchors on one row.
        let anchors = own.filter { abs($0.frame.width - source.frame.width) < 2 }.sorted { $0.frame.minY < $1.frame.minY }
        let rows = anchors.map(\.frame.minY)
        guard zip(rows, rows.dropFirst()).allSatisfy({ $1 - $0 >= 2 }) else { return failure("ambiguous control anchors") }
        func row(_ window: StatusWindow) -> Int? { rows.firstIndex { abs(window.frame.minY - $0) < 2 } }
        // Tuck owns exactly two status items, so the separator replica on a row is
        // Tuck's one other window there, whatever width that row reports this instant.
        var separator: [StatusWindow] = []
        for (index, anchor) in anchors.enumerated() {
            let others = own.filter { row($0) == index && $0.key != anchor.key }
            guard others.count == 1 else { return failure("separator not identified on every menu row") }
            separator.append(others[0])
        }
        let sides = Set(zip(separator, anchors).map { ($0.frame.minX > $1.frame.minX ? 1 : 0) - ($0.frame.minX < $1.frame.minX ? 1 : 0) })
        guard sides.count == 1, !sides.contains(0) else { return failure("Tuck's items differ between menu rows") }
        // A row is dormant when nothing there is on screen and none of Tuck's windows is.
        let occupied = list.windows.filter { $0.onScreen || $0.key.pid == ownPID }.map(\.frame.minY)
        guard list.windows.allSatisfy({ window in
            !menuHeights.contains(window.frame.height) || row(window) != nil
                || !occupied.contains { abs($0 - window.frame.minY) < 2 }
        }) else { return failure("menu row has no control anchor") }
        return (rows, separator, anchors, nil)
    }

    func row(of window: StatusWindow) -> Int? {
        rows.firstIndex { abs(window.frame.minY - $0) < 2 }
    }

    /// True when the separator is at revealed width (< 100pt) on every row.
    var boundaryRevealed: Bool {
        fault == nil && !separator.isEmpty && separator.allSatisfy { $0.frame.width < 100 }
    }

    func window(_ key: WindowKey) -> StatusWindow? { byKey[key] }

    /// Every status window of one process, in list order: on anchored rows, dormant, or outside.
    func windows(of pid: Int32) -> [StatusWindow] { byPID[pid] ?? [] }

    /// A menu-height window on an anchored row: one that can be an icon.
    public func onBar(_ window: StatusWindow) -> Bool {
        menuHeights.contains(window.frame.height) && row(of: window) != nil
    }

    /// One process's windows that can be icons.
    public func barWindows(of pid: Int32) -> [StatusWindow] { windows(of: pid).filter(onBar) }

    /// Whether an AX frame lies near an anchored row. AX reports frames only on the
    /// active row; a frame anywhere else describes no bar this list knows.
    public func admits(_ axFrame: CGRect) -> Bool { rows.contains { abs(axFrame.minY - $0) < 64 } }
}
