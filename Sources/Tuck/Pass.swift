import AppKit
import TuckCore

extension AppProcess {
    /// Running apps with a bundle id, excluding Tuck.
    @MainActor static func running() -> [AppProcess] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != getpid(), let bundle = app.bundleIdentifier, bundle != "local.tuck" else { return nil }
            return AppProcess(pid: app.processIdentifier, bundle: bundle, name: app.localizedName ?? bundle,
                              incarnation: incarnation(pid: app.processIdentifier, launchDate: app.launchDate))
        }
    }
}

extension Display {
    /// Attached displays in CoreGraphics global coordinates; `usableLeft` as Mover computes it.
    @MainActor static func current() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let frame = CGDisplayBounds(number.uint32Value)
            return Display(frame: frame, usableLeft: screen.auxiliaryTopRightArea?.minX ?? frame.minX + 180)
        }
    }
}

// MARK: - Gather

/// One observation of the menu bar: one full window-list read, then AX only for the
/// apps the previous bar cannot vouch for.
@MainActor
enum Gather {
    enum Reach {
        /// Reads no app: the bar is complete exactly when nothing is stale.
        case observeOnly
        case full
    }

    /// The one full window-list read. Malformed records are dropped and `skippedMalformed` says so.
    static func rows(on worker: SerialWorker, adding extra: [StatusWindow] = []) async throws -> MenuRows {
        let displays = Display.current()
        let read: (list: WindowList, malformed: Bool)
        do { read = try await worker.run { try WindowList.readSkippingMalformed() } }
        catch is CancellationError { throw CancellationError() }
        catch { throw AXReadFailure("Window inventory temporarily unavailable") }
        let list = extra.isEmpty ? read.list : WindowList(skippingMalformed: read.list.windows + extra)
        return MenuRows(list, ownPID: getpid(), displays: displays, skippedMalformed: read.malformed)
    }

    /// `check` runs after the AX read and throws to abandon the observation.
    static func bar(_ rows: MenuRows, previous: MenuBar, reach: Reach, reader: AppReader,
                    check: () throws -> Void = {}) async throws -> MenuBar {
        let running = AppProcess.running()
        var readings: [AppReading] = []
        // Faulty rows can bind nothing; the bar is incomplete either way.
        if reach == .full && rows.fault == nil {
            let stale = previous.staleApps(in: rows, running: running)
            if !stale.isEmpty {
                let targets = running.filter { stale[$0.pid] != nil }
                let hadIcons = Set(previous.roles.map(\.pid))
                readings = try await SerialWorker.system.run { reader.read(targets, rows: rows, hadIcons: hadIcons) }
                try check()
            }
        }
        return MenuBar.observe(rows, running: running, readings: readings, previous: previous)
    }
}

// MARK: - The single window-list parser

extension WindowList {
    /// Every status-layer window (no height or display filter). Throws `.unavailable`
    /// when CG returns no list and `.malformed` when a status record lacks pid,
    /// number or usable bounds, or repeats a key.
    nonisolated static func read() throws -> WindowList {
        let (windows, complete) = parse(try copyAll())
        guard complete else { throw Fault.malformed }
        return try WindowList(windows)
    }

    /// The same read, keeping only well-formed windows and reporting whether any
    /// status record was dropped. A single bad record must not stop the full pass,
    /// AppReader or Mover; the observe-only hide declines on it.
    nonisolated static func readSkippingMalformed() throws -> (list: WindowList, malformed: Bool) {
        let (windows, complete) = parse(try copyAll())
        let list = WindowList(skippingMalformed: windows)
        return (list, !complete || list.windows.count != windows.count)
    }

    /// Fresh records for known windows via CGWindowListCreateDescriptionFromArray,
    /// parsed by the same record parser. Not a full list read. Windows that left the
    /// status layer are omitted.
    nonisolated static func describe(_ keys: [WindowKey]) throws -> [StatusWindow] {
        var numbers = keys.map { UnsafeRawPointer(bitPattern: UInt($0.number)) }
        guard let array = CFArrayCreate(kCFAllocatorDefault, &numbers, numbers.count, nil),
              let records = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else {
            throw Fault.unavailable
        }
        let (windows, complete) = parse(records)
        guard complete else { throw Fault.malformed }
        return windows
    }

    private nonisolated static func copyAll() throws -> [[String: Any]] {
        guard let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw Fault.unavailable
        }
        return records
    }

    /// Status-layer records only; `complete` is false when any of them lacked a field.
    private nonisolated static func parse(_ records: [[String: Any]]) -> (windows: [StatusWindow], complete: Bool) {
        let layer = Int(CGWindowLevelForKey(.statusWindow))
        var windows: [StatusWindow] = []
        var complete = true
        for record in records where (record[kCGWindowLayer as String] as? Int) == layer {
            guard let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  let number = record[kCGWindowNumber as String] as? UInt32,
                  let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else {
                complete = false; continue
            }
            windows.append(StatusWindow(key: WindowKey(pid: pid, number: number), frame: frame,
                onScreen: (record[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                title: record[kCGWindowName as String] as? String ?? ""))
        }
        return (windows, complete)
    }
}
