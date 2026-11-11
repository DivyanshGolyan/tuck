import AppKit
import ApplicationServices
import TuckCore

/// AX reads of the apps it is told to read, bound by `AppReading.bind`.
/// All mutable state and AX references are confined to SerialWorker.system.
final class AppReader: @unchecked Sendable {
    private lazy var titles = StatusWindowTitles()
    /// AXUIElement -> item, per process incarnation. The core cannot hold AXUIElements,
    /// so bound icons name their element by index and this memory is refreshed from them.
    private var knownElements: [pid_t: (incarnation: String, items: [(AXUIElement, String)])] = [:]
    private let debug = ProcessInfo.processInfo.environment["TUCK_DEBUG_INVENTORY"] == "1"

    /// One reading per app, sharing one pass budget. `hadIcons` names the apps the
    /// previous bar showed icons for: empty extras from them are not evidence of removal.
    func read(_ apps: [AppProcess], rows: MenuRows, hadIcons: Set<pid_t>) -> [AppReading] {
        guard AXIsProcessTrusted() else {
            return apps.map { .failed($0, WorkIssue(recovery: .awaitChange, message: "Accessibility permission required")) }
        }
        let budget = AXReadBudget()
        return apps.map { app in
            if knownElements[app.pid]?.incarnation != app.incarnation { knownElements[app.pid] = nil }
            do {
                return try read(app, rows: rows, hadIcons: hadIcons.contains(app.pid), using: AXRead(pass: budget))
            } catch {
                let failure = error as? AXReadFailure
                if failure?.code == .invalidUIElement { knownElements[app.pid] = nil }
                return .failed(app, failure?.issue ?? WorkIssue(recovery: .retry, message: error.localizedDescription))
            }
        }
    }

    private func read(_ app: AppProcess, rows: MenuRows, hadIcons: Bool, using read: AXRead) throws -> AppReading {
        var elements: [AXUIElement] = []
        if let value = try read.value(AXUIElementCreateApplication(app.pid), "AXExtrasMenuBar", optional: false),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            elements = try read.value(value as! AXUIElement, kAXChildrenAttribute, optional: false) as? [AXUIElement] ?? []
        }
        // AX geometry and metadata first, then fresh CG geometry for this process, not
        // the gather's list from before other IPC.
        let remembered = knownElements[app.pid]?.items ?? []
        var readings: [AXElementReading] = []
        for element in elements {
            guard let frame = try read.frame(element) else {
                readings.append(AXElementReading(frame: nil, identifier: nil, remembered: nil, compatibility: nil, description: nil))
                continue
            }
            // The bind would reject it too; failing here sends no further IPC.
            guard rows.admits(frame) else { throw AXReadFailure("Accessibility geometry is outside current menu rows") }
            let identifier = (try read.value(element, "AXIdentifier") as? String)?.nilIfEmpty
            let cached = remembered.first(where: { CFEqual($0.0, element) })?.1
            let compatibility = identifier == nil && cached == nil ? StatusItemIdentity.compatibilityItem(bundleID: app.bundle,
                accessibilityTitle: try read.value(element, kAXTitleAttribute) as? String) : nil
            let description = elements.count > 1 && app.bundle == "com.apple.controlcenter"
                ? (try read.value(element, kAXDescriptionAttribute) as? String)?.nilIfEmpty : nil
            readings.append(AXElementReading(frame: frame, identifier: identifier, remembered: cached,
                                             compatibility: compatibility, description: description))
        }

        let known = rows.barWindows(of: app.pid)
        var windows = elements.isEmpty && known.isEmpty ? [] : try sample(known, pid: app.pid)
        var reading = AppReading.bind(app: app, elements: readings, windows: windows, titles: titles(windows, rows: rows),
                                      rows: rows, hadIcons: hadIcons, finalAttempt: false)
        if reading == nil {
            // One bounded geometry re-sample only. Never choose a closest window or
            // replay an action when AX and CG still disagree.
            for index in readings.indices where readings[index].frame != nil {
                guard let frame = try read.frame(elements[index]) else { throw AXReadFailure("Status geometry changed during read") }
                readings[index].frame = frame
            }
            windows = try everyWindow(of: app.pid)
            reading = AppReading.bind(app: app, elements: readings, windows: windows, titles: titles(windows, rows: rows),
                                      rows: rows, hadIcons: hadIcons, finalAttempt: true)
        }
        let result = reading!
        remember(result, elements: elements, incarnation: app.incarnation)
        if debug { trace(result, readings: readings, windows: windows, rows: rows) }
        return result
    }

    /// Fresh geometry for one process without describing every window on the system.
    /// A known window that vanished falls back to the full list; one created since is
    /// caught by the bind's re-sample.
    private func sample(_ known: [StatusWindow], pid: pid_t) throws -> [StatusWindow] {
        if !known.isEmpty, let described = try? WindowList.describe(known.map(\.key)), described.count == known.count {
            return described
        }
        return try everyWindow(of: pid)
    }

    private func everyWindow(of pid: pid_t) throws -> [StatusWindow] {
        do { return try WindowList.read().list.windows.filter { $0.key.pid == pid } }
        catch { throw AXReadFailure("Window inventory temporarily unavailable") }
    }

    /// Private titles for the untitled windows that can be icons.
    private func titles(_ windows: [StatusWindow], rows: MenuRows) -> [WindowKey: String] {
        var result: [WindowKey: String] = [:]
        for window in windows where window.title.isEmpty && rows.onBar(window) {
            result[window.key] = titles.title(windowID: window.key.number)
        }
        return result
    }

    private func remember(_ reading: AppReading, elements: [AXUIElement], incarnation: String) {
        let bound: [AppReading.BoundIcon]
        switch reading.outcome {
        case .clean(let icons), .unclear(let icons, _): bound = icons
        case .failed: return
        }
        var items = knownElements[reading.app.pid]?.items ?? []
        for icon in bound {
            guard let item = icon.identity.item else { continue }
            let element = elements[icon.element]
            items.removeAll { CFEqual($0.0, element) }
            items.append((element, item))
        }
        if case .clean = reading.outcome {
            items = items.filter { known in elements.contains { CFEqual(known.0, $0) } }
        }
        knownElements[reading.app.pid] = (incarnation, items)
    }

    private func trace(_ reading: AppReading, readings: [AXElementReading], windows: [StatusWindow], rows: MenuRows) {
        let bound: [AppReading.BoundIcon]
        switch reading.outcome {
        case .clean(let icons), .unclear(let icons, _): bound = icons
        case .failed: bound = []
        }
        let bundle = reading.app.bundle
        let candidates = windows.filter { $0.key.pid == reading.app.pid && rows.onBar($0) }
        let geometry = candidates.map { "\($0.key.number):\($0.frame):onscreen=\($0.onScreen)" }.joined(separator: "; ")
        for (index, element) in readings.enumerated() {
            let matched = bound.first { $0.element == index }?.window.number
            guard matched == nil || bundle == "com.apple.controlcenter" else { continue }
            fputs("AX inventory \(bundle) id=\(element.identifier ?? element.remembered ?? "?") AX=\(element.frame.map { "\($0)" } ?? "nil") matched=\(matched?.description ?? "none") CG=[\(geometry)]\n", stderr)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
