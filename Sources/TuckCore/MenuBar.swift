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

/// Every status-layer window in one CGWindowListCopyWindowInfo result.
/// Invariants (checked here, trusted everywhere after): keys unique, frames finite
/// and positive. The only parser of the CG list is `WindowList.read()` in Tuck/Pass.swift.
public struct WindowList: Sendable {
    /// "Could not read" is never "nothing there".
    public enum Fault: Error, Equatable, Sendable { case unavailable, malformed }
    public let windows: [StatusWindow]

    /// Throws `.malformed` on duplicate keys or unusable frames.
    public init(_ windows: [StatusWindow]) throws {
        let kept = Self.wellFormed(windows)
        guard kept.count == windows.count else { throw Fault.malformed }
        self.windows = kept
    }

    /// The well-formed subset: usable frames, first window per key.
    public init(skippingMalformed windows: [StatusWindow]) {
        self.windows = Self.wellFormed(windows)
    }

    public var keys: Set<WindowKey> { Set(windows.map(\.key)) }

    private static func wellFormed(_ windows: [StatusWindow]) -> [StatusWindow] {
        var seen = Set<WindowKey>()
        return windows.filter { usable($0.frame) && seen.insert($0.key).inserted }
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

/// Candidates MUST already be restricted to this process's status-layer windows.
/// A unique named source establishes the role; only its width and the requested
/// physical row may select an unnamed replica. Offscreen separators are valid.
public func ownedStatusWindow(title: String, menuY: CGFloat, candidates: [StatusWindow]) -> StatusWindow? {
    let sources = candidates.filter { $0.title == title }
    guard sources.count == 1, let source = sources.first else { return nil }
    if abs(source.frame.minY - menuY) < 2 { return source }
    let replicas = candidates.filter {
        abs($0.frame.minY - menuY) < 2 && abs($0.frame.width - source.frame.width) < 2
    }
    return replicas.count == 1 ? replicas.first : nil
}

// MARK: - Icon identity

/// The natural key of an icon.
public struct IconIdentity: Hashable, Sendable {
    public let bundle: String
    public let item: String?
    public init(bundle: String, item: String?) { self.bundle = bundle; self.item = item }
    /// "bundle::item", or "bundle" when there is no item. The default config id.
    public var key: String { item.map { bundle + "::" + $0 } ?? bundle }
    /// Control Centre's fixed modules and Notification Centre cannot be dragged.
    public static func isMovable(bundle: String, item: String) -> Bool {
        if bundle == "com.apple.controlcenter" {
            return !["Clock", "BentoBox", "AudioVideoModule", "com.apple.menuextra.clock",
                     "com.apple.menuextra.controlcenter", "com.apple.menuextra.audiovideo"].contains(item)
        }
        return bundle != "com.apple.notificationcenterui"
    }
}

// MARK: - Matching primitives

/// Strict evidence tiers, not a nearest-window heuristic. Status windows can
/// overlap even in a single current CG snapshot (for example a dormant FocusModes
/// replica over Battery). A midpoint alone does not identify the owning window.
public func matchWindow(_ frame: CGRect, candidates: [StatusWindow], used: Set<WindowKey>) -> StatusWindow? {
    let exact = candidates.filter {
        abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 &&
        abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
    }
    if !exact.isEmpty { return exact.count == 1 && !used.contains(exact[0].key) ? exact[0] : nil }
    // AX can report a content inset rather than the entire status window. Require
    // containment of the WHOLE AX rect, and a unique candidate, not just its center.
    let containing = candidates.filter { $0.frame.insetBy(dx: -2, dy: -2).contains(frame) }
    return containing.count == 1 && !used.contains(containing[0].key) ? containing[0] : nil
}

/// Successful empty AX extras plus only never-observed offscreen CG windows is
/// not evidence of an accessible icon. Retain known hidden icons on AX loss,
/// but allow actual removal when no status windows remain.
public func shouldBlockEmptyExtras(candidates: [StatusWindow], hasLastGood: Bool) -> Bool {
    !candidates.isEmpty && (hasLastGood || candidates.contains(where: \.onScreen))
}
