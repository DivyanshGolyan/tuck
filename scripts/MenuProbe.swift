// Temporary diagnostic only. No titles, values, labels, or user content are read.
// Include this file in Tuck's diagnostic target and call the function below before normal startup.
import AppKit
import ApplicationServices

private final class MenuProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.tuck.menu-probe.ax", qos: .utility)
    private let output: FileHandle
    private let application: AXUIElement
    private let dropClose: Bool
    private let fixturePID: pid_t
    private let start = ProcessInfo.processInfo.systemUptime
    private var observer: AXObserver?
    private var savedMenu: AXUIElement?
    private var savedParent: AXUIElement?
    private var generation = 0
    private var deadline = 0.0

    init(pid: pid_t, output: FileHandle, dropClose: Bool) {
        application = AXUIElementCreateApplication(pid)
        fixturePID = pid
        self.output = output
        self.dropClose = dropClose
    }

    private func emit(_ body: [String: Any]) {
        var entry = body
        entry["elapsed"] = ProcessInfo.processInfo.systemUptime - start
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
            output.write(data); output.write(Data([10]))
        }
    }

    private func read(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return (.cannotComplete, nil) }
        AXUIElementSetMessagingTimeout(element, 0.12)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func brief(_ value: AXUIElement) -> [String: Any] {
        let (error, role) = read(value, kAXRoleAttribute)
        return ["id": CFHash(value), "roleError": error.rawValue,
                "role": role as? String ?? NSNull()]
    }

    private func describe(_ value: CFTypeRef?) -> Any {
        guard let value else { return NSNull() }
        if let ax = element(value) { return brief(ax) }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = unsafeBitCast(value, to: AXValue.self)
            switch AXValueGetType(ax) {
            case .cgPoint:
                var p = CGPoint.zero
                return AXValueGetValue(ax, .cgPoint, &p) ? ["x": p.x, "y": p.y] : [:]
            case .cgSize:
                var s = CGSize.zero
                return AXValueGetValue(ax, .cgSize, &s) ? ["width": s.width, "height": s.height] : [:]
            default: return ["axValueType": AXValueGetType(ax).rawValue]
            }
        }
        if let values = value as? [AXUIElement] {
            return ["count": values.count, "firstElements": values.prefix(6).map { brief($0) }]
        }
        if let string = value as? String { return string }
        return ["cfType": CFGetTypeID(value)]
    }

    private func attributes(_ target: AXUIElement) -> [String: Any] {
        var result: [String: Any] = ["id": CFHash(target)]
        for name in [kAXRoleAttribute, kAXShownMenuUIElementAttribute, kAXParentAttribute,
                     kAXChildrenAttribute, kAXVisibleChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute] {
            let (error, value) = read(target, name)
            result[name] = ["error": error.rawValue, "value": describe(value)]
        }
        return result
    }

    private func menuBarEvidence() -> [String: Any] {
        var result: [String: Any] = [:]
        var bars: [AXUIElement] = []
        func add(_ candidate: AXUIElement) {
            guard bars.count < 3, !bars.contains(where: { CFEqual($0, candidate) }) else { return }
            let (_, role) = read(candidate, kAXRoleAttribute)
            if role as? String == kAXMenuBarRole { bars.append(candidate) }
        }
        for name in [kAXMenuBarAttribute, kAXExtrasMenuBarAttribute] {
            let (error, value) = read(application, name)
            result[name] = ["error": error.rawValue, "value": describe(value)]
            if let candidate = element(value) { add(candidate) }
        }
        if let children = read(application, kAXChildrenAttribute).1 as? [AXUIElement] {
            for child in children.prefix(3) { add(child) }
        }
        if let savedParent { add(savedParent) }
        result["bars"] = bars.map { bar -> [String: Any] in
            var entry: [String: Any] = ["bar": attributes(bar)]
            let (error, value) = read(bar, kAXChildrenAttribute)
            entry["childrenError"] = error.rawValue
            if let children = value as? [AXUIElement] {
                entry["childrenCount"] = children.count
                entry["childrenTruncated"] = children.count > 3
                entry["children"] = children.prefix(3).map { attributes($0) }
            }
            return entry
        }
        return result
    }

    private func popupWindowEvidence() -> [String: Any] {
        let popupLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ["available": false, "popupLayer": popupLayer]
        }
        // Never copy window owner names or titles. Include fixture-owned windows and
        // other owners' popup-layer windows to expose ownership mismatches explicitly.
        let relevant = windows.filter { info in
            (info[kCGWindowOwnerPID as String] as? Int32) == fixturePID ||
            (info[kCGWindowLayer as String] as? Int) == popupLayer
        }
        let records: [[String: Any]] = relevant.prefix(32).map { info in
            var entry: [String: Any] = [:]
            for key in [kCGWindowOwnerPID, kCGWindowNumber, kCGWindowLayer, kCGWindowBounds,
                        kCGWindowIsOnscreen, kCGWindowAlpha] {
                if let value = info[key as String] { entry[key as String] = value }
            }
            return entry
        }
        return ["available": true, "popupLayer": popupLayer, "fixturePID": fixturePID,
                "count": relevant.count, "truncated": relevant.count > 32, "windows": records]
    }

    private func snapshot(_ reason: String, eventElement: AXUIElement? = nil) {
        deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var body: [String: Any] = ["kind": "snapshot", "reason": reason, "generation": generation]
        if let menu = savedMenu {
            body["retainedMenu"] = attributes(menu)
            if savedParent == nil {
                savedParent = element(read(menu, kAXParentAttribute).1)
            }
            // Read both current and retained parent: a closed menu can lose its parent link.
            if let current = element(read(menu, kAXParentAttribute).1) {
                body["currentParent"] = attributes(current)
                if let grandparent = element(read(current, kAXParentAttribute).1) {
                    body["currentGrandparent"] = attributes(grandparent)
                }
            }
        }
        if let parent = savedParent { body["retainedParent"] = attributes(parent) }
        if let eventElement { body["notificationElement"] = attributes(eventElement) }
        body["application"] = attributes(application)
        body["menuBarCandidates"] = menuBarEvidence()
        body["cgPopupEvidence"] = popupWindowEvidence()
        body["budgetExhausted"] = ProcessInfo.processInfo.systemUptime >= deadline
        emit(body)
    }

    func receive(_ element: AXUIElement, notification: String) {
        let received = ProcessInfo.processInfo.systemUptime - start
        queue.async { [self] in
            deadline = ProcessInfo.processInfo.systemUptime + 0.5
            emit(["kind": "notification", "name": notification, "receivedElapsed": received,
                  "element": brief(element), "droppedForSimulation": dropClose && notification == kAXMenuClosedNotification])
            if notification == kAXMenuOpenedNotification {
                generation += 1
                savedMenu = element
                savedParent = nil
                snapshot("opened", eventElement: element)
                let expectedGeneration = generation
                // Finite diagnostics, not a production poll. These run even if close is dropped.
                for delay in [0.25, 1.0, 2.0, 4.0, 8.0, 12.0] {
                    queue.asyncAfter(deadline: .now() + delay) { [self] in
                        guard generation == expectedGeneration else { return }
                        snapshot("after-open-\(delay)")
                    }
                }
            } else if notification == kAXMenuClosedNotification && !dropClose {
                snapshot("closed", eventElement: element)
                let expectedGeneration = generation
                for delay in [0.15, 0.75, 2.0] {
                    queue.asyncAfter(deadline: .now() + delay) { [self] in
                        guard generation == expectedGeneration else { return }
                        snapshot("after-close-\(delay)")
                    }
                }
            }
        }
    }

    @MainActor func install(seconds: Double) {
        let trusted = AXIsProcessTrusted() // Never requests consent or changes TCC.
        var pid: pid_t = 0
        AXUIElementGetPid(application, &pid)
        emit(["kind": "start", "trusted": trusted, "fixturePID": pid,
              "probePID": getpid(), "seconds": seconds, "dropClose": dropClose])
        guard trusted else {
            emit(["kind": "error", "message": "Launch diagnostic using explicitly trusted identity; no consent request made"])
            return
        }
        var observer: AXObserver?
        let error = AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            Unmanaged<MenuProbe>.fromOpaque(context).takeUnretainedValue().receive(element, notification: notification as String)
        }, &observer)
        emit(["kind": "observerCreate", "error": error.rawValue])
        guard let observer else { return }
        self.observer = observer
        AXUIElementSetMessagingTimeout(application, 0.12)
        for notification in [kAXMenuOpenedNotification, kAXMenuClosedNotification] {
            let status = AXObserverAddNotification(observer, application, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
            emit(["kind": "observe", "notification": notification, "error": status.rawValue])
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        queue.async { self.snapshot("initial") }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            queue.async { [self] in
                snapshot("final")
                emit(["kind": "finished"])
                // All JSONL writes above are synchronous. Terminate only this diagnostic
                // process; NSApp.stop can leave run() asleep waiting for another event.
                try? output.synchronize()
                exit(0)
            }
        }
        NSApplication.shared.run()
    }
}

/// Temporary Main.swift dispatch: if runMenuProbeFromCommandLineIfRequested() { return }
@MainActor
func runMenuProbeFromCommandLineIfRequested() -> Bool {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--menu-probe-pid") else { return false }
    func option(_ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    guard i + 1 < args.count, let pid = Int32(args[i + 1]), pid > 0,
          let path = option("--menu-probe-output") else {
        fputs("Usage: --menu-probe-pid PID --menu-probe-output PATH [--menu-probe-seconds 20] [--menu-probe-drop-close]\n", stderr)
        return true
    }
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let output = FileHandle(forWritingAtPath: path) else { return true }
    let seconds = min(90, max(3, Double(option("--menu-probe-seconds") ?? "20") ?? 20))
    let probe = MenuProbe(pid: pid, output: output, dropClose: args.contains("--menu-probe-drop-close"))
    probe.install(seconds: seconds)
    return true
}

#if MENU_PROBE_STANDALONE
@main struct MenuProbeMain {
    @MainActor static func main() { _ = runMenuProbeFromCommandLineIfRequested() }
}
#endif
