import CoreGraphics
import Foundation

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

    init(app: AppProcess, outcome: Outcome) { self.app = app; self.outcome = outcome }

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
        init(identity: IconIdentity, label: String, movable: Bool, window: WindowKey, element: Int) {
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
        guard elements.allSatisfy({ element in element.frame.map(rows.admits) ?? true }) else {
            return failed(app, WorkIssue(recovery: .retry, message: "Accessibility geometry is outside current menu rows"))
        }
        let candidates = windows.filter { $0.key.pid == app.pid && rows.onBar($0) }
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

// MARK: - Icon identity

/// The natural key of an icon.
public struct IconIdentity: Hashable, Sendable {
    public let bundle: String
    public let item: String?
    init(bundle: String, item: String?) { self.bundle = bundle; self.item = item }
    /// "bundle::item", or "bundle" when there is no item. The default config id.
    public var key: String { item.map { bundle + "::" + $0 } ?? bundle }
    /// Control Centre's fixed modules and Notification Centre cannot be dragged.
    static func isMovable(bundle: String, item: String) -> Bool {
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
    let grouped: Bool
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

    /// `windows` are every status window of the app in `rows`.
    init(incarnation: String, windows: [StatusWindow], members: Set<WindowKey>, rows: MenuRows) {
        self.incarnation = incarnation
        keys = Set(windows.map(\.key))
        var loose: [WindowKey: LooseState] = [:]
        for window in windows where !members.contains(window.key) && loose[window.key] == nil {
            loose[window.key] = LooseState(minY: window.frame.minY, onScreen: window.onScreen,
                                           frame: rows.row(of: window) == nil ? nil : window.frame)
        }
        self.loose = loose
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

/// One observation of the menu bar, and the identities it carries to the next.
///
/// A gather asks `survey` once ("which apps cannot vouch for themselves on this list?"),
/// reads exactly those apps, and hands the survey and the readings to `observe`. With
/// nothing stale and no readings the survey already is the bar, so a no-change gather
/// examines the list once.
public struct MenuBar: Sendable {
    /// The bar before the first observation: no bindings, so every app is stale.
    public static let none = MenuBar(rows: MenuRows(WindowList(skippingMalformed: []), ownPID: 0, displays: []),
                                     roles: [], issues: [], activeRow: nil, reusable: false, bindings: [:],
                                     auditMismatches: 0, audited: nil)

    public let rows: MenuRows
    /// Icons of other apps, left to right on the reference row.
    public let roles: [Role]
    /// Non-empty means incomplete: never a visibility command (except reveal).
    /// Includes "<app>: not read (<stale reason>)" for every stale app without a reading.
    public let issues: [WorkIssue]
    /// Row index the last AX reading landed on; nil until some app was read.
    let activeRow: Int?
    /// True when the next pass over an unchanged list would read no app.
    public let reusable: Bool
    /// Audit readings that named different identities for a carried binding's windows.
    public let auditMismatches: Int

    /// Per app, the reading that produced its roles, with the evidence it was read
    /// under. Only a clean reading creates or replaces one; a failed or unclear reading
    /// keeps it (never publish disappearance) but marks it not reusable.
    struct Binding: Sendable {
        let app: AppProcess
        let evidence: AppEvidence
        let icons: [AppReading.BoundIcon]
        /// Per icon, the replicas grouped when it was bound; nil when it could not be grouped.
        let groups: [Set<WindowKey>?]
        var reusable: Bool
        var members: Set<WindowKey> {
            zip(icons, groups).reduce(into: []) { $0.formUnion($1.1 ?? [$1.0.window]) }
        }

        /// True when a clean reading names the same identities for the same windows:
        /// as many icons, each one of this binding's icons on one of its replicas.
        /// Members are disjoint within an app, so this is a one-to-one match.
        func agrees(with read: [AppReading.BoundIcon]) -> Bool {
            read.count == icons.count && read.allSatisfy { icon in
                zip(icons, groups).contains { bound, group in
                    bound.identity == icon.identity && bound.movable == icon.movable
                        && (group ?? [bound.window]).contains(icon.window)
                }
            }
        }
    }
    let bindings: [Int32: Binding]
    /// The app the last audit reading was for; `auditTarget` continues after it.
    let audited: Int32?

    private init(rows: MenuRows, roles: [Role], issues: [WorkIssue], activeRow: Int?, reusable: Bool,
                 bindings: [Int32: Binding], auditMismatches: Int, audited: Int32?) {
        self.rows = rows; self.roles = roles; self.issues = issues; self.activeRow = activeRow
        self.reusable = reusable; self.bindings = bindings; self.auditMismatches = auditMismatches; self.audited = audited
    }

    public var complete: Bool { issues.isEmpty && rows.fault == nil }

    /// The row positions are read from: `activeRow`, else the first. nil when the rows are faulty.
    public var referenceRow: Int? {
        guard rows.fault == nil, !rows.rows.isEmpty else { return nil }
        return activeRow.flatMap { $0 < rows.rows.count ? $0 : nil } ?? 0
    }

    /// Movable icons' identity keys and Tuck's own ids, left to right on the reference
    /// row. Empty when the rows are faulty. An ungrouped icon counts by its window on
    /// that row: in a complete bar it was read on that row this pass.
    var order: [String] {
        guard let row = referenceRow else { return [] }
        let icons = roles.filter(\.movable).compactMap { role in
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

    /// The app the shell may re-read after a pass applied, to check a carried binding
    /// against AX. Rotates over reusable bindings in pid order; nil when there is none.
    public var auditTarget: AppProcess? {
        let candidates = bindings.filter(\.value.reusable).keys.sorted()
        guard let pid = candidates.first(where: { pid in audited.map { pid > $0 } ?? true }) ?? candidates.first else { return nil }
        return bindings[pid]?.app
    }

    // MARK: Survey and observe

    /// One look at a window list through this bar's carried bindings.
    public struct Survey: Sendable {
        /// pid -> why that app needs an AX read. Empty means nothing changed.
        public var stale: [Int32: String] { findings.stale }
        let previous: MenuBar
        let rows: MenuRows
        let live: [Int32: AppProcess]
        fileprivate let findings: Findings
    }

    /// The "nothing changed" question every gather asks, once. An app needs an AX read
    /// iff it has a window that can be an icon and no binding, its incarnation changed,
    /// its last reading was not clean, its `AppEvidence` changed, one of its roles is
    /// ungrouped or lost a replica or its row set, a same-pid window overlays a member,
    /// it shows a window on an anchored row that is no role, its identity is duplicated,
    /// or its icons are in a different order on some row.
    public func survey(_ rows: MenuRows, running: [AppProcess]) -> Survey {
        let live = Dictionary(running.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return Survey(previous: self, rows: rows, live: live, findings: Self.examine(rows, live: live, bindings: bindings))
    }

    /// Build this pass's bar from a survey and the readings taken for it. Readings
    /// should cover every stale app; any not covered becomes an issue, never a guess.
    /// With no readings the bar is complete exactly when nothing is stale, the rows have
    /// no fault and some icon of another app is on the bar.
    ///
    /// A reading of an app the survey did not name is an audit of its binding: when it
    /// agrees nothing changes, when it disagrees it replaces the binding and counts in
    /// `auditMismatches`, and when it fails the binding stops being reusable.
    public static func observe(_ survey: Survey, readings: [AppReading]) -> MenuBar {
        let rows = survey.rows, live = survey.live, previous = survey.previous
        var bindings = previous.bindings.filter { live[$0.key]?.incarnation == $0.value.evidence.incarnation }
        var changed = bindings.count != previous.bindings.count
        var issues: [WorkIssue] = []
        var fresh: [Int32: [AppReading.BoundIcon]] = [:]
        var read = Set<Int32>()
        var mismatches = previous.auditMismatches
        var audited = previous.audited
        for reading in readings {
            guard let app = live[reading.app.pid], app.incarnation == reading.app.incarnation,
                  app.pid != rows.ownPID else { continue }
            let audit = survey.stale[app.pid] == nil ? bindings[app.pid] : nil
            if audit != nil { audited = app.pid }
            read.insert(app.pid)
            fresh[app.pid] = nil
            switch reading.outcome {
            case .clean(let icons):
                if let audit {
                    if audit.agrees(with: icons) { continue }
                    mismatches += 1
                }
                fresh[app.pid] = icons
            case .unclear(_, let found):
                issues += found
                bindings[app.pid]?.reusable = false
                changed = true
            case .failed(let issue):
                issues.append(WorkIssue(recovery: issue.recovery, message: "\(app.name): \(issue.message)"))
                bindings[app.pid]?.reusable = false
                changed = true
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
            changed = changed || !fresh.isEmpty
            fresh = [:]
        } else if let row = landed.compactMap({ $0 }).first {
            activeRow = row
        }

        let groups = group(fresh, carried: bindings, rows: rows)
        for (pid, icons) in fresh {
            let assigned = groups[pid] ?? Array(repeating: nil, count: icons.count)
            let members = zip(icons, assigned).reduce(into: Set<WindowKey>()) { $0.formUnion($1.1 ?? [$1.0.window]) }
            bindings[pid] = Binding(app: live[pid]!,
                                    evidence: AppEvidence(incarnation: live[pid]!.incarnation, windows: rows.windows(of: pid),
                                                          members: members, rows: rows),
                                    icons: icons, groups: assigned, reusable: true)
            changed = true
        }
        for (pid, reason) in survey.stale where !read.contains(pid) {
            if let app = live[pid] { issues.append(WorkIssue(recovery: .retry, message: "\(app.name): not read (\(reason))")) }
        }

        let after = changed ? examine(rows, live: live, bindings: bindings) : survey.findings
        // Rows that disagree on managed order leave the bar unreusable (the apps stay
        // stale). They block it only when an app involved was not read on the active
        // row this pass, so its position there is not fresh evidence.
        if !after.disordered.isSubset(of: fresh.keys) {
            issues.append(WorkIssue(recovery: .retry, message: "known window order changed"))
        }
        for key in after.duplicates { issues.append(WorkIssue(recovery: .awaitChange, message: "\(key): ambiguous identity")) }
        if issues.isEmpty && rows.fault == nil && after.roles.isEmpty {
            issues.append(WorkIssue(recovery: .retry, message: "Waiting for a coherent active menu bar"))
        }
        var seen = Set<String>()
        issues = issues.filter { seen.insert($0.message).inserted }
            .sorted { ($0.message, $0.recovery.rawValue) < ($1.message, $1.recovery.rawValue) }

        let reference = activeRow ?? 0
        func x(_ role: Role) -> CGFloat {
            let key = role.members.indices.contains(reference) ? role.members[reference] : nil
            return (key ?? role.members.compactMap { $0 }.first).flatMap { rows.window($0)?.frame.minX } ?? .infinity
        }
        let roles = after.roles.sorted { x($0) < x($1) }
        return MenuBar(rows: rows, roles: roles, issues: issues, activeRow: activeRow,
                       reusable: issues.isEmpty && rows.fault == nil && after.stale.isEmpty,
                       bindings: bindings, auditMismatches: mismatches, audited: audited)
    }

    fileprivate struct Findings: Sendable {
        var roles: [Role] = []
        var stale: [Int32: String] = [:]
        /// Processes with an icon in a different managed order on some row; Tuck's own
        /// pid when its items are.
        var disordered = Set<Int32>()
        var duplicates: [String] = []
        mutating func mark(_ pid: Int32, _ reason: String) { if stale[pid] == nil { stale[pid] = reason } }
    }

    /// Roles from carried bindings and the current list, and every app that cannot vouch
    /// for itself. Linear in the list: every per-app question goes through `windows(of:)`.
    private static func examine(_ rows: MenuRows, live: [Int32: AppProcess], bindings: [Int32: Binding]) -> Findings {
        var findings = Findings()
        let carried = bindings.keys.sorted()
        for pid in carried where live[pid].map({ $0.incarnation != bindings[pid]!.evidence.incarnation }) == true {
            findings.mark(pid, "process restarted")
        }
        // An app with only panels or dormant windows has no icon to read; it is asked
        // about once one of its windows can be an icon.
        for pid in live.keys.sorted() where pid != rows.ownPID && bindings[pid] == nil
            && rows.windows(of: pid).contains(where: rows.onBar) {
            findings.mark(pid, "not yet read")
        }

        for pid in carried {
            guard let binding = bindings[pid], live[pid]?.incarnation == binding.evidence.incarnation else { continue }
            if !binding.reusable { findings.mark(pid, "previous read incomplete") }
            let members = binding.members
            let windows = rows.windows(of: pid)
            if let change = binding.evidence.change(to: AppEvidence(incarnation: binding.evidence.incarnation, windows: windows,
                                                                     members: members, rows: rows)) {
                findings.mark(pid, change)
            }
            for (icon, group) in zip(binding.icons, binding.groups) {
                let keys = group ?? [icon.window]
                var slots = [WindowKey?](repeating: nil, count: rows.rows.count)
                var grouped = group != nil
                if !grouped { findings.mark(pid, "icon not grouped across rows") }
                for key in keys.sorted(by: { $0.number < $1.number }) {
                    guard let window = rows.window(key), let index = rows.row(of: window), slots[index] == nil else {
                        grouped = false
                        findings.mark(pid, "logical role row membership changed")
                        continue
                    }
                    slots[index] = key
                    // A previously distinct same-process window must not become an
                    // ambiguous overlay of a trusted role.
                    if windows.contains(where: {
                        !keys.contains($0.key) && rows.row(of: $0) == index &&
                        abs($0.frame.width - window.frame.width) < 2 && abs($0.frame.minX - window.frame.minX) < 2
                    }) { findings.mark(pid, "ambiguous logical role geometry") }
                }
                if icon.movable && slots.contains(where: { $0 == nil }) {
                    grouped = false
                    findings.mark(pid, "logical role replica missing")
                }
                findings.roles.append(Role(identity: icon.identity, label: icon.label, movable: icon.movable,
                                           pid: pid, members: slots, grouped: grouped))
            }
            if windows.contains(where: {
                !members.contains($0.key) && $0.onScreen && menuHeights.contains($0.frame.height) && rows.row(of: $0) != nil
            }) { findings.mark(pid, "untracked active menu-bar window") }
        }

        for (identity, roles) in Dictionary(grouping: findings.roles, by: \.identity) where roles.count > 1 {
            findings.duplicates.append(identity.key)
            for role in roles { findings.mark(role.pid, "\(identity.key): ambiguous identity") }
        }
        findings.duplicates.sort()

        // Managed order (movable icons and Tuck's items) must agree on every row.
        guard rows.fault == nil, !rows.rows.isEmpty else { return findings }
        let managed = findings.roles.filter { $0.grouped && $0.movable }
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
                    for pid in [a.pid, b.pid] {
                        findings.disordered.insert(pid ?? rows.ownPID)
                        if let pid { findings.mark(pid, "known window order changed") }
                    }
                }
            }
        }
        return findings
    }

    // MARK: Replica grouping

    /// Groups each fresh icon's replicas:
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
                var candidates = rows.windows(of: entry.pid).filter {
                    abs($0.frame.width - source.frame.width) < 2 && row($0) != nil
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
                let candidates = rows.windows(of: entry.pid).filter { candidate in
                    guard abs(candidate.frame.width - source.frame.width) < 2,
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
func matchWindow(_ frame: CGRect, candidates: [StatusWindow], used: Set<WindowKey>) -> StatusWindow? {
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
func shouldBlockEmptyExtras(candidates: [StatusWindow], hasLastGood: Bool) -> Bool {
    !candidates.isEmpty && (hasLastGood || candidates.contains(where: \.onScreen))
}
