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
    public let list: WindowList
    public let ownPID: Int32
    public let displays: [Display]
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

    public init(_ list: WindowList, ownPID: Int32, displays: [Display], skippedMalformed: Bool = false) {
        self.list = list
        self.ownPID = ownPID
        self.displays = displays
        self.skippedMalformed = skippedMalformed
        byKey = Dictionary(list.windows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        (rows, separator, control, fault) = Self.anchor(list, ownPID: ownPID)
    }

    private static func anchor(_ list: WindowList, ownPID: Int32)
        -> (rows: [CGFloat], separator: [StatusWindow], control: [StatusWindow], fault: String?) {
        func failure(_ reason: String) -> ([CGFloat], [StatusWindow], [StatusWindow], String?) { ([], [], [], reason) }
        let own = list.windows.filter { $0.key.pid == ownPID }
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
        guard list.windows.allSatisfy({
            !menuHeights.contains($0.frame.height) || row($0) != nil || isDormant($0, in: list, ownPID: ownPID)
        }) else { return failure("menu row has no control anchor") }
        return (rows, separator, anchors, nil)
    }

    private static func isDormant(_ window: StatusWindow, in list: WindowList, ownPID: Int32) -> Bool {
        !list.windows.contains { abs($0.frame.minY - window.frame.minY) < 2 && ($0.onScreen || $0.key.pid == ownPID) }
    }

    public func row(of window: StatusWindow) -> Int? {
        rows.firstIndex { abs(window.frame.minY - $0) < 2 }
    }

    /// True when the separator is at revealed width (< 100pt) on every row.
    public var boundaryRevealed: Bool {
        fault == nil && !separator.isEmpty && separator.allSatisfy { $0.frame.width < 100 }
    }

    func window(_ key: WindowKey) -> StatusWindow? { byKey[key] }

    /// Every status window of one process: on anchored rows, dormant, or outside.
    func windows(of pid: Int32) -> [StatusWindow] { list.windows.filter { $0.key.pid == pid } }
}

// MARK: - Processes and AX readings

/// A running app as the shell sees it. `incarnation` is the launch date, else the
/// kernel start time (Control Centre has no launch date).
public struct AppProcess: Hashable, Sendable {
    public let pid: Int32
    public let bundle: String
    public let name: String
    public let incarnation: String
    public init(pid: Int32, bundle: String, name: String, incarnation: String) {
        self.pid = pid; self.bundle = bundle; self.name = name; self.incarnation = incarnation
    }
}

/// What AX said about one extras-menu-bar child.
public struct AXElementReading: Sendable {
    /// nil when AX gave no usable position and size.
    public var frame: CGRect?
    public let identifier: String?
    /// The item this exact AXUIElement was bound to before (the shell's element cache).
    public let remembered: String?
    /// iStat compatibility item, computed at the edge from the AX title via StatusItemIdentity.
    public let compatibility: String?
    /// Control Centre only, for labels.
    public let description: String?
    public init(frame: CGRect?, identifier: String?, remembered: String?, compatibility: String?, description: String?) {
        self.frame = frame; self.identifier = identifier; self.remembered = remembered
        self.compatibility = compatibility; self.description = description
    }
}

/// One app's identities, bound to window keys.
public struct AppReading: Sendable {
    public let app: AppProcess
    public let outcome: Outcome

    public init(app: AppProcess, outcome: Outcome) { self.app = app; self.outcome = outcome }

    public enum Outcome: Sendable {
        /// Every element matched a unique window and has an identity (or is the app's only icon).
        case clean([BoundIcon])
        /// The read finished but something is ambiguous; carries what did bind and why not all.
        case unclear([BoundIcon], [WorkIssue])
        /// The read itself failed (timeout, invalid element, budget, permission).
        case failed(WorkIssue)
    }

    public struct BoundIcon: Equatable, Sendable {
        public let identity: IconIdentity
        public let label: String
        public let movable: Bool
        public let window: WindowKey
        /// Index into the elements passed to `bind`, so the shell can refresh its
        /// AXUIElement -> item cache without the core holding AX objects.
        public let element: Int
        public init(identity: IconIdentity, label: String, movable: Bool, window: WindowKey, element: Int) {
            self.identity = identity; self.label = label; self.movable = movable; self.window = window; self.element = element
        }
    }

    /// Binds AX elements to this app's freshly sampled windows (menu-height, on an
    /// anchored row). Matching is `matchWindow`: never nearest. Identity is identifier,
    /// else window title (only when the app's windows carry several distinct titles),
    /// else compatibility, else remembered. Several icons where one lacks an identity is
    /// an awaitChange issue; empty extras that `shouldBlockEmptyExtras` rejects is a
    /// retry issue. An element frame off every anchored row fails the reading.
    ///
    /// Returns nil when some element matched no window and `finalAttempt` is false: the
    /// shell then re-reads the element frames and the app's windows once and calls again
    /// with `finalAttempt: true`. That bounded re-sample is the only retry.
    public static func bind(app: AppProcess, elements: [AXElementReading], windows: [StatusWindow],
                            titles: [WindowKey: String], rows: MenuRows, hadIcons: Bool,
                            finalAttempt: Bool) -> AppReading? {
        let name = app.name
        guard elements.allSatisfy({ element in
            element.frame.map { frame in rows.rows.contains { abs(frame.minY - $0) < 64 } } ?? true
        }) else {
            return failed(app, WorkIssue(recovery: .retry, message: "Accessibility geometry is outside current menu rows"))
        }
        let candidates = windows.filter {
            $0.key.pid == app.pid && menuHeights.contains($0.frame.height) && rows.row(of: $0) != nil
        }
        var used = Set<WindowKey>()
        var matches: [StatusWindow?] = []
        for element in elements {
            let match = element.frame.flatMap { matchWindow($0, candidates: candidates, used: used) }
            if let match { used.insert(match.key) }
            matches.append(match)
        }
        if !finalAttempt && zip(elements, matches).contains(where: { $0.frame != nil && $1 == nil }) { return nil }

        // Titles enrich a uniquely matched window; they never select it.
        func title(_ window: StatusWindow) -> String? {
            let title = window.title.isEmpty ? titles[window.key] ?? "" : window.title
            return title.isEmpty ? nil : title
        }
        let titled = candidates.compactMap { window in title(window).map { (window: window, title: $0) } }
        let distinctTitles = Set(titled.map(\.title))
        func rightGap(_ frame: CGRect) -> CGFloat? {
            let matching = rows.displays.filter { abs(frame.minY - $0.frame.minY) < 2 }
            guard let display = matching.first(where: { $0.frame.minX <= frame.midX && frame.midX < $0.frame.maxX })
                    ?? matching.first else { return nil }
            return display.frame.maxX - frame.maxX
        }
        func item(for window: StatusWindow) -> String? {
            if let title = title(window) { return title }
            guard let gap = rightGap(window.frame) else { return nil }
            let peers = Set(titled.filter {
                abs($0.window.frame.width - window.frame.width) < 2 && rightGap($0.window.frame).map { abs($0 - gap) < 2 } == true
            }.map(\.title))
            return peers.count == 1 ? peers.first : nil
        }

        var icons: [BoundIcon] = []
        var issues: [WorkIssue] = []
        func note(_ recovery: Recovery, _ message: String) {
            if !issues.contains(where: { $0.message == message }) { issues.append(WorkIssue(recovery: recovery, message: message)) }
        }
        for (index, element) in elements.enumerated() {
            guard element.frame != nil else { note(.retry, "\(name): accessibility geometry unavailable"); continue }
            guard let window = matches[index] else { note(.retry, "\(name): ambiguous window match"); continue }
            let identity = element.identifier ?? (distinctTitles.count > 1 ? item(for: window) : nil)
                ?? element.compatibility ?? element.remembered
            if elements.count > 1 && identity == nil {
                note(.awaitChange, "\(name): multiple icons without stable identifiers"); continue
            }
            let detail = app.bundle == "com.apple.controlcenter" ? element.description ?? identity ?? "icon" : identity ?? "icon"
            icons.append(BoundIcon(identity: IconIdentity(bundle: app.bundle, item: identity),
                                   label: elements.count > 1 ? "\(name) — \(detail)" : name,
                                   movable: IconIdentity.isMovable(bundle: app.bundle, item: identity ?? title(window) ?? ""),
                                   window: window.key, element: index))
        }
        if elements.isEmpty && shouldBlockEmptyExtras(candidates: candidates, hasLastGood: hadIcons) {
            note(.retry, "\(name): accessibility inventory unavailable")
        }
        return AppReading(app: app, outcome: issues.isEmpty ? .clean(icons) : .unclear(icons, issues))
    }

    public static func failed(_ app: AppProcess, _ issue: WorkIssue) -> AppReading {
        AppReading(app: app, outcome: .failed(issue))
    }
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

// MARK: - The bar

/// One icon and its replicas: `members[i]` is its window on `rows.rows[i]`. A role is
/// `grouped` when its replicas were found by the control-relative offset rule and are
/// still one per row (every row for a movable icon; fixed indicators may be absent
/// from some rows). An ungrouped role keeps only its bound window and makes its app
/// stale on every pass.
public struct Role: Sendable {
    public let identity: IconIdentity
    public let label: String
    public let movable: Bool
    public let pid: Int32
    public let members: [WindowKey?]
    public let grouped: Bool
}

/// What "nothing changed" means for one app; `==` is the question. Role members
/// contribute only their keys, so their frames may change freely (separator width,
/// hidden icons shifted 10_000pt, rows exchanging replicas). Every other status window
/// of the app contributes its exact row, on-screen state and, on an anchored row, its
/// exact frame: a ghost that wakes up or moves is new evidence.
struct AppEvidence: Equatable, Sendable {
    let incarnation: String
    let keys: Set<WindowKey>
    let loose: [WindowKey: LooseState]
    struct LooseState: Equatable, Sendable { let minY: CGFloat; let onScreen: Bool; let frame: CGRect? }

    init(incarnation: String, pid: Int32, members: Set<WindowKey>, rows: MenuRows) {
        let windows = rows.windows(of: pid)
        self.incarnation = incarnation
        keys = Set(windows.map(\.key))
        loose = Dictionary(windows.filter { !members.contains($0.key) }.map { window in
            (window.key, LooseState(minY: window.frame.minY, onScreen: window.onScreen,
                                    frame: rows.row(of: window) == nil ? nil : window.frame))
        }, uniquingKeysWith: { first, _ in first })
    }

    func change(to now: AppEvidence) -> String? {
        guard now != self else { return nil }
        guard keys == now.keys else { return "status-window membership changed" }
        for (key, before) in loose.sorted(by: { $0.key.number < $1.key.number }) {
            guard let after = now.loose[key] else { return "status-window membership changed" }
            if before.onScreen != after.onScreen { return "untracked visibility changed" }
            if before.minY != after.minY || (before.frame == nil) != (after.frame == nil) { return "untracked row changed" }
            if let old = before.frame, let new = after.frame, old != new {
                return "untracked geometry changed: pid=\(key.pid) window=\(key.number) \(old) -> \(new)"
            }
        }
        return "process restarted"
    }
}

public struct MenuBar: Sendable {
    /// The bar before the first observation: no bindings, so every app is stale.
    public static let none = MenuBar(rows: MenuRows(WindowList(skippingMalformed: []), ownPID: 0, displays: []),
                                     roles: [], issues: [], activeRow: nil, bindings: [:], reusable: false)

    public let rows: MenuRows
    /// Icons of other apps, left to right on the reference row.
    public let roles: [Role]
    /// Non-empty means incomplete: never a visibility command (except reveal).
    /// Includes "<app>: not read (<stale reason>)" for every stale app without a reading.
    public let issues: [WorkIssue]
    /// Row index the last AX reading landed on; nil until some app was read.
    public let activeRow: Int?
    /// The post-apply audit is not wired yet; this stays 0.
    public let auditMismatches = 0
    /// True when the next pass over an unchanged list would read no app.
    public let reusable: Bool

    /// Per app, the reading that produced its roles, with the evidence it was read
    /// under. Only a clean reading creates or replaces one; a failed or unclear reading
    /// keeps it (never publish disappearance) but marks it not reusable.
    struct Binding: Sendable {
        let evidence: AppEvidence
        let icons: [AppReading.BoundIcon]
        /// Per icon, the replicas grouped when it was bound; nil when it could not be grouped.
        let groups: [Set<WindowKey>?]
        var reusable: Bool
        var members: Set<WindowKey> {
            zip(icons, groups).reduce(into: []) { $0.formUnion($1.1 ?? [$1.0.window]) }
        }
    }
    let bindings: [Int32: Binding]

    private init(rows: MenuRows, roles: [Role], issues: [WorkIssue], activeRow: Int?,
                 bindings: [Int32: Binding], reusable: Bool) {
        self.rows = rows; self.roles = roles; self.issues = issues; self.activeRow = activeRow
        self.bindings = bindings; self.reusable = reusable
    }

    public var complete: Bool { issues.isEmpty && rows.fault == nil }

    /// Movable icons' identity keys and Tuck's own ids, left to right on the reference
    /// row (`activeRow`, else the first). Empty when the rows are faulty.
    public var order: [String] {
        guard rows.fault == nil, !rows.rows.isEmpty else { return [] }
        let row = activeRow.flatMap { $0 < rows.rows.count ? $0 : nil } ?? 0
        let icons = roles.filter { $0.grouped && $0.movable }.compactMap { role in
            frame(of: role, row: row).map { (role.identity.key, $0.minX) }
        }
        let own = [(OwnItem.separator.id, rows.separator[row].frame.minX), (OwnItem.control.id, rows.control[row].frame.minX)]
        return (icons + own).sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Frame of a role on a row, from this pass's list. nil when it has no window there.
    public func frame(of role: Role, row: Int) -> CGRect? {
        guard role.members.indices.contains(row), let key = role.members[row] else { return nil }
        return rows.window(key)?.frame
    }

    /// The "nothing changed" question every pass asks. An app needs an AX read iff it
    /// has status windows and no binding, its incarnation changed, its last reading was
    /// not clean, its `AppEvidence` changed, one of its roles is ungrouped or lost a
    /// replica or its row set, a same-pid window overlays a member, it shows a window on
    /// an anchored row that is no role, its identity is duplicated, or its icons are in a
    /// different order on some row. Returns pid -> human reason.
    public func staleApps(in rows: MenuRows, running: [AppProcess]) -> [Int32: String] {
        Self.survey(rows, running: running, bindings: bindings).stale
    }

    /// Build this pass's bar. `readings` should cover every app `staleApps` named; any it
    /// does not cover becomes an issue, never a guess. With no readings the bar is
    /// complete exactly when `staleApps` is empty and the rows have no fault.
    public static func observe(_ rows: MenuRows, running: [AppProcess], readings: [AppReading],
                               previous: MenuBar) -> MenuBar {
        let live = Dictionary(running.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = previous.staleApps(in: rows, running: running)
        var bindings = previous.bindings.filter { live[$0.key]?.incarnation == $0.value.evidence.incarnation }
        var issues: [WorkIssue] = []
        var fresh: [Int32: [AppReading.BoundIcon]] = [:]
        var read = Set<Int32>()
        for reading in readings {
            guard let app = live[reading.app.pid], app.incarnation == reading.app.incarnation,
                  app.pid != rows.ownPID else { continue }
            read.insert(app.pid)
            fresh[app.pid] = nil
            switch reading.outcome {
            case .clean(let icons):
                fresh[app.pid] = icons
            case .unclear(_, let found):
                issues += found
                bindings[app.pid]?.reusable = false
            case .failed(let issue):
                issues.append(WorkIssue(recovery: issue.recovery, message: "\(app.name): \(issue.message)"))
                bindings[app.pid]?.reusable = false
            }
        }

        // AX reports one active row. Readings that landed on different rows, or on
        // windows this list does not have, are not bound.
        let landed = fresh.values.joined().map { rows.window($0.window).flatMap(rows.row(of:)) }
        var activeRow = previous.activeRow.flatMap { $0 < rows.rows.count ? $0 : nil }
        if landed.contains(where: { $0 == nil }) || Set(landed).count > 1 {
            issues.append(WorkIssue(recovery: .retry, message: landed.contains(where: { $0 == nil })
                ? "Status geometry changed during read" : "Waiting for a coherent active menu bar"))
            for pid in fresh.keys { bindings[pid]?.reusable = false }
            fresh = [:]
        } else if let row = landed.compactMap({ $0 }).first {
            activeRow = row
        }

        let groups = group(fresh, carried: bindings, rows: rows)
        for (pid, icons) in fresh {
            let assigned = groups[pid] ?? Array(repeating: nil, count: icons.count)
            let members = zip(icons, assigned).reduce(into: Set<WindowKey>()) { $0.formUnion($1.1 ?? [$1.0.window]) }
            bindings[pid] = Binding(evidence: AppEvidence(incarnation: live[pid]!.incarnation, pid: pid, members: members, rows: rows),
                                    icons: icons, groups: assigned, reusable: true)
        }
        for (pid, reason) in stale where !read.contains(pid) {
            if let app = live[pid] { issues.append(WorkIssue(recovery: .retry, message: "\(app.name): not read (\(reason))")) }
        }

        let after = survey(rows, running: running, bindings: bindings)
        if after.disordered { issues.append(WorkIssue(recovery: .retry, message: "known window order changed")) }
        for key in after.duplicates { issues.append(WorkIssue(recovery: .awaitChange, message: "\(key): ambiguous identity")) }
        var seen = Set<String>()
        issues = issues.filter { seen.insert($0.message).inserted }
            .sorted { ($0.message, $0.recovery.rawValue) < ($1.message, $1.recovery.rawValue) }

        let reference = activeRow ?? 0
        func x(_ role: Role) -> CGFloat {
            let key = role.members.indices.contains(reference) ? role.members[reference] : nil
            return (key ?? role.members.compactMap { $0 }.first).flatMap { rows.window($0)?.frame.minX } ?? .infinity
        }
        let roles = after.roles.sorted { x($0) < x($1) }
        return MenuBar(rows: rows, roles: roles, issues: issues, activeRow: activeRow, bindings: bindings,
                       reusable: issues.isEmpty && rows.fault == nil && after.stale.isEmpty)
    }

    // MARK: Survey

    private struct Survey {
        var roles: [Role] = []
        var stale: [Int32: String] = [:]
        var disordered = false
        var duplicates: [String] = []
        mutating func mark(_ pid: Int32, _ reason: String) { if stale[pid] == nil { stale[pid] = reason } }
    }

    /// Roles from carried bindings and the current list, and every app that cannot vouch
    /// for itself. Mirrors VerifiedVisibilityLayout.mismatchReason, per app.
    private static func survey(_ rows: MenuRows, running: [AppProcess], bindings: [Int32: Binding]) -> Survey {
        var survey = Survey()
        let live = Dictionary(running.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Set(rows.list.windows.map(\.key.pid))
        for pid in bindings.keys.sorted() where live[pid].map({ $0.incarnation != bindings[pid]!.evidence.incarnation }) == true {
            survey.mark(pid, "process restarted")
        }
        for app in running where app.pid != rows.ownPID && bindings[app.pid] == nil && present.contains(app.pid) {
            survey.mark(app.pid, "not yet read")
        }

        for pid in bindings.keys.sorted() {
            guard let binding = bindings[pid], live[pid]?.incarnation == binding.evidence.incarnation else { continue }
            if !binding.reusable { survey.mark(pid, "previous read incomplete") }
            let members = binding.members
            if let change = binding.evidence.change(to: AppEvidence(incarnation: binding.evidence.incarnation, pid: pid,
                                                                     members: members, rows: rows)) {
                survey.mark(pid, change)
            }
            for (icon, group) in zip(binding.icons, binding.groups) {
                let keys = group ?? [icon.window]
                var slots = [WindowKey?](repeating: nil, count: rows.rows.count)
                var grouped = group != nil
                if !grouped { survey.mark(pid, "icon not grouped across rows") }
                for key in keys.sorted(by: { $0.number < $1.number }) {
                    guard let window = rows.window(key), let index = rows.row(of: window), slots[index] == nil else {
                        grouped = false
                        survey.mark(pid, "logical role row membership changed")
                        continue
                    }
                    slots[index] = key
                    // A previously distinct same-process window must not become an
                    // ambiguous overlay of a trusted role.
                    if rows.list.windows.contains(where: {
                        !keys.contains($0.key) && $0.key.pid == pid && rows.row(of: $0) == index &&
                        abs($0.frame.width - window.frame.width) < 2 && abs($0.frame.minX - window.frame.minX) < 2
                    }) { survey.mark(pid, "ambiguous logical role geometry") }
                }
                if icon.movable && slots.contains(where: { $0 == nil }) {
                    grouped = false
                    survey.mark(pid, "logical role replica missing")
                }
                survey.roles.append(Role(identity: icon.identity, label: icon.label, movable: icon.movable,
                                         pid: pid, members: slots, grouped: grouped))
            }
            if rows.windows(of: pid).contains(where: {
                !members.contains($0.key) && $0.onScreen && menuHeights.contains($0.frame.height) && rows.row(of: $0) != nil
            }) { survey.mark(pid, "untracked active menu-bar window") }
        }

        for (identity, roles) in Dictionary(grouping: survey.roles, by: \.identity) where roles.count > 1 {
            survey.duplicates.append(identity.key)
            for role in roles { survey.mark(role.pid, "\(identity.key): ambiguous identity") }
        }
        survey.duplicates.sort()

        // Managed order (movable icons and Tuck's items) must agree on every row.
        guard rows.fault == nil, !rows.rows.isEmpty else { return survey }
        let managed = survey.roles.filter { $0.grouped && $0.movable }
        struct Item { let id: Int; let pid: Int32?; let x: CGFloat }
        let sequences = rows.rows.indices.map { row -> [Item] in
            let icons = managed.enumerated().compactMap { index, role in
                role.members[row].flatMap(rows.window).map { Item(id: index, pid: role.pid, x: $0.frame.minX) }
            }
            let own = [Item(id: -1, pid: nil, x: rows.separator[row].frame.minX),
                       Item(id: -2, pid: nil, x: rows.control[row].frame.minX)]
            return (icons + own).sorted { $0.x < $1.x }
        }
        let rank = Dictionary(uniqueKeysWithValues: sequences[0].enumerated().map { ($1.id, $0) })
        for sequence in sequences {
            for i in sequence.indices {
                for j in sequence.indices where j > i {
                    let a = sequence[i], b = sequence[j]
                    guard !(a.x < b.x) || rank[a.id]! > rank[b.id]! else { continue }
                    survey.disordered = true
                    for pid in [a.pid, b.pid].compactMap({ $0 }) { survey.mark(pid, "known window order changed") }
                }
            }
        }
        return survey
    }

    // MARK: Replica grouping

    /// Groups each fresh icon's replicas, ported from VerifiedVisibilityLayout:
    ///  1. fixed indicators by width, narrowed to the control-relative slot when one
    ///     process has several near-equal-width windows on a row;
    ///  2. every movable icon by its control-relative offset with fixed indicators'
    ///     widths removed (they can sit in different slots on mirrored rows), one member
    ///     on every row;
    ///  3. each fixed member at the same control-relative offset, or in an exact gap
    ///     between managed windows on both its source row and its own row.
    /// Members are never shared within an app. An app with any icon that fails is
    /// ungrouped as a whole, and grouping repeats without its replicas until stable.
    private static func group(_ fresh: [Int32: [AppReading.BoundIcon]], carried: [Int32: Binding],
                              rows: MenuRows) -> [Int32: [Set<WindowKey>?]] {
        guard rows.fault == nil, !fresh.isEmpty else { return [:] }
        let anchors = rows.control
        func row(_ window: StatusWindow) -> Int? { rows.row(of: window) }
        func onePerRow(_ windows: [StatusWindow]) -> Bool { Set(windows.compactMap(row)).count == windows.count }

        var carriedFixed: [StatusWindow] = []
        var carriedManaged = rows.separator + rows.control
        for (pid, binding) in carried where fresh[pid] == nil {
            for (icon, group) in zip(binding.icons, binding.groups) {
                let windows = (group ?? [icon.window]).compactMap(rows.window)
                if icon.movable { carriedManaged += windows } else { carriedFixed += windows }
            }
        }
        struct Entry { let pid: Int32; let index: Int; let icon: AppReading.BoundIcon; let source: StatusWindow? }
        let entries = fresh.flatMap { pid, icons in
            icons.enumerated().map { Entry(pid: pid, index: $0, icon: $1, source: rows.window($1.window)) }
        }.sorted {
            ($0.source?.frame.minX ?? .infinity, $0.pid, $0.index) < ($1.source?.frame.minX ?? .infinity, $1.pid, $1.index)
        }

        var failed = Set<Int32>()
        while true {
            var groups = fresh.mapValues { [Set<WindowKey>?](repeating: nil, count: $0.count) }
            var used: [Int32: Set<WindowKey>] = [:]
            var failures = Set<Int32>()
            func claim(_ entry: Entry, _ members: [StatusWindow]) -> Bool {
                let keys = Set(members.map(\.key))
                guard used[entry.pid, default: []].isDisjoint(with: keys) else { return false }
                used[entry.pid, default: []].formUnion(keys)
                groups[entry.pid]![entry.index] = keys
                return true
            }

            var fixedWindows = carriedFixed
            var fixedRoles: [(entry: Entry, source: StatusWindow, members: [StatusWindow])] = []
            for entry in entries where !entry.icon.movable {
                if failed.contains(entry.pid) { fixedWindows += [entry.source].compactMap { $0 }; continue }
                guard let source = entry.source, let sourceRow = row(source) else { failures.insert(entry.pid); continue }
                var candidates = rows.list.windows.filter {
                    $0.key.pid == entry.pid && abs($0.frame.width - source.frame.width) < 2 && row($0) != nil
                }
                if !onePerRow(candidates) {
                    // One process can own several near-equal-width windows on a row
                    // (Control Centre's button beside a dormant Now Playing). Width
                    // alone is then ambiguous; only the control-relative slot decides.
                    let offset = source.frame.minX - anchors[sourceRow].frame.minX
                    candidates = candidates.filter { candidate in
                        row(candidate).map { abs(candidate.frame.minX - anchors[$0].frame.minX - offset) < 2 } == true
                    }
                }
                guard candidates.contains(source), onePerRow(candidates), claim(entry, candidates) else {
                    failures.insert(entry.pid); continue
                }
                fixedWindows += candidates
                fixedRoles.append((entry, source, candidates))
            }
            guard failures.isEmpty else { failed.formUnion(failures); continue }

            func normalizedX(_ window: StatusWindow) -> CGFloat? {
                var x = window.frame.minX
                for item in fixedWindows where row(item) == row(window) {
                    if item.frame.maxX <= window.frame.minX {
                        x -= item.frame.width
                    } else if item.frame.minX < window.frame.maxX {
                        return nil
                    }
                }
                return x
            }
            var managed = carriedManaged
            for entry in entries where entry.icon.movable {
                if failed.contains(entry.pid) { managed += [entry.source].compactMap { $0 }; continue }
                guard let source = entry.source, let sourceRow = row(source), let sourceX = normalizedX(source),
                      let anchorX = normalizedX(anchors[sourceRow]) else { failures.insert(entry.pid); continue }
                let relativeX = sourceX - anchorX
                let candidates = rows.list.windows.filter { candidate in
                    guard candidate.key.pid == entry.pid, abs(candidate.frame.width - source.frame.width) < 2,
                          let index = row(candidate), let x = normalizedX(candidate),
                          let controlX = normalizedX(anchors[index]) else { return false }
                    return abs(x - controlX - relativeX) < 2
                }
                guard candidates.contains(source), onePerRow(candidates), candidates.count == rows.rows.count,
                      claim(entry, candidates) else { failures.insert(entry.pid); continue }
                managed += candidates
            }
            guard failures.isEmpty else { failed.formUnion(failures); continue }

            func occupiesManagedGap(_ window: StatusWindow) -> Bool {
                let neighbours = managed.filter { row($0) == row(window) }
                return neighbours.filter { abs($0.frame.maxX - window.frame.minX) < 2 }.count == 1
                    && neighbours.filter { abs($0.frame.minX - window.frame.maxX) < 2 }.count == 1
            }
            for role in fixedRoles {
                let offset = role.source.frame.minX - anchors[row(role.source)!].frame.minX
                for member in role.members {
                    let sameOffset = abs(member.frame.minX - anchors[row(member)!].frame.minX - offset) < 2
                    if !sameOffset && !(occupiesManagedGap(role.source) && occupiesManagedGap(member)) {
                        failures.insert(role.entry.pid)
                    }
                }
            }
            guard failures.isEmpty else { failed.formUnion(failures); continue }
            for pid in failed { groups[pid] = Array(repeating: nil, count: fresh[pid]!.count) }
            return groups
        }
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
