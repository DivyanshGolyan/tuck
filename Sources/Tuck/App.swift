import AppKit
import ApplicationServices
import TuckCore
import os
import Darwin

private struct DeferredWork: Error { let issue: WorkIssue }

private func elapsedMS(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private struct ClickTrace {
    let id: Int
    let mouseUpNS: UInt64
    let acceptedNS: UInt64
    var committedNS: UInt64?
    var showHidden: Bool?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inventory = Inventory()
    private let mover = Mover()
    private let observers = IconObservers()
    private let files = SerialWorker(label: "local.tuck.files")
    private let geometry = SerialWorker(label: "local.tuck.visibility")
    private let log = Logger(subsystem: "local.tuck", category: "lifecycle")
    private let configURL: URL
    private let runtimeURL: URL
    private let store: ConfigStore
    private var config: TuckConfig?
    private var showHidden: Bool { config?.showHidden ?? false }
    private var watcher: ConfigWatcher?
    private var control: NSStatusItem!
    private var separator: NSStatusItem!
    private var ownFrames: [String: BarIcon] = [:]
    private var observationY: CGFloat?
    private var verifiedLayout: VerifiedVisibilityLayout?
    private var fastHides = 0
    private var fastHideReason: String?
    private var lastScanMS: Double = 0
    private var lastConfigLoadMS: Double = 0
    private var lastVisibilityCheckMS: Double = 0
    private var lastReconcileMS: Double = 0
    private var reconciles = 0
    private var reconcilePhases: [String: Double] = [:]
    private var snapshot = InventorySnapshot(icons: [], ambiguous: [])
    private var gate = LatestWork()
    private var backoff = RetryBackoff()
    private var work: Task<Void, Never>?
    private var retryWake: Task<Void, Never>?
    private var configWork: Task<Void, Never>?
    private var toggleWork: Task<Void, Never>?
    private var togglePending = false
    private var acceptedClickSequence = 0
    private var clickTraces: [ClickTrace] = []
    private var toggleDeferred = false
    private var queued = false
    private var needsConfig = true
    private var configRequest = 0
    private var terminating = false
    private var sessionActive = true
    private var accessibility = false
    private var requestedAccessibility = false
    private var workspaceTokens: [NSObjectProtocol] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var deferredMouseMonitor: Any?
    private var sessionFD: Int32 = -1
    private var desiredRevision = 0
    private var appliedRevision: Int?
    private var phase = "starting"
    private var waiting: String?
    private var lastError: String?
    private var configLoads = 0
    private var scans = 0
    private var moves = 0
    private var retries = 0
    private var retryDelay: TimeInterval?
    private var lastRuntime: Data?
    private var pendingRuntime: Data?
    private var runtimeWork: Task<Void, Never>?
    // An effect is never replayed just because observation timed out. Resolve its
    // postcondition using fresh reads before deciding whether any new effect is safe.
    private var unverifiedMove: MoveVerification?
    private var moveAttempts = MoveAttempts()
    private var observerTargets: Set<pid_t> = []

    init(configURL: URL) {
        self.configURL = configURL
        runtimeURL = configURL.deletingLastPathComponent().appendingPathComponent("runtime.json")
        store = ConfigStore(url: configURL)
        super.init()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         handler: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated { handler(notification) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Even startup filesystem work is not a dependency of the main run loop.
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let directory = self.configURL.deletingLastPathComponent()
                let fd = try await self.files.run { () throws -> Int32 in
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/local.tuck")
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    let fd = open(cache.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
                    guard fd >= 0 else { throw ConfigStoreError.io("instance lock", errno) }
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return -1 }
                    return fd
                }
                self.work = nil
                guard fd >= 0 else { NSApp.terminate(nil); return }
                if self.terminating { close(fd); self.finishTerminationIfReady(); return }
                self.sessionFD = fd
                self.start()
            } catch {
                self.work = nil
                if self.terminating { self.finishTerminationIfReady() }
                else { self.report(error); NSApp.terminate(nil) }
            }
        }
    }

    private func start() {
        NSApp.setActivationPolicy(.accessory)
        separator = NSStatusBar.system.statusItem(withLength: 4)
        separator.autosaveName = "TuckSeparator"
        separator.button?.title = "│"
        separator.button?.setAccessibilityIdentifier("TuckSeparator")
        separator.button?.setAccessibilityLabel("Tuck hidden icons boundary")
        UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position TuckControl")
        control = NSStatusBar.system.statusItem(withLength: 20)
        control.autosaveName = "TuckControl"
        control.button?.setAccessibilityIdentifier("TuckControl")
        control.button?.target = self
        control.button?.action = #selector(clicked)
        control.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateControl()
        watcher = ConfigWatcher(url: configURL) { [weak self] in self?.request(reload: true) }
        observers.changed = { [weak self] in
            guard let self, self.phase != "applying" else { return }
            self.request()
        }
        observers.menuChanged = { [weak self] open in
            guard let self else { return }
            if open { self.work?.cancel() }
            else if self.gate.pending { self.request() }
            self.updateMenuRecoveryNeed()
        }
        observers.diagnosticsChanged = { [weak self] in self?.writeRuntime() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceTokens.append(observe(center, name) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.sessionDidBecomeActiveNotification { self.sessionActive = true }
                self.observers.refresh(); self.request(significant: true)
            })
        }
        workspaceTokens.append(observe(center, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            guard let self else { return }
            self.sessionActive = false
            self.retryWake?.cancel(); self.retryWake = nil
            self.work?.cancel(); self.gate.deferPending()
            self.updateMenuRecoveryNeed()
            self.phase = "suspended"; self.writeRuntime()
        })
        workspaceTokens.append(observe(center, NSWorkspace.didActivateApplicationNotification) { [weak self] _ in
            guard let self, !Mover.sessionIsLocked else { return }
            if !self.accessibility || self.phase == "suspended" || self.phase == "waiting-input" {
                self.observers.refresh(); self.request(significant: true)
            }
        })
        notificationTokens.append(observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            // A different display arrangement can make an abandoned move possible.
            self?.moveAttempts.reset()
            self?.request(significant: true)
        })
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification] {
            notificationTokens.append(observe(NotificationCenter.default, name) { [weak self] _ in
                guard let self, self.phase != "applying" else { return }
                self.request()
            })
        }
        observers.refresh()
        request(reload: true)
    }

    /// The sole adoption path, whether an editor, discovery, or the chevron wrote.
    private func loadConfig() async throws {
        guard needsConfig else { return }
        needsConfig = false
        let request = configRequest
        let started = DispatchTime.now().uptimeNanoseconds
        let store = self.store
        do {
            let loaded = try await files.run { try store.loadSnapshot() }
            guard !terminating else { throw CancellationError() }
            guard request == configRequest else { needsConfig = true; return }
            configLoads += 1
            lastConfigLoadMS = elapsedMS(since: started)
            if config != loaded.config {
                var previousPlacement = config
                previousPlacement?.showHidden = loaded.config.showHidden
                let visibilityOnly = previousPlacement == loaded.config
                if !visibilityOnly { verifiedLayout = nil; moveAttempts.reset() }
                config = loaded.config
                desiredRevision += 1
                backoff.reset()
                // Desired intent can change, but an already-posted effect's
                // unknown outcome must still be verified before another action.
                appliedRevision = nil
                // Config adoption never waits behind AX IPC or physical input.
                // Revealing our own boundary needs no foreign geometry.
                if showHidden { separator.length = 4 }
                updateControl()
                if !showHidden && visibilityOnly { await hideVerifiedLayout(request: request) }
                writeRuntime()
            }
        } catch {
            if error is CancellationError { needsConfig = true; throw error }
            let issue = issue(for: error)
            if issue.recovery == .retry { needsConfig = true }
            throw DeferredWork(issue: issue)
        }
    }

    /// A visibility-only edit doesn't require rediscovering every AX provider.
    /// Check fresh window membership and order against a fully verified layout;
    /// a new/missing/reordered window falls back to normal reconciliation.
    private func hideVerifiedLayout(request: Int) async {
        guard let verifiedLayout else { fastHideReason = "no verified layout"; return }
        guard unverifiedMove == nil else { fastHideReason = "move outcome unknown"; return }
        guard accessibility else { fastHideReason = "permission not verified"; return }
        guard !observers.isMenuOpen, !mover.userIsBusy else { fastHideReason = "input or menu before check"; return }
        let generation = gate.generation
        let started = DispatchTime.now().uptimeNanoseconds
        guard let fresh = try? await geometry.run({ try WindowLayoutSnapshot.read() }) else { fastHideReason = "window read failed"; return }
        lastVisibilityCheckMS = elapsedMS(since: started)
        guard request == configRequest else { fastHideReason = "config changed during check"; return }
        guard generation == gate.generation else { fastHideReason = "work generation changed during check"; return }
        guard !terminating, !showHidden, !Mover.sessionIsLocked else { fastHideReason = "intent, lock or termination changed"; return }
        guard unverifiedMove == nil, !observers.isMenuOpen, !mover.userIsBusy else { fastHideReason = "input, menu or move during check"; return }
        if let reason = verifiedLayout.mismatchReason(fresh) { fastHideReason = reason; return }
        guard let config else { fastHideReason = "config missing"; return }
        let available = Set(snapshot.icons.filter(\.movable).map(\.id))
        separator.length = config.hidden.contains(where: available.contains) ? 10_000 : 4
        fastHides += 1
        fastHideReason = nil
    }

    /// Independent file adoption prevents a slow AX call from delaying a click.
    /// The watcher remains the sole entry point for every config writer.
    private func drainConfigLoads() {
        guard configWork == nil, needsConfig, !terminating else { return }
        configWork = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.needsConfig && !self.terminating {
                let request = self.configRequest
                do { try await self.loadConfig() }
                catch {
                    if request != self.configRequest { continue }
                    if !self.terminating {
                        let problem = self.issue(for: error)
                        if problem.recovery == .retry { self.scheduleRetry(problem) }
                        else {
                            self.gate.abandonPending(); self.phase = "blocked"
                            self.lastError = problem.message; self.waiting = nil
                        }
                        self.updateControl(); self.writeRuntime()
                    }
                    break
                }
            }
            self.configWork = nil
            self.updateMenuRecoveryNeed()
            if self.gate.pending && self.retryWake == nil { self.queuePump() }
            self.finishTerminationIfReady()
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return }
        if NSApp.currentEvent?.cgEvent?.getIntegerValueField(.eventSourceUserData) == Mover.eventTag { return }
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        let event = NSApp.currentEvent
        let mouseUpNS: UInt64 = event?.type == .leftMouseUp
            ? (event?.cgEvent?.timestamp ?? UInt64((event?.timestamp ?? 0) * 1_000_000_000)) : 0
        acceptedClickSequence += 1
        clickTraces.append(ClickTrace(id: acceptedClickSequence, mouseUpNS: mouseUpNS,
            acceptedNS: DispatchTime.now().uptimeNanoseconds))
        if clickTraces.count > 64 { clickTraces.removeFirst(clickTraces.count - 64) }
        // Coalesce queued clicks by parity, not a stale in-memory desired value.
        // The transaction itself always toggles the latest file under its lock.
        togglePending.toggle()
        drainToggles()
        if !accessibility && !requestedAccessibility && !CommandLine.arguments.contains("--no-prompt") {
            requestedAccessibility = true
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }

    private func drainToggles() {
        guard toggleWork == nil, togglePending, !terminating,
              !(toggleDeferred && retryWake != nil) else { return }
        togglePending = false
        let store = self.store
        let clickID = acceptedClickSequence
        toggleWork = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receipt = try await self.files.run {
                    let configSnapshot = try store.toggleShowHiddenSnapshot()
                    let committedNS = DispatchTime.now().uptimeNanoseconds
                    return (configSnapshot.config.showHidden, committedNS)
                }
                if let index = self.clickTraces.firstIndex(where: { $0.id == clickID }) {
                    self.clickTraces[index].showHidden = receipt.0
                    self.clickTraces[index].committedNS = receipt.1
                }
                self.toggleDeferred = false
                // No adoption, spacer mutation, or manual reload: the watcher owns it.
            } catch {
                let issue = self.issue(for: error)
                if issue.recovery == .retry {
                    self.togglePending.toggle() // failed transaction made no change
                    self.toggleDeferred = true
                    self.scheduleRetry(issue)
                } else { self.toggleDeferred = false; self.report(error) }
                self.writeRuntime()
            }
            self.toggleWork = nil
            self.drainToggles()
            self.updateMenuRecoveryNeed()
            if self.gate.pending && self.retryWake == nil { self.queuePump() }
            self.finishTerminationIfReady()
        }
    }

    private func updateControl() {
        let image = NSImage(systemSymbolName: showHidden ? "chevron.right" : "chevron.left",
            accessibilityDescription: showHidden ? "Hide hidden icons" : "Show hidden icons")
        image?.isTemplate = true
        control?.button?.image = image
        control?.button?.toolTip = lastError.map { "Tuck: \($0)" } ?? waiting.map { "Tuck: \($0)" }
            ?? (showHidden ? "Click to hide icons" : "Click to reveal hidden icons")
        control?.button?.setAccessibilityLabel(showHidden ? "Hide hidden icons" : "Show hidden icons")
    }

    private func showMenu() {
        let menu = NSMenu()
        if let message = lastError ?? waiting {
            let item = menu.addItem(withTitle: message, action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(.separator())
        }
        let edit = menu.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ""); edit.target = self
        let quit = menu.addItem(withTitle: "Quit Tuck", action: #selector(quit), keyEquivalent: ""); quit.target = self
        control.menu = menu; control.button?.performClick(nil); control.menu = nil
    }
    @objc private func openConfig() { NSWorkspace.shared.open(configURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func request(reload: Bool = false, significant: Bool = false) {
        guard !terminating else { return }
        needsConfig = needsConfig || reload
        if reload { configRequest += 1 }
        gate.request()
        if reload || significant {
            retryWake?.cancel(); retryWake = nil; retryDelay = nil
            if reload { work?.cancel() }
        }
        if reload { drainConfigLoads() }
        guard retryWake == nil else { return } // noise does not defeat backoff
        queuePump()
    }

    private func queuePump() {
        guard !queued, work == nil, !terminating else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false; self.pump()
        }
    }

    private func waitForInput() {
        guard deferredMouseMonitor == nil else { return }
        deferredMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .flagsChanged]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.mover.userIsBusy else { return }
                if let monitor = self.deferredMouseMonitor { NSEvent.removeMonitor(monitor); self.deferredMouseMonitor = nil }
                self.request(significant: true)
            }
        }
    }

    private func scheduleRetry(_ issue: WorkIssue) {
        waiting = issue.message; lastError = nil; phase = "waiting"
        gate.deferPending()
        guard retryWake == nil, !Mover.sessionIsLocked, !terminating else { return }
        let delay = backoff.nextDelay(); retries += 1; retryDelay = delay
        retryWake = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)); try Task.checkCancellation() }
            catch { return }
            guard let self else { return }
            self.retryWake = nil; self.retryDelay = nil
            self.drainConfigLoads(); self.drainToggles(); self.queuePump()
        }
    }

    private func updateMenuRecoveryNeed() {
        let pending = gate.pending || gate.running != nil || needsConfig || configWork != nil || toggleWork != nil || togglePending
        observers.setMenuRecoveryNeeded(pending && sessionActive && !Mover.sessionIsLocked && !terminating)
    }

    private func pump() {
        updateMenuRecoveryNeed()
        guard work == nil, gate.pending, !terminating else { return }
        if needsConfig { drainConfigLoads(); return }
        if configWork != nil || toggleWork != nil || (toggleDeferred && retryWake != nil) { return }
        guard !Mover.sessionIsLocked else { phase = "suspended"; writeRuntime(); return }
        guard !observers.isMenuOpen, !mover.userIsBusy else {
            phase = "waiting-input"; waiting = "Waiting for user input/menu to finish"
            waitForInput(); writeRuntime(); return
        }
        guard let token = gate.begin() else { return }
        phase = "observing"; lastError = nil; waiting = nil; writeRuntime()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            var applied = false
            var layoutNote: String?
            var deferred: WorkIssue?
            do {
                try self.check(token)
                // Revealing our own boundary is safe without another process's
                // geometry. Busy providers must not unnecessarily delay access.
                if self.showHidden { self.separator.length = 4 }
                self.accessibility = try await SerialWorker.system.run { AXIsProcessTrusted() }
                try self.check(token)
                guard self.accessibility else {
                    self.separator.length = 4
                    throw DeferredWork(issue: WorkIssue(recovery: .awaitChange, message: "Accessibility permission required"))
                }
                layoutNote = try await self.reconcile(token: token)
                applied = true
            } catch is CancellationError {
                if self.gate.isCurrent(token: token) { self.gate.deferPending() }
            } catch let error as DeferredWork {
                if !Task.isCancelled { deferred = error.issue }
            } catch {
                if !Task.isCancelled { deferred = self.issue(for: error) }
            }
            // An OS call may throw its own error after cancellation rather than
            // CancellationError. Either way, a cancelled current run stays dirty.
            if Task.isCancelled && self.gate.isCurrent(token: token) { self.gate.deferPending() }
            // A stale failure must not block a newer desired revision.
            let current = self.gate.isCurrent(token: token)
            self.gate.finish(token: token, applied: applied)
            self.work = nil
            if current, applied {
                self.appliedRevision = self.desiredRevision
                self.backoff.reset(); self.retryWake?.cancel(); self.retryWake = nil; self.retryDelay = nil
                self.phase = "idle"; self.waiting = nil; self.lastError = layoutNote
            } else if current, let deferred {
                switch deferred.recovery {
                case .retry: self.scheduleRetry(deferred)
                case .awaitChange:
                    self.gate.abandonPending(); self.phase = "blocked"
                    self.lastError = deferred.message; self.waiting = nil
                case .discard:
                    self.gate.deferPending(); self.phase = "suspended"
                }
            }
            self.updateMenuRecoveryNeed()
            self.updateControl(); self.writeRuntime()
            self.finishTerminationIfReady()
            if self.gate.pending && self.retryWake == nil { self.queuePump() }
        }
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard gate.isCurrent(token: token), !terminating else { throw CancellationError() }
        guard !Mover.sessionIsLocked else { throw CancellationError() }
    }

    private func scan(token: Int) async throws -> InventorySnapshot {
        scans += 1
        let started = DispatchTime.now().uptimeNanoseconds
        defer { lastScanMS = elapsedMS(since: started) }
        let raw = try await inventory.scan()
        try check(token)
        // AX follows the active bar, whereas named CG owner windows may remain on
        // another display. Never combine geometry from two physical bars.
        if raw.complete {
            guard let row = raw.icons.first?.frame.minY,
                  raw.icons.allSatisfy({ abs($0.frame.minY - row) < 2 }) else {
                throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting for a coherent active menu bar"))
            }
            observationY = row
        }
        guard let config else { return raw }
        var allocated = Set(config.items.keys)
        let mapped = raw.icons.map { icon -> BarIcon in
            let matches = config.items.filter { $0.value.bundleID == icon.metadata.bundleID && $0.value.item == icon.metadata.item }
            let id: String
            if matches.count == 1 { id = matches.first!.key }
            else {
                var candidate = icon.id; var suffix = 2
                while allocated.contains(candidate) { candidate = icon.id + "#" + String(suffix); suffix += 1 }
                id = candidate; allocated.insert(id)
            }
            return BarIcon(id: id, metadata: icon.metadata, pid: icon.pid, windowID: icon.windowID,
                           frame: icon.frame, movable: icon.movable)
        }
        let groups = Dictionary(grouping: mapped, by: \.id)
        let collisions = groups.filter { $0.value.count > 1 }.keys.sorted()
        return InventorySnapshot(icons: mapped.filter { groups[$0.id]?.count == 1 },
            ambiguous: raw.ambiguous + collisions.map { "Ambiguous config alias: " + $0 }, issues: raw.issues,
            statusKeys: raw.statusKeys)
    }

    private func requireComplete(_ value: InventorySnapshot) throws {
        guard value.complete else {
            // Incomplete observations are not a visibility command. In particular,
            // switching the active display must preserve the last physical state.
            let issue = value.issues.first(where: { $0.recovery == .retry }) ?? value.issues.first
                ?? WorkIssue(recovery: .retry, message: value.ambiguous.joined(separator: "; "))
            throw DeferredWork(issue: issue)
        }
    }

    /// Tuck's separator and control from one window-list read; nil unless both
    /// are identified.
    private func ownIcons() async throws -> [BarIcon]? {
        let pid = getpid()
        let row = observationY
        let found: [BarIcon] = try await SerialWorker.system.run {
            let windows = (try? WindowList.readSkippingMalformed())?.list.windows ?? []
            let candidates = windows.filter { $0.key.pid == pid }
            return [OwnItem.separator, .control].compactMap { own in
                let selected: StatusWindow?
                if let row { selected = ownedStatusWindow(title: own.title, menuY: row, candidates: candidates) }
                else {
                    let named = candidates.filter { $0.title == own.title }
                    selected = named.count == 1 ? named[0] : nil
                }
                return selected.map {
                    BarIcon(id: own.id, metadata: ItemMetadata(bundleID: "local.tuck", label: own.id), pid: pid,
                            windowID: $0.key.number, frame: $0.frame, movable: true)
                }
            }
        }
        ownFrames = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return found.count == 2 ? found : nil
    }

    private func placeOwnedItem(_ item: NSStatusItem, icon: BarIcon, before anchor: BarIcon?, rightEdge: CGFloat) async throws {
        guard let native = item.value(forKey: "cgsItem") as? NSObject,
              native.responds(to: NSSelectorFromString("setPreferredPosition:")),
              native.responds(to: NSSelectorFromString("rebuildStatusBar")),
              let preference = native.value(forKey: "preferredPosition") as? NSNumber else {
            throw MovementFailure(message: "Native status-item positioning unavailable on this macOS version")
        }
        let shift = (anchor?.frame.minX ?? rightEdge) - icon.frame.maxX
        let desired = preference.floatValue - Float(shift)
        native.setValue(desired, forKey: "preferredPosition")
        let selector = NSSelectorFromString("rebuildStatusBar")
        typealias Rebuild = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(native.method(for: selector), to: Rebuild.self)(native, selector)
        if let name = item.autosaveName { UserDefaults.standard.set(desired, forKey: "NSStatusItem Preferred Position " + name) }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func label(for id: String) -> String {
        if id == Inventory.separatorID || id == Inventory.controlID { return "Tuck's own item" }
        return config?.items[id]?.label ?? id
    }

    /// Movable icons and Tuck's own two items, left to right.
    private func managedIcons(_ scan: InventorySnapshot) async throws -> [BarIcon] {
        guard let own = try await ownIcons() else {
            throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting for menu bar windows"))
        }
        return (scan.icons.filter(\.movable) + own).sorted { $0.frame.minX < $1.frame.minX }
    }

    private func requireQuietInput() throws {
        guard !observers.isMenuOpen, !mover.userIsBusy else {
            waitForInput()
            throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting for user input/menu to finish"))
        }
    }

    /// Returns why the applied layout is not in configured order, or nil when it is.
    private func reconcile(token: Int) async throws -> String? {
        guard let config else { throw CancellationError() }
        let previousWidth = separator.length
        var beganEffect = false
        var completed = false
        defer {
            // A cancelled/failed preflight must not become an accidental reveal.
            // Never restore over a new reveal request or an uncertain input effect.
            if !completed && !beganEffect && !showHidden && previousWidth > 100 && separator.length == 4 {
                separator.length = previousWidth
            }
        }
        let revision = desiredRevision
        var lapStart = DispatchTime.now().uptimeNanoseconds
        var phases: [String: Double] = [:]
        func lap(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            phases[name, default: 0] += Double(now - lapStart) / 1_000_000
            lapStart = now
        }
        var fresh = try await scan(token: token)
        lap("scan")
        try requireComplete(fresh)
        // The scan's own starting window list is the "before" that the final
        // read must still match for the layout to count as verified.
        let beforeKeys = fresh.statusKeys
        snapshot = fresh // never publish disappearance from an incomplete scan
        let targets = Set(fresh.icons.map(\.pid))
        if targets != observerTargets || (!observers.isRefreshing && observers.issues.contains(where: { $0.recovery == .retry })) {
            observerTargets = targets
            observers.refresh(pids: targets)
        }
        let discovered = Dictionary(uniqueKeysWithValues: fresh.icons.map { ($0.id, $0.metadata) })
        let orderedIDs = fresh.icons.map(\.id)
        let store = self.store
        let registered = try await files.run {
            try store.registerSnapshot(discovered, orderedIDs: orderedIDs, preserveObservedPositions: true)
        }
        try check(token)
        lap("register")
        guard registered.config == config else {
            // Discovery is only a writer. The normal file watch performs adoption.
            throw DeferredWork(issue: WorkIssue(recovery: .awaitChange, message: "Waiting for discovered config revision"))
        }
        var observed = try await managedIcons(fresh)
        try check(token)
        lap("ownIcons")
        let available = Set(fresh.icons.filter(\.movable).map(\.id))
        let hidden = config.hidden.filter { available.contains($0) }
        let visible = config.visible.filter { available.contains($0) } + [Inventory.controlID]
        var order = observed.map(\.id)
        var plan = try LayoutPlanner.plan(hidden: hidden, visible: visible, observed: order, separatorID: Inventory.separatorID)
        if var verification = unverifiedMove {
            let decision = verification.observe(order: order, goalSatisfied: plan.isEmpty)
            unverifiedMove = verification
            switch decision {
            case .verified: unverifiedMove = nil
            case .wait:
                throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting to verify previous move"))
            case .awaitChange:
                // Three unchanged reads resolve the outcome: the gesture had no
                // effect. That permits a bounded fresh attempt, not a permanent stop.
                unverifiedMove = nil
                backoff.reset()
                moveAttempts.fail(order: order,
                    reason: "Could not move \(label(for: verification.itemID)); order left unchanged")
            }
        }
        var degraded: String?
        var budget = max(4, observed.count * 2)
        while !plan.isEmpty && budget > 0 {
            try check(token)
            // Checked before revealing, so an abandoned order never flickers.
            if let reason = moveAttempts.abandoned(order: order) { degraded = reason; break }
            try requireQuietInput()
            separator.length = 4
            phase = "applying"; writeRuntime()
            try await Task.sleep(nanoseconds: 100_000_000)
            fresh = try await scan(token: token); try requireComplete(fresh)
            observed = try await managedIcons(fresh)
            try check(token)
            let byID = Dictionary(uniqueKeysWithValues: observed.map { ($0.id, $0) })
            order = observed.map(\.id)
            plan = try LayoutPlanner.plan(hidden: hidden, visible: visible, observed: order, separatorID: Inventory.separatorID)
            guard let move = plan.first, let icon = byID[move.id] else { break }
            if let reason = moveAttempts.abandoned(order: order) { degraded = reason; break }
            let managedRight = observed.map { $0.frame.maxX }.max() ?? 0
            let fixed = fresh.icons.filter { !$0.movable && $0.frame.minX >= managedRight - 1 }.map { $0.frame.minX }.min()
            let edge = fixed.map { $0 - 1 } ?? managedRight - 1
            let before = order
            let anchor = move.before.flatMap { byID[$0] }
            if icon.id == Inventory.separatorID || icon.id == Inventory.controlID {
                beganEffect = true
                unverifiedMove = MoveVerification(itemID: move.id, before: before)
                try await placeOwnedItem(icon.id == Inventory.separatorID ? separator : control,
                    icon: icon, before: anchor, rightEdge: edge)
            } else {
                do {
                    try await mover.move(icon, before: anchor, rightEdge: edge,
                        isCurrent: { [weak self] in self?.gate.isCurrent(token: token) == true && self?.terminating == false },
                        didBegin: { [weak self] in
                            beganEffect = true
                            self?.unverifiedMove = MoveVerification(itemID: move.id, before: before)
                        })
                } catch let failure as MovementFailure where failure.recovery == .awaitChange && unverifiedMove == nil {
                    // Nothing was posted and retrying cannot help (for example an
                    // icon behind the notch). Give up on this order, not on hiding.
                    moveAttempts.fail(order: order, reason: failure.message, final: true)
                    degraded = failure.message
                    break
                }
            }
            moves += 1; budget -= 1
            try check(token)
            let after = try await scan(token: token); try requireComplete(after)
            snapshot = after; fresh = after
            order = try await managedIcons(after).map(\.id)
            if order == before {
                throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting to verify previous move"))
            }
            unverifiedMove = nil
            plan = try LayoutPlanner.plan(hidden: hidden, visible: visible, observed: order, separatorID: Inventory.separatorID)
        }
        if !plan.isEmpty {
            guard let degraded else {
                throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Layout pass budget reached; continuing later"))
            }
            // Order inside a group is cosmetic. Hiding only requires that nothing
            // meant to stay visible sits left of the boundary; a hidden-group icon
            // stranded on the right merely stays visible.
            let keep = Set(visible)
            guard let boundaryIndex = order.firstIndex(of: Inventory.separatorID),
                  !order[..<boundaryIndex].contains(where: keep.contains) else {
                throw DeferredWork(issue: WorkIssue(recovery: .awaitChange, message: degraded + "; icons left accessible"))
            }
        }
        try check(token)
        guard desiredRevision == revision else { throw CancellationError() }
        try requireQuietInput()
        guard !fresh.icons.contains(where: { config.items[$0.id] == nil }) else {
            throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting to register newly observed icons"))
        }
        separator.length = !showHidden && !hidden.isEmpty ? 10_000 : 4
        snapshot = fresh
        if observers.isRefreshing || observers.issues.contains(where: { $0.recovery == .retry }) {
            throw DeferredWork(issue: WorkIssue(recovery: .retry, message: "Waiting for observation subscriptions"))
        }
        let finalIcons = fresh.icons + [Inventory.separatorID, Inventory.controlID].compactMap { ownFrames[$0] }
        if let beforeKeys, let afterGeometry = try? await geometry.run({ try WindowLayoutSnapshot.read() }) {
            try check(token)
            verifiedLayout = VerifiedVisibilityLayout(before: beforeKeys, after: afterGeometry, icons: finalIcons)
        } else { verifiedLayout = nil }
        lap("verify")
        reconciles += 1
        reconcilePhases = phases
        lastReconcileMS = phases.values.reduce(0, +)
        completed = true
        return plan.isEmpty ? nil : degraded
    }

    private func issue(for error: Error) -> WorkIssue {
        if let deferred = error as? DeferredWork { return deferred.issue }
        if let movement = error as? MovementFailure { return WorkIssue(recovery: movement.recovery, message: movement.message) }
        if let store = error as? ConfigStoreError {
            switch store {
            case .busy, .concurrentModification: return WorkIssue(recovery: .retry, message: store.description)
            case .io(_, let code) where [EINTR, EAGAIN, EBUSY, ETIMEDOUT].contains(code):
                return WorkIssue(recovery: .retry, message: store.description)
            default: return WorkIssue(recovery: .awaitChange, message: store.description)
            }
        }
        if error is DecodingError { return WorkIssue(recovery: .awaitChange, message: "Invalid config; keeping last verified layout") }
        return WorkIssue(recovery: .awaitChange, message: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }
    private func report(_ error: Error) {
        let message = issue(for: error).message
        if lastError != message { log.error("\(message, privacy: .public)") }
        lastError = message; updateControl()
    }

    private func writeRuntime() {
        let data: [String: Any] = ["accessibility": accessibility, "sessionLocked": Mover.sessionIsLocked,
            "menuOpen": observers.isMenuOpen, "menuCount": observers.menuCount, "menuPIDs": observers.menuPIDs,
            "inputBusy": mover.userIsBusy, "menuChecks": observers.menuChecks,
            "menuCheckResult": observers.lastMenuCheckResult as Any? ?? NSNull(),
            "menuCheckReason": observers.lastMenuCheckReason as Any? ?? NSNull(),
            "showHidden": showHidden, "config": configURL.path, "scans": scans, "moves": moves,
            "configLoads": configLoads, "ambiguous": snapshot.ambiguous, "pid": getpid(),
            "clickTraces": clickTraces.map { trace in
                ["id": trace.id, "mouseUpNS": trace.mouseUpNS, "acceptedNS": trace.acceptedNS,
                 "committedNS": trace.committedNS as Any? ?? NSNull(),
                 "showHidden": trace.showHidden as Any? ?? NSNull()] as [String: Any]
            },
            "reconcileMS": lastReconcileMS, "reconciles": reconciles, "reconcilePhases": reconcilePhases,
            "scanMS": lastScanMS, "configLoadMS": lastConfigLoadMS,
            "visibilityCheckMS": lastVisibilityCheckMS, "fastHides": fastHides,
            "fastHideReason": fastHideReason as Any? ?? NSNull(),
            "verifiedLayout": verifiedLayout != nil,
            "icons": snapshot.icons.map { ["id": $0.id, "label": $0.metadata.label, "movable": $0.movable, "x": $0.frame.minX] as [String: Any] },
            "hiddenIDs": config?.hidden ?? [], "revision": desiredRevision,
            "appliedRevision": appliedRevision as Any? ?? NSNull(), "workGeneration": gate.generation,
            "appliedGeneration": gate.applied as Any? ?? NSNull(), "phase": phase,
            "pending": gate.pending || gate.running != nil || needsConfig || toggleWork != nil,
            "applying": phase == "applying", "error": lastError as Any? ?? NSNull(),
            "waiting": waiting as Any? ?? NSNull(), "retryDelay": retryDelay as Any? ?? NSNull(), "retries": retries,
            "controlX": ownFrames[Inventory.controlID]?.frame.minX ?? -1,
            "separatorX": ownFrames[Inventory.separatorID]?.frame.minX ?? -1,
            "separatorWidth": separator?.length ?? -1]
        guard let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), bytes != lastRuntime else { return }
        lastRuntime = bytes; pendingRuntime = bytes
        guard runtimeWork == nil else { return }
        runtimeWork = Task { @MainActor [weak self] in
            guard let self else { return }
            while let next = self.pendingRuntime {
                self.pendingRuntime = nil
                let url = self.runtimeURL
                try? await self.files.run { try next.write(to: url, options: .atomic) }
            }
            self.runtimeWork = nil
        }
    }

    private func finishTerminationIfReady() {
        if terminating && work == nil && toggleWork == nil && configWork == nil { NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true; updateMenuRecoveryNeed()
        retryWake?.cancel(); retryWake = nil
        work?.cancel(); togglePending = false
        guard work != nil || toggleWork != nil || configWork != nil else { return .terminateNow }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        observers.setMenuRecoveryNeeded(false)
        retryWake?.cancel(); work?.cancel(); separator?.length = 4
        if let control { NSStatusBar.system.removeStatusItem(control) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        if let monitor = deferredMouseMonitor { NSEvent.removeMonitor(monitor) }
        if sessionFD >= 0 { flock(sessionFD, LOCK_UN); close(sessionFD) }
    }
}
