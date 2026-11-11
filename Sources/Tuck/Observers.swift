import AppKit
import ApplicationServices
import Darwin
import TuckCore

/// Context ownership is independent of the facade. A registration retains this
/// until its main run-loop source has been detached; queued deliveries retain it.
private final class ObserverRelay {
    let pid: pid_t
    let incarnation = UUID().uuidString
    let applicationIncarnation: String
    let deliver: @MainActor (pid_t, String, AXUIElement, String) -> Void
    init(app: AppProcess, deliver: @escaping @MainActor (pid_t, String, AXUIElement, String) -> Void) {
        pid = app.pid; applicationIncarnation = app.incarnation; self.deliver = deliver
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, context in
    guard let context else { return }
    let relay = Unmanaged<ObserverRelay>.fromOpaque(context).takeUnretainedValue()
    // Sources are installed only on the main run loop. Deliver synchronously
    // there, without allocating one unstructured task for every notification.
    // A defensive foreign-thread path retains the relay until delivery.
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            relay.deliver(relay.pid, relay.incarnation, element, notification as String)
        }
    } else {
        Task { @MainActor in relay.deliver(relay.pid, relay.incarnation, element, notification as String) }
    }
}

private struct ObserverSubscription {
    let element: AXUIElement
    let notification: String
    func matches(_ other: ObserverSubscription) -> Bool {
        notification == other.notification && CFEqual(element, other.element)
    }
}

private final class ObserverRegistration {
    let observer: AXObserver
    let source: CFRunLoopSource
    let application: AXUIElement
    let relay: ObserverRelay
    // The following are worker-only mutable state.
    var roots: Set<String> = []
    var extras: [ObserverSubscription] = []
    init(observer: AXObserver, application: AXUIElement, relay: ObserverRelay) {
        self.observer = observer; self.application = application; self.relay = relay
        source = AXObserverGetRunLoopSource(observer)
    }
}

private struct ObserverRefresh {
    let registrations: [pid_t: ObserverRegistration]
    // Retain removed contexts until the facade detaches their old sources.
    let retired: [ObserverRegistration]
    let issues: [WorkIssue]
    let treeChanged: Bool
}

/// Only SerialWorker.system accesses the mutable subscription dictionary.
private final class ObserverReader {
    private var registrations: [pid_t: ObserverRegistration] = [:]
    private var cursor = 0

    func clear() { registrations.removeAll() }

    func refresh(apps: [AppProcess], pids: Set<pid_t>?, menus: [pid_t: [AXUIElement]],
                 deliver: @escaping @MainActor (pid_t, String, AXUIElement, String) -> Void) -> ObserverRefresh {
        let live = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
        var retired: [ObserverRegistration] = []
        for pid in Array(registrations.keys) where live[pid]?.incarnation != registrations[pid]?.relay.applicationIncarnation {
            if let old = registrations.removeValue(forKey: pid) { retired.append(old) }
        }
        guard AXIsProcessTrusted() else {
            retired.append(contentsOf: registrations.values); registrations.removeAll()
            return ObserverRefresh(registrations: [:], retired: retired,
                issues: [WorkIssue(recovery: .awaitChange, message: "Accessibility permission required")], treeChanged: false)
        }
        var issues: [WorkIssue] = []; var changed = false
        let budget = AXReadBudget(256)
        let candidates = apps.filter { pids == nil || pids!.contains($0.pid) }.sorted { $0.pid < $1.pid }
        let offset = candidates.isEmpty ? 0 : cursor % candidates.count
        let ordered = Array(candidates.dropFirst(offset)) + Array(candidates.prefix(offset))
        cursor = candidates.isEmpty ? 0 : (offset + 1) % candidates.count
        for app in ordered {
            do {
                guard budget.remaining > 0 else { throw AXReadFailure("Observer refresh budget exhausted") }
                let processBudget = AXReadBudget(96, duration: 0.8, now: budget.now)
                let registration: ObserverRegistration
                if let existing = registrations[app.pid] { registration = existing }
                else {
                    var observer: AXObserver?
                    let code = AXObserverCreate(app.pid, observerCallback, &observer)
                    guard code == .success, let observer else { throw AXReadFailure(code, operation: "Create observer") }
                    registration = ObserverRegistration(observer: observer, application: AXUIElementCreateApplication(app.pid),
                        relay: ObserverRelay(app: app, deliver: deliver))
                    registrations[app.pid] = registration
                }
                for notification in [kAXCreatedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification]
                where !registration.roots.contains(notification) {
                    try add(ObserverSubscription(element: registration.application, notification: notification), to: registration, budget: budget, process: processBudget)
                    registration.roots.insert(notification)
                }
                let read = AXRead(pass: budget, processDuration: processBudget.timeRemaining)
                var desired: [ObserverSubscription] = []
                if let raw = try read.value(registration.application, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                    let bar = raw as! AXUIElement
                    let children = try read.value(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification] {
                        desired.append(ObserverSubscription(element: bar, notification: notification))
                    }
                    for child in children {
                        // No title/value subscriptions: meters and clocks are not layout work.
                        for notification in [kAXMovedNotification, kAXUIElementDestroyedNotification] {
                            desired.append(ObserverSubscription(element: child, notification: notification))
                        }
                    }
                }
                for menu in menus[app.pid] ?? [] {
                    desired.append(ObserverSubscription(element: menu, notification: kAXUIElementDestroyedNotification))
                }
                let removed = registration.extras.filter { old in !desired.contains { $0.matches(old) } }
                let added = desired.filter { new in !registration.extras.contains { $0.matches(new) } }
                for subscription in removed {
                    try consume(budget, process: processBudget)
                    try timeout(subscription.element)
                    let code = AXObserverRemoveNotification(registration.observer, subscription.element, subscription.notification as CFString)
                    if ![AXError.success, .notificationNotRegistered, .notificationUnsupported, .invalidUIElement].contains(code) {
                        throw AXReadFailure(code, operation: "Remove observer notification")
                    }
                    registration.extras.removeAll { $0.matches(subscription) }
                    changed = true
                }
                for subscription in added {
                    try add(subscription, to: registration, budget: budget, process: processBudget)
                    // Remember unsupported notifications too, so every refresh is not a false diff.
                    registration.extras.append(subscription); changed = true
                }
            } catch {
                let issue = (error as? AXReadFailure)?.issue ?? WorkIssue(recovery: .retry, message: error.localizedDescription)
                issues.append(WorkIssue(recovery: issue.recovery, message: "\(app.name): \(issue.message)"))
                // A first IPC failure stops this process, preserving existing subscriptions.
            }
        }
        return ObserverRefresh(registrations: registrations, retired: retired,
            issues: issues.sorted { ($0.message, $0.recovery.rawValue) < ($1.message, $1.recovery.rawValue) }, treeChanged: changed)
    }

    private func consume(_ budget: AXReadBudget, process: AXReadBudget) throws {
        try process.consume(); try budget.consume()
    }
    private func timeout(_ element: AXUIElement) throws {
        let code = AXUIElementSetMessagingTimeout(element, AXRead.messagingTimeout)
        guard code == .success else { throw AXReadFailure(code, operation: "Set observer timeout") }
    }
    private func add(_ subscription: ObserverSubscription, to registration: ObserverRegistration, budget: AXReadBudget, process: AXReadBudget) throws {
        try consume(budget, process: process); try timeout(subscription.element)
        let context = Unmanaged.passUnretained(registration.relay).toOpaque()
        let code = AXObserverAddNotification(registration.observer, subscription.element, subscription.notification as CFString, context)
        guard [.success, .notificationAlreadyRegistered, .notificationUnsupported, .notImplemented].contains(code) else {
            throw AXReadFailure(code, operation: "Add observer notification")
        }
    }
}

@MainActor
final class IconObservers {
    private let reader = ObserverReader()
    private var installed: [pid_t: ObserverRegistration] = [:]
    private var ledger: MenuLedger
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskID: UInt64 = 0
    private var recoveryNeeded = false
    private var recoveryCursor = 0
    private let validateMenus: ([MenuToken]) async throws -> [MenuCheck]
    private let recoverySleep: (TimeInterval) async throws -> Void
    private let terminationCenter: NotificationCenter?
    private var terminationToken: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var dirty = false
    private var allRequested = false
    private var requestedPIDs: Set<pid_t> = []
    var changed: (() -> Void)?
    var menuChanged: ((Bool) -> Void)?
    var diagnosticsChanged: (() -> Void)?
    var menuCount: Int { ledger.tokens.count }
    var menuPIDs: [pid_t] { Set(ledger.tokens.map(\.pid)).sorted() }
    private(set) var menuChecks = 0
    private(set) var lastMenuCheckResult: String?
    private(set) var lastMenuCheckReason: String?
    private(set) var isMenuOpen = false
    private(set) var issues: [WorkIssue] = []
    private(set) var isRefreshing = false

    init(ledger: MenuLedger = MenuLedger(),
         terminationCenter: NotificationCenter? = NSWorkspace.shared.notificationCenter,
         validateMenus: @escaping ([MenuToken]) async throws -> [MenuCheck] = { tokens in
             try await SerialWorker.system.run { MenuPresenceReader.check(tokens) }
         },
         recoverySleep: @escaping (TimeInterval) async throws -> Void = { delay in
             try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
         }) {
        self.ledger = ledger; self.terminationCenter = terminationCenter
        self.validateMenus = validateMenus; self.recoverySleep = recoverySleep
        isMenuOpen = !ledger.tokens.isEmpty
        terminationToken = terminationCenter?.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func setMenuRecoveryNeeded(_ needed: Bool) {
        recoveryNeeded = needed
        updateMenuRecovery()
    }

    private func publishMenuState() {
        let open = !ledger.tokens.isEmpty
        let changed = open != isMenuOpen
        isMenuOpen = open
        updateMenuRecovery()
        if changed { menuChanged?(open) }
        diagnosticsChanged?()
    }

    private func updateMenuRecovery() {
        guard recoveryNeeded && isMenuOpen else { recoveryTask?.cancel(); return }
        // A cancelled in-flight IPC still owns this slot until it actually returns.
        guard recoveryTask == nil else { return }
        recoveryTaskID += 1
        let id = recoveryTaskID
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryTaskID == id {
                    self.recoveryTask = nil
                    self.updateMenuRecovery()
                }
            }
            var backoff = RetryBackoff()
            while self.recoveryNeeded && self.isMenuOpen && !Task.isCancelled {
                do {
                    try await self.recoverySleep(min(2, backoff.nextDelay()))
                    try Task.checkCancellation()
                    let tokens = self.ledger.tokens
                    guard !tokens.isEmpty else { break }
                    let offset = self.recoveryCursor % tokens.count
                    self.recoveryCursor = (offset + 1) % tokens.count
                    let ordered = Array(tokens.dropFirst(offset)) + Array(tokens.prefix(offset))
                    let checks = try await self.validateMenus(ordered)
                    try Task.checkCancellation()
                    guard self.recoveryNeeded else { break }
                    self.menuChecks += 1
                    var closed = 0; var open = 0; var unknown = 0
                    for check in checks {
                        switch check.presence {
                        case .closed: closed += 1
                        case .open: open += 1
                        case .unknown: unknown += 1
                        }
                        self.ledger.apply(check.presence, to: check.token)
                    }
                    self.lastMenuCheckResult = "closed=\(closed) open=\(open) unknown=\(unknown)"
                    self.lastMenuCheckReason = Set(checks.map { $0.presence.reason }).sorted().joined(separator: ",")
                    self.publishMenuState()
                } catch {
                    if Task.isCancelled { break }
                    self.menuChecks += 1
                    self.lastMenuCheckResult = "unknown"
                    self.lastMenuCheckReason = "validation-failure"
                    self.diagnosticsChanged?()
                }
            }
        }
    }

    private func received(pid: pid_t, incarnation: String, element: AXUIElement, notification: String) {
        guard let registration = installed[pid], registration.relay.incarnation == incarnation else { return }
        if notification == kAXMenuOpenedNotification {
            ledger.opened(pid: pid, incarnation: incarnation, element: element)
            publishMenuState(); refresh(pids: [pid]); return
        }
        if notification == kAXMenuClosedNotification {
            ledger.closed(pid: pid, incarnation: incarnation, element: element,
                application: CFEqual(element, registration.application))
            publishMenuState(); refresh(pids: [pid]); return
        }
        if notification == kAXUIElementDestroyedNotification {
            ledger.closed(pid: pid, incarnation: incarnation, element: element); publishMenuState()
        }
        // Root AXCreated may describe an ordinary window. Reinspect the extras
        // tree before claiming a status layout change; worker publishes its diff.
        if notification == kAXCreatedNotification || notification == kAXUIElementDestroyedNotification {
            refresh(pids: [pid]); return
        }
        // Move/layout notifications invalidate state, with no synchronous IPC.
        changed?()
    }

    func refresh(pids: Set<pid_t>? = nil) {
        dirty = true
        if let pids { requestedPIDs.formUnion(pids) } else { allRequested = true }
        guard task == nil else { return }
        isRefreshing = true
        task = Task { [weak self] in
            guard let self else { return }
            var publishChange = false
            while self.dirty && !Task.isCancelled {
                self.dirty = false
                let requested: Set<pid_t>? = self.allRequested ? nil : self.requestedPIDs
                self.allRequested = false; self.requestedPIDs.removeAll()
                let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }.map {
                    AppProcess(pid: $0.processIdentifier, bundle: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "Application",
                        incarnation: AppProcess.incarnation(pid: $0.processIdentifier, launchDate: $0.launchDate) ?? UUID().uuidString)
                }
                let reader = self.reader
                let menus = Dictionary(grouping: self.ledger.tokens, by: \.pid).mapValues { $0.map(\.element) }
                do {
                    let result = try await SerialWorker.system.run {
                        reader.refresh(apps: apps, pids: requested, menus: menus) { [weak self] pid, incarnation, element, notification in
                            self?.received(pid: pid, incarnation: incarnation, element: element, notification: notification)
                        }
                    }
                    // Main owns run-loop attachment. Keep old registrations retained
                    // until sources are removed, before exposing any replacements.
                    for (pid, old) in self.installed where result.registrations[pid] !== old {
                        CFRunLoopRemoveSource(CFRunLoopGetMain(), old.source, .commonModes)
                        self.ledger.unregister(pid: pid, incarnation: old.relay.incarnation)
                    }
                    for (pid, registration) in result.registrations where self.installed[pid] !== registration {
                        self.ledger.register(pid: pid, incarnation: registration.relay.incarnation)
                        CFRunLoopAddSource(CFRunLoopGetMain(), registration.source, .commonModes)
                    }
                    self.installed = result.registrations
                    publishChange = publishChange || result.treeChanged || self.issues != result.issues
                    self.issues = result.issues
                    self.publishMenuState()
                    withExtendedLifetime(result.retired) {}
                } catch {
                    if !Task.isCancelled {
                        let issues = [WorkIssue(recovery: .retry, message: error.localizedDescription)]
                        publishChange = publishChange || self.issues != issues
                        self.issues = issues
                    }
                }
            }
            self.task = nil; self.isRefreshing = false
            if publishChange && !Task.isCancelled { self.changed?() }
        }
    }

    deinit {
        task?.cancel(); recoveryTask?.cancel()
        if let terminationToken { terminationCenter?.removeObserver(terminationToken) }
        for registration in installed.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .commonModes) }
        // No blocking AX teardown on main, and no callback context points to self.
        let reader = reader
        Task { try? await SerialWorker.system.run { reader.clear() } }
    }
}
