import AppKit
import ApplicationServices
import TuckCore

// All coordinates in this file are CoreGraphics global display coordinates.
struct BarIcon: Sendable {
    let id: String
    let metadata: ItemMetadata
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let movable: Bool
}

struct InventorySnapshot: Sendable {
    let icons: [BarIcon]
    let ambiguous: [String]
    let issues: [WorkIssue]
    /// Every status-layer window in the list this scan started from; nil when
    /// that list was unavailable or malformed.
    let statusKeys: Set<WindowKey>?
    var complete: Bool { issues.isEmpty && ambiguous.isEmpty }
    init(icons: [BarIcon], ambiguous: [String], issues: [WorkIssue] = [], statusKeys: Set<WindowKey>? = nil) {
        self.icons = icons; self.ambiguous = ambiguous; self.issues = issues; self.statusKeys = statusKeys
    }
}

@MainActor
final class Inventory {
    nonisolated static let separatorID = "__tuck_separator__"
    nonisolated static let controlID = "__tuck_control__"
    private let reader = InventoryReader()

    func scan() async throws -> InventorySnapshot {
        let displays = NSScreen.displayBounds
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AXApplicationContext? in
            guard app.processIdentifier != getpid(), let bundle = app.bundleIdentifier, bundle != "local.tuck" else { return nil }
            return AXApplicationContext(pid: app.processIdentifier, bundle: bundle, name: app.localizedName ?? bundle,
                incarnation: AXApplicationContext.incarnation(pid: app.processIdentifier, launchDate: app.launchDate))
        }
        return try await SerialWorker.system.run { [reader] in
            reader.scan(displays: displays, apps: apps)
        }
    }

    nonisolated static func key(bundle: String, item: String?) -> String {
        guard let item else { return bundle }
        return bundle + "::" + item
    }
    nonisolated static func isMovable(bundle: String, item: String) -> Bool {
        if bundle == "com.apple.controlcenter" {
            return !["Clock", "BentoBox", "AudioVideoModule", "com.apple.menuextra.clock", "com.apple.menuextra.controlcenter", "com.apple.menuextra.audiovideo"].contains(item)
        }
        return bundle != "com.apple.notificationcenterui"
    }
}

extension NSScreen {
    /// Every attached display, in CoreGraphics global coordinates.
    static var displayBounds: [CGRect] {
        screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) }
        }
    }
}

struct StatusWindow: Hashable {
    let id: CGWindowID
    let frame: CGRect
    let publicTitle: String
    let onScreen: Bool
}

/// Candidates MUST already be restricted to this process's status-layer windows.
/// A unique named source establishes the role; only its width and the requested
/// physical row may select an unnamed replica. Offscreen separators are valid.
func ownedStatusWindow(title: String, menuY: CGFloat, candidates: [StatusWindow]) -> StatusWindow? {
    let sources = candidates.filter { $0.publicTitle == title }
    guard sources.count == 1, let source = sources.first else { return nil }
    if abs(source.frame.minY - menuY) < 2 { return source }
    let replicas = candidates.filter {
        abs($0.frame.minY - menuY) < 2 && abs($0.frame.width - source.frame.width) < 2
    }
    return replicas.count == 1 ? replicas.first : nil
}

/// Successful empty AX extras plus only never-observed offscreen CG windows is
/// not evidence of an accessible icon. Retain known hidden icons on AX loss,
/// but allow actual removal when no status windows remain.
func shouldBlockEmptyExtras(candidates: [StatusWindow], hasLastGood: Bool) -> Bool {
    !candidates.isEmpty && (hasLastGood || candidates.contains(where: \.onScreen))
}

private struct AXStatusItem {
    let element: AXUIElement
    var frame: CGRect
    let identifier: String?
    let compatibility: String?
    let cached: String?
    let description: String?
}

/// Strict evidence tiers, not a nearest-window heuristic. Status windows can
/// overlap even in a single current CG snapshot (for example a dormant FocusModes
/// replica over Battery). A midpoint alone does not identify the owning window.
func matchWindow(_ frame: CGRect, candidates: [StatusWindow], used: Set<CGWindowID>) -> StatusWindow? {
    let exact = candidates.filter {
        abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 &&
        abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2
    }
    if !exact.isEmpty { return exact.count == 1 && !used.contains(exact[0].id) ? exact[0] : nil }
    // AX can report a content inset rather than the entire status window. Require
    // containment of the WHOLE AX rect, and a unique candidate, not just its center.
    let containing = candidates.filter { $0.frame.insetBy(dx: -2, dy: -2).contains(frame) }
    return containing.count == 1 && !used.contains(containing[0].id) ? containing[0] : nil
}

/// All mutable state and AX references are confined to SerialWorker.system.
private final class InventoryReader {
    private lazy var titles = StatusWindowTitles()
    private var knownElements: [pid_t: [(AXUIElement, String)]] = [:]
    private var incarnations: [pid_t: String] = [:]
    private var lastGood: [pid_t: [BarIcon]] = [:]
    private var cursor = 0
    // The window geometry under which lastGood[pid] was read cleanly. While a
    // process's status windows are byte-for-byte where they were, its icons are
    // too, so its AX geometry is not asked for again.
    private var lastGoodEvidence: [pid_t: Set<StatusWindow>] = [:]

    private func windowInfo() throws -> [[String: Any]] {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw AXReadFailure("Window inventory temporarily unavailable")
        }
        return windows
    }

    private func statusWindows(_ windows: [[String: Any]], displays: [CGRect], pid: pid_t? = nil) -> [pid_t: [StatusWindow]] {
        var result: [pid_t: [StatusWindow]] = [:]
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let owner = window[kCGWindowOwnerPID as String] as? Int32,
                  pid == nil || owner == pid,
                  let id = window[kCGWindowNumber as String] as? UInt32,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.height >= 16, frame.height <= 64, frame.width > 0,
                  displays.contains(where: { abs(frame.minY - $0.minY) < 2 }) else { continue }
            result[owner, default: []].append(StatusWindow(id: id, frame: frame,
                publicTitle: window[kCGWindowName as String] as? String ?? "",
                onScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        return result
    }

    /// Fresh geometry for one process without describing every window on the
    /// system. A window that vanished or was never seen falls back to the full
    /// list; a window created since is caught by the caller's re-sample.
    private func freshStatusWindows(known: [StatusWindow], displays: [CGRect], pid: pid_t) throws -> [StatusWindow] {
        if !known.isEmpty {
            var ids = known.map { UnsafeRawPointer(bitPattern: UInt($0.id)) }
            if let array = CFArrayCreate(kCFAllocatorDefault, &ids, ids.count, nil),
               let described = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
               described.count == known.count {
                return statusWindows(described, displays: displays, pid: pid)[pid] ?? []
            }
        }
        return statusWindows(try windowInfo(), displays: displays, pid: pid)[pid] ?? []
    }

    func scan(displays: [CGRect], apps: [AXApplicationContext]) -> InventorySnapshot {
        let live = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
        for pid in Array(incarnations.keys) where live[pid]?.incarnation != incarnations[pid] {
            knownElements.removeValue(forKey: pid); lastGood.removeValue(forKey: pid); incarnations.removeValue(forKey: pid)
            lastGoodEvidence.removeValue(forKey: pid)
        }
        for app in apps { incarnations[app.pid] = app.incarnation }
        guard AXIsProcessTrusted() else {
            return InventorySnapshot(icons: lastGood.values.flatMap { $0 }, ambiguous: [],
                issues: [WorkIssue(recovery: .awaitChange, message: "Accessibility permission required")])
        }
        let initial: [pid_t: [StatusWindow]]
        let statusKeys: Set<WindowKey>?
        do {
            let info = try windowInfo()
            initial = statusWindows(info, displays: displays)
            statusKeys = (try? WindowLayoutSnapshot(records: info))?.keys
        } catch {
            return InventorySnapshot(icons: lastGood.values.flatMap { $0 }, ambiguous: [],
                issues: [WorkIssue(recovery: .retry, message: error.localizedDescription)])
        }
        var icons: [BarIcon] = []; var ambiguous: [String] = []; var issues: [WorkIssue] = []
        let budget = AXReadBudget()
        let pids = Set(initial.keys).union(lastGood.keys).filter { live[$0] != nil }.sorted()
        let offset = pids.isEmpty ? 0 : cursor % pids.count
        let ordered = Array(pids.dropFirst(offset)) + Array(pids.prefix(offset))
        cursor = pids.isEmpty ? 0 : (offset + 1) % pids.count
        let debug = ProcessInfo.processInfo.environment["TUCK_DEBUG_INVENTORY"] == "1"
        // AX reports the active bar's row, which can change while every window
        // stays put. One remembered process is always re-read, rotating with the
        // fairness cursor; if its row moved, nothing remembered is reused.
        let canary = ordered.first { lastGoodEvidence[$0] != nil && !(lastGood[$0] ?? []).isEmpty }
        let canaryRow = canary.flatMap { lastGood[$0]?.first?.frame.minY }
        if canary == nil { lastGoodEvidence.removeAll() }
        // A canary that cannot be read cleanly vouches for nothing.
        func forget(_ pid: pid_t) {
            if pid == canary { lastGoodEvidence.removeAll() } else { lastGoodEvidence.removeValue(forKey: pid) }
        }
        for pid in ordered {
            guard let app = live[pid] else { continue }
            if pid != canary, let evidence = lastGoodEvidence[pid], let good = lastGood[pid],
               evidence == Set(initial[pid] ?? []) {
                icons.append(contentsOf: good); continue
            }

            let bundle = app.bundle; let name = app.name
            let beforeCount = icons.count; let beforeAmbiguous = ambiguous.count; let beforeIssues = issues.count
            do {
                let read = AXRead(pass: budget)
                let application = AXUIElementCreateApplication(pid)
                var elements: [AXUIElement] = []
                if let value = try read.value(application, "AXExtrasMenuBar", optional: false), CFGetTypeID(value) == AXUIElementGetTypeID() {
                    elements = try read.value(value as! AXUIElement, kAXChildrenAttribute, optional: false) as? [AXUIElement] ?? []
                }
                // Capture AX geometry and optional metadata first, then sample fresh
                // CG geometry for THIS process, not a snapshot from before other IPC.
                var records: [AXStatusItem] = []
                for element in elements {
                    guard let frame = try read.frame(element) else {
                        ambiguous.append("\(name): accessibility geometry unavailable"); continue
                    }
                    // Throw rather than silently dropping a nonempty off-row
                    // extras list: the catch preserves this PID's last-good data.
                    guard displays.contains(where: { abs(frame.minY - $0.minY) < 64 }) else {
                        throw AXReadFailure("Accessibility geometry is outside current menu rows")
                    }
                    let identifier = (try read.value(element, "AXIdentifier") as? String)?.nilIfEmpty
                    let cached = knownElements[pid]?.first(where: { CFEqual($0.0, element) })?.1
                    let compatibility = identifier == nil && cached == nil ? StatusItemIdentity.compatibilityItem(bundleID: bundle,
                        accessibilityTitle: try read.value(element, kAXTitleAttribute) as? String) : nil
                    let description = elements.count > 1 && bundle == "com.apple.controlcenter"
                        ? (try read.value(element, kAXDescriptionAttribute) as? String)?.nilIfEmpty : nil
                    records.append(AXStatusItem(element: element, frame: frame, identifier: identifier,
                        compatibility: compatibility, cached: cached, description: description))
                }
                var candidates = try freshStatusWindows(known: initial[pid] ?? [], displays: displays, pid: pid)
                func allMatch() -> Bool {
                    var used = Set<CGWindowID>()
                    for record in records {
                        guard let window = matchWindow(record.frame, candidates: candidates, used: used) else { return false }
                        used.insert(window.id)
                    }
                    return true
                }
                // One bounded geometry re-sample only. Never choose a closest item
                // or replay an action when AX and CG observations still disagree.
                if !allMatch() && !records.isEmpty {
                    for index in records.indices {
                        guard let frame = try read.frame(records[index].element) else { throw AXReadFailure("Status geometry changed during read") }
                        records[index].frame = frame
                    }
                    candidates = statusWindows(try windowInfo(), displays: displays, pid: pid)[pid] ?? []
                }
                // Titles enrich a uniquely matched window; they never select it.
                let named = candidates.map { window in
                    (window: window, title: window.publicTitle.isEmpty ? (titles.title(windowID: window.id) ?? "") : window.publicTitle)
                }
                let meaningful = named.filter { !$0.title.isEmpty }
                let distinctNames = Set(meaningful.map(\.title))
                func rightGap(_ frame: CGRect) -> CGFloat? {
                    let matching = displays.filter { abs(frame.minY - $0.minY) < 2 }
                    guard let display = matching.first(where: { $0.minX <= frame.midX && frame.midX < $0.maxX }) ?? matching.first else { return nil }
                    return display.maxX - frame.maxX
                }
                func titleForWindow(_ window: StatusWindow) -> String? {
                    if let title = named.first(where: { $0.window.id == window.id })?.title.nilIfEmpty { return title }
                    guard let gap = rightGap(window.frame) else { return nil }
                    let peers = Set(meaningful.filter {
                        abs($0.window.frame.width - window.frame.width) < 2 && rightGap($0.window.frame).map { abs($0 - gap) < 2 } == true
                    }.map(\.title))
                    return peers.count == 1 ? peers.first : nil
                }
                var used = Set<CGWindowID>()
                for record in records {
                    let window = matchWindow(record.frame, candidates: candidates, used: used)
                    if debug && (window == nil || bundle == "com.apple.controlcenter") {
                        let geometry = candidates.map { "\($0.id):\($0.frame):onscreen=\($0.onScreen)" }.joined(separator: "; ")
                        fputs("AX inventory \(bundle) id=\(record.identifier ?? record.cached ?? "?") AX=\(record.frame) matched=\(window?.id.description ?? "none") CG=[\(geometry)]\n", stderr)
                    }
                    guard let window else { ambiguous.append("\(name): ambiguous window match"); continue }
                    used.insert(window.id)
                    let item = record.identifier ?? (distinctNames.count > 1 ? titleForWindow(window) : nil) ?? record.compatibility ?? record.cached
                    if let item {
                        knownElements[pid, default: []].removeAll { CFEqual($0.0, record.element) }
                        knownElements[pid, default: []].append((record.element, item))
                    }
                    if elements.count > 1 && item == nil {
                        let message = "\(name): multiple icons without stable identifiers"
                        ambiguous.append(message); issues.append(WorkIssue(recovery: .awaitChange, message: message)); continue
                    }
                    let label = elements.count > 1 ? "\(name) — \(bundle == "com.apple.controlcenter" ? (record.description ?? item ?? "icon") : (item ?? "icon"))" : name
                    let windowTitle = named.first(where: { $0.window.id == window.id })?.title ?? ""
                    let movable = Inventory.isMovable(bundle: bundle, item: item ?? windowTitle)
                    icons.append(BarIcon(id: Inventory.key(bundle: bundle, item: item),
                        metadata: ItemMetadata(bundleID: bundle, label: label, item: item, movable: movable),
                        pid: pid, windowID: window.id, frame: window.frame, movable: movable))
                }
                if elements.isEmpty && shouldBlockEmptyExtras(candidates: candidates, hasLastGood: !(lastGood[pid] ?? []).isEmpty) {
                    ambiguous.append("\(name): accessibility inventory unavailable")
                }
                if ambiguous.count == beforeAmbiguous {
                    knownElements[pid] = (knownElements[pid] ?? []).filter { known in elements.contains { CFEqual(known.0, $0) } }
                    lastGood[pid] = Array(icons.dropFirst(beforeCount))
                    lastGoodEvidence[pid] = Set(candidates)
                    if pid == canary, let canaryRow,
                       lastGood[pid]?.first.map({ abs($0.frame.minY - canaryRow) < 2 }) != true {
                        lastGoodEvidence = lastGoodEvidence.filter { $0.key == pid }
                    }
                } else {
                    forget(pid)
                    let observed = Set(icons.dropFirst(beforeCount).map(\.id))
                    icons.append(contentsOf: (lastGood[pid] ?? []).filter { !observed.contains($0.id) })
                }
            } catch {
                icons.removeSubrange(beforeCount..<icons.count)
                ambiguous.removeSubrange(beforeAmbiguous..<ambiguous.count)
                issues.removeSubrange(beforeIssues..<issues.count)
                icons.append(contentsOf: lastGood[pid] ?? [])
                forget(pid)
                if (error as? AXReadFailure)?.code == .invalidUIElement { knownElements.removeValue(forKey: pid) }
                let issue = (error as? AXReadFailure)?.issue ?? WorkIssue(recovery: .retry, message: error.localizedDescription)
                issues.append(WorkIssue(recovery: issue.recovery, message: "\(name): \(issue.message)"))
            }
        }
        // Apps can report the new active row at different moments after a display
        // switch. A mixed result must not be remembered, or it would be replayed.
        if let row = icons.first?.frame.minY, !icons.allSatisfy({ abs($0.frame.minY - row) < 2 }) {
            lastGoodEvidence.removeAll()
        }
        let counts = Dictionary(grouping: icons, by: \.id)
        for (id, matches) in counts where matches.count > 1 {
            let message = "\(id): ambiguous identity"
            ambiguous.append(message); issues.append(WorkIssue(recovery: .awaitChange, message: message))
        }
        for message in Set(ambiguous) where !issues.contains(where: { $0.message == message }) {
            issues.append(WorkIssue(recovery: .retry, message: message))
        }
        return InventorySnapshot(icons: icons.filter { counts[$0.id]?.count == 1 }.sorted { $0.frame.minX < $1.frame.minX },
            ambiguous: Array(Set(ambiguous)).sorted(),
            issues: issues.sorted { ($0.message, $0.recovery.rawValue) < ($1.message, $1.recovery.rawValue) },
            statusKeys: statusKeys)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
