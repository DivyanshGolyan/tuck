import AppKit
import ApplicationServices
import TuckCore
import os
import Darwin

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
final class AppDelegate: NSObject, NSApplicationDelegate, PassHost {
    private let mover = Mover()
    private let observers = IconObservers()
    private let files = SerialWorker(label: "local.tuck.files")
    private let log = Logger(subsystem: "local.tuck", category: "lifecycle")
    private let configURL: URL
    private let runtimeURL: URL
    private let store: ConfigStore
    private var config: TuckConfig?
    private var showHidden: Bool { config?.showHidden ?? false }
    private var watcher: ConfigWatcher?
    private var control: NSStatusItem!
    private var separator: NSStatusItem!
    private var reconciler: Reconciler!
    private var lastConfigLoadMS: Double = 0
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
    private var retries = 0
    private var retryDelay: TimeInterval?
    private var lastRuntime: Data?
    private var pendingRuntime: Data?
    private var runtimeWork: Task<Void, Never>?

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
        reconciler = Reconciler(separator: separator, control: control, mover: mover, observers: observers,
                                store: store, files: files, host: self)
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
                // The same pass in observe-only reach: hides at once when the carried bar
                // still vouches for every app and the layout needs no move. Otherwise
                // the full pass, already requested by the reload, does the work.
                if !showHidden, let config, accessibility, !observers.isMenuOpen, !mover.userIsBusy {
                    let generation = gate.generation
                    _ = try? await reconciler.run(config, reach: .observeOnly) { [unowned self] in
                        guard request == self.configRequest, generation == self.gate.generation, !self.terminating,
                              !self.showHidden, !Mover.sessionIsLocked, !self.observers.isMenuOpen, !self.mover.userIsBusy
                        else { throw CancellationError() }
                    }
                } else if !showHidden {
                    _ = reconciler.decline(accessibility ? "input or menu before check" : "permission not verified")
                }
                writeRuntime()
            }
        } catch {
            if error is CancellationError { needsConfig = true; throw error }
            let issue = issue(for: error)
            if issue.recovery == .retry { needsConfig = true }
            throw DeferredWork(issue: issue)
        }
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

    var showsHidden: Bool { showHidden }

    func willApply() {
        phase = "applying"; writeRuntime()
    }

    func waitForInput() {
        guard deferredMouseMonitor == nil else { return }
        deferredMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .flagsChanged]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.mover.userIsBusy else { return }
                if let monitor = self.deferredMouseMonitor { NSEvent.removeMonitor(monitor); self.deferredMouseMonitor = nil }
                self.request(significant: true)
            }
        }
    }

    func audited(disagreed: Bool) {
        writeRuntime()
        if disagreed { request() }
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
            let resolvedMoves = self.reconciler.resolvedMoves
            do {
                try self.check(token)
                // Revealing our own boundary is safe without another process's
                // geometry. Busy providers must not unnecessarily delay access.
                if self.showHidden { self.separator.length = 4 }
                // Not on SerialWorker.system: a post-pass audit's AX read may hold it, and
                // a pass that needs no AX must not wait behind one.
                self.accessibility = AXIsProcessTrusted()
                try self.check(token)
                guard self.accessibility else {
                    self.separator.length = 4
                    throw DeferredWork(issue: WorkIssue(recovery: .awaitChange, message: "Accessibility permission required"))
                }
                guard let config = self.config else { throw CancellationError() }
                let revision = self.desiredRevision
                let result = try await self.reconciler.run(config, reach: .full) {
                    try self.check(token)
                    guard self.desiredRevision == revision else { throw CancellationError() }
                }
                guard case .applied(let note) = result else { preconditionFailure("A full pass never declines") }
                layoutNote = note
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
            // A settled move outcome starts the next wait from the shortest delay.
            if self.reconciler.resolvedMoves != resolvedMoves { self.backoff.reset() }
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

    private func issue(for error: Error) -> WorkIssue {
        if let deferred = error as? DeferredWork { return deferred.issue }
        if let read = error as? AXReadFailure { return read.issue }
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
        let bar = reconciler?.bar ?? .none
        let stats = reconciler?.stats ?? PassStats()
        let roster = Roster(bar, items: config?.items)
        let reference = bar.referenceRow
        let data: [String: Any] = ["accessibility": accessibility, "sessionLocked": Mover.sessionIsLocked,
            "menuOpen": observers.isMenuOpen, "menuCount": observers.menuCount, "menuPIDs": observers.menuPIDs,
            "inputBusy": mover.userIsBusy, "menuChecks": observers.menuChecks,
            "menuCheckResult": observers.lastMenuCheckResult as Any? ?? NSNull(),
            "menuCheckReason": observers.lastMenuCheckReason as Any? ?? NSNull(),
            "showHidden": showHidden, "config": configURL.path, "scans": stats.scans, "moves": stats.moves,
            "configLoads": configLoads, "ambiguous": roster.collisions.map { "Ambiguous config alias: " + $0 },
            "pid": getpid(),
            "clickTraces": clickTraces.map { trace in
                ["id": trace.id, "mouseUpNS": trace.mouseUpNS, "acceptedNS": trace.acceptedNS,
                 "committedNS": trace.committedNS as Any? ?? NSNull(),
                 "showHidden": trace.showHidden as Any? ?? NSNull()] as [String: Any]
            },
            "reconcileMS": stats.reconcileMS, "reconciles": stats.reconciles, "reconcilePhases": stats.reconcilePhases,
            "scanMS": stats.scanMS, "configLoadMS": lastConfigLoadMS,
            "visibilityCheckMS": stats.visibilityCheckMS, "fastHides": stats.fastHides,
            "fastHideReason": stats.fastHideReason as Any? ?? NSNull(),
            "verifiedLayout": bar.reusable, "auditMismatches": bar.auditMismatches,
            "icons": roster.icons.map { ["id": $0.id, "label": $0.role.label, "movable": $0.role.movable, "x": $0.frame.minX] as [String: Any] },
            "hiddenIDs": config?.hidden ?? [], "revision": desiredRevision,
            "appliedRevision": appliedRevision as Any? ?? NSNull(), "workGeneration": gate.generation,
            "appliedGeneration": gate.applied as Any? ?? NSNull(), "phase": phase,
            "pending": gate.pending || gate.running != nil || needsConfig || toggleWork != nil,
            "applying": phase == "applying", "error": lastError as Any? ?? NSNull(),
            "waiting": waiting as Any? ?? NSNull(), "retryDelay": retryDelay as Any? ?? NSNull(), "retries": retries,
            "controlX": reference.map { bar.rows.control[$0].frame.minX } ?? -1,
            "separatorX": reference.map { bar.rows.separator[$0].frame.minX } ?? -1,
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
