import AppKit
import TuckCore

/// A pass that did not apply, with what the scheduler should do about it.
struct DeferredWork: Error { let issue: WorkIssue }

/// What the pass needs from the scheduler that owns it.
@MainActor
protocol PassHost: AnyObject {
    /// Live intent: a cancelled pass never undoes a reveal the user has since asked for.
    var showsHidden: Bool { get }
    /// The pass is about to change the menu bar; changes it causes are not new work.
    func willApply()
    /// A menu is open or input is held; wake the scheduler when it ends.
    func waitForInput()
}

/// Diagnostics written to runtime.json under the existing field names.
struct PassStats {
    var scans = 0, moves = 0, reconciles = 0, fastHides = 0
    var scanMS = 0.0, reconcileMS = 0.0, visibilityCheckMS = 0.0
    var reconcilePhases: [String: Double] = [:]
    var fastHideReason: String?
}

/// The imperative shell around `assess`: gathers, applies the verdict, performs at most
/// one move, gathers again. It owns the middle layer's state (`bar`, `history`) and
/// makes no layout decision.
@MainActor
final class Reconciler {
    enum Result {
        case applied(note: String?)
        /// Observe-only reach only; the reason is also `stats.fastHideReason`.
        case declined(String)
    }

    private let separator: NSStatusItem
    private let control: NSStatusItem
    private let mover: Mover
    private let observers: IconObservers
    private let store: ConfigStore
    private let files: SerialWorker
    private weak var host: PassHost?
    private let windows = SerialWorker(label: "local.tuck.visibility")
    private let reader = AppReader()

    private(set) var bar = MenuBar.none
    private(set) var history = MoveHistory()
    private(set) var stats = PassStats()
    /// Counts pending moves whose outcome an observation settled.
    private(set) var resolvedMoves = 0
    private var observerTargets: Set<pid_t> = []

    init(separator: NSStatusItem, control: NSStatusItem, mover: Mover, observers: IconObservers,
         store: ConfigStore, files: SerialWorker, host: PassHost) {
        self.separator = separator; self.control = control; self.mover = mover
        self.observers = observers; self.store = store; self.files = files; self.host = host
    }

    /// One pass. `guardrail` throws CancellationError when the pass is no longer wanted;
    /// it runs after every await. The full reach throws DeferredWork for a stop. The
    /// observe-only reach reads no app, writes no file, moves nothing, and acts only on
    /// a `.done` verdict; it never throws.
    func run(_ config: TuckConfig, reach: Gather.Reach, guardrail: () throws -> Void) async throws -> Result {
        guard reach == .observeOnly else { return try await pass(config, reach: reach, guardrail: guardrail) }
        do { return try await pass(config, reach: reach, guardrail: guardrail) }
        catch is CancellationError { return decline("intent, input or menu changed during check") }
        catch { return decline("window read failed") }
    }

    func decline(_ reason: String) -> Result {
        stats.fastHideReason = reason
        return .declined(reason)
    }

    private func pass(_ config: TuckConfig, reach: Gather.Reach, guardrail: () throws -> Void) async throws -> Result {
        let startWidth = separator.length
        var revealedForMove = false, effectBegan = false, finished = false
        defer {
            if revealedForMove && !effectBegan && !finished && !(host?.showsHidden ?? true)
                && startWidth > 100 && separator.length == 4 {
                separator.length = startWidth
            }
        }
        var phases: [String: Double] = [:]
        var lapStart = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            phases[name, default: 0] += Double(now - lapStart) / 1_000_000
            lapStart = now
        }

        var step = 0
        while true {
            step += 1
            lap("apply")
            let bar = try await gather(reach, guardrail: guardrail, lap: lap)
            let wasPending = history.pending
            let verdict = assess(config, bar, history)
            history = verdict.history
            if wasPending && !history.pending { resolvedMoves += 1 }

            var acts = false
            switch verdict.next {
            case .move, .settleThenGather: acts = true
            case .done, .stop, .register: break
            }
            if reach == .observeOnly {
                guard !bar.rows.skippedMalformed else { return decline("invalid window snapshot") }
                guard case .done = verdict.next else { return decline(reason(verdict)) }
                try guardrail()
            } else {
                if bar.complete { refreshObserversIfNeeded() }
                if case .done = verdict.next { try guardrail(); try requireQuietInput() }
                if acts {
                    guard step < Limits.passSteps(managed: verdict.layout?.order.count ?? 0) else {
                        throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Layout pass budget reached; continuing later"))
                    }
                    // Before revealing, so a busy user never sees a reveal the defer undoes.
                    try requireQuietInput()
                    host?.willApply()
                }
            }
            switch verdict.boundary {
            case .keep: break
            case .reveal: revealedForMove = acts; separator.length = 4
            case .hide: revealedForMove = false; separator.length = 10_000
            }

            switch verdict.next {
            case .done(let note):
                finished = true
                if reach == .observeOnly {
                    stats.fastHides += 1
                    stats.fastHideReason = nil
                    return .applied(note: note)
                }
                if observers.isRefreshing || observers.issues.contains(where: { $0.recovery == .retry }) {
                    throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting for observation subscriptions"))
                }
                lap("apply")
                stats.reconciles += 1
                stats.reconcilePhases = phases
                stats.reconcileMS = phases.values.reduce(0, +)
                return .applied(note: note)
            case .stop(let issue):
                throw DeferredWork(issue: issue)
            case .register(let items, let order):
                let store = self.store
                _ = try await files.run { try store.registerSnapshot(items, orderedIDs: order, preserveObservedPositions: true) }
                try guardrail()
                lap("register")
                // Discovery only writes; the watcher adopts.
                throw DeferredWork(issue: WorkIssue(recovery: .awaitChange, message: "Waiting for discovered config revision"))
            case .settleThenGather:
                try await Task.sleep(nanoseconds: 100_000_000)
                try guardrail()
            case .move(let move, let subject):
                try await perform(move, subject, guardrail: guardrail, began: { effectBegan = true })
                try guardrail()
            }
        }
    }

    /// One window-list read; AX only for the apps the carried bar cannot vouch for, and
    /// none in observe-only reach.
    private func gather(_ reach: Gather.Reach, guardrail: () throws -> Void, lap: (String) -> Void) async throws -> MenuBar {
        let started = DispatchTime.now().uptimeNanoseconds
        let rows = try await Gather.rows(on: windows)
        try guardrail()
        lap("windows")
        bar = try await Gather.bar(rows, previous: bar, reach: reach, reader: reader, check: guardrail)
        lap("apps")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        if reach == .full { stats.scans += 1; stats.scanMS = elapsed } else { stats.visibilityCheckMS = elapsed }
        return bar
    }

    /// Records `.began` at the moment the effect can have reached the OS, and a
    /// permanent refusal when the mechanism declined before posting anything.
    private func perform(_ move: Move, _ subject: Subject, guardrail: () throws -> Void, began: () -> Void) async throws {
        stats.moves += 1
        var posted = false
        func begin() {
            posted = true
            began()
            history = history.record(.began(move))
        }
        do {
            switch subject {
            case .own(let item, let shift):
                try await placeOwnedItem(item == .separator ? separator : control, shift: shift, began: begin)
            case .icon(let drag):
                try await mover.move(drag, label: move.label, isCurrent: { (try? guardrail()) != nil }, didBegin: begin)
            }
        } catch let failure as MovementFailure where !posted && failure.recovery == .awaitChange {
            history = history.record(.refused(move, reason: failure.message, permanent: true))
        }
    }

    private func placeOwnedItem(_ item: NSStatusItem, shift: CGFloat, began: () -> Void) async throws {
        guard let native = item.value(forKey: "cgsItem") as? NSObject,
              native.responds(to: NSSelectorFromString("setPreferredPosition:")),
              native.responds(to: NSSelectorFromString("rebuildStatusBar")),
              let preference = native.value(forKey: "preferredPosition") as? NSNumber else {
            throw MovementFailure(message: "Native status-item positioning unavailable on this macOS version")
        }
        let desired = preference.floatValue - Float(shift)
        began()
        native.setValue(desired, forKey: "preferredPosition")
        let selector = NSSelectorFromString("rebuildStatusBar")
        typealias Rebuild = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(native.method(for: selector), to: Rebuild.self)(native, selector)
        if let name = item.autosaveName { UserDefaults.standard.set(desired, forKey: "NSStatusItem Preferred Position " + name) }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func requireQuietInput() throws {
        guard !observers.isMenuOpen, !mover.userIsBusy else {
            host?.waitForInput()
            throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting for user input/menu to finish"))
        }
    }

    private func refreshObserversIfNeeded() {
        let targets = Set(bar.roles.map(\.pid))
        if targets != observerTargets || (!observers.isRefreshing && observers.issues.contains(where: { $0.recovery == .retry })) {
            observerTargets = targets
            observers.refresh(pids: targets)
        }
    }

    private func reason(_ verdict: Verdict) -> String {
        switch verdict.next {
        case .stop(let issue): return issue.message
        case .register: return "new icons need registration"
        case .move, .settleThenGather: return "layout needs moves"
        case .done: return ""
        }
    }
}

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
