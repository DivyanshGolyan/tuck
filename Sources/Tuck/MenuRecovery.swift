import ApplicationServices
import Darwin
import Foundation

// Unknown is deliberately not closure evidence, regardless of elapsed time.
enum MenuPresence: Equatable {
    case open, closed(String), unknown(String)
    var isUnknown: Bool { if case .unknown = self { return true }; return false }
    var reason: String {
        switch self {
        case .open: return "positive-size"
        case .closed(let reason), .unknown(let reason): return reason
        }
    }
}

struct MenuToken {
    let pid: pid_t
    let incarnation: String
    let element: AXUIElement
    let epoch: UInt64
}

struct MenuLedger {
    private(set) var tokens: [MenuToken] = []
    private var registrations: [pid_t: String] = [:]
    private var epoch: UInt64 = 0

    mutating func register(pid: pid_t, incarnation: String) {
        guard registrations[pid] != incarnation else { return }
        tokens.removeAll { $0.pid == pid }
        registrations[pid] = incarnation
    }
    mutating func unregister(pid: pid_t, incarnation: String) {
        guard registrations[pid] == incarnation else { return }
        tokens.removeAll { $0.pid == pid }; registrations.removeValue(forKey: pid)
    }
    @discardableResult
    mutating func opened(pid: pid_t, incarnation: String, element: AXUIElement) -> MenuToken? {
        guard registrations[pid] == incarnation else { return nil }
        // Duplicate opens are new lifetimes too: an in-flight read cannot close them.
        epoch += 1
        let token = MenuToken(pid: pid, incarnation: incarnation, element: element, epoch: epoch)
        tokens.removeAll { $0.pid == pid && CFEqual($0.element, element) }
        tokens.append(token)
        return token
    }
    mutating func closed(pid: pid_t, incarnation: String, element: AXUIElement, application: Bool = false) {
        guard registrations[pid] == incarnation else { return }
        tokens.removeAll { $0.pid == pid && (application || CFEqual($0.element, element)) }
    }
    @discardableResult
    mutating func apply(_ presence: MenuPresence, to token: MenuToken) -> Bool {
        guard case .closed = presence, registrations[token.pid] == token.incarnation,
              let index = tokens.firstIndex(where: {
                  $0.pid == token.pid && $0.incarnation == token.incarnation &&
                  $0.epoch == token.epoch && CFEqual($0.element, token.element)
              }) else { return false }
        tokens.remove(at: index)
        return true
    }
}

struct MenuCheck {
    let token: MenuToken
    let presence: MenuPresence
}

enum MenuPresenceReader {
    // Only ESRCH proves exit. Alive/reused PIDs, permission failures and other
    // errors must still take the conservative AX path.
    static func processHasExited(result: Int32, error: Int32) -> Bool {
        result == -1 && error == ESRCH
    }

    private static func processHasExited(_ pid: pid_t) -> Bool {
        let result = Darwin.kill(pid, 0)
        let error = errno
        return processHasExited(result: result, error: error)
    }

    // Called only on SerialWorker.system; one bounded pass, not an inventory scan.
    static func check(_ tokens: [MenuToken], processExited: (pid_t) -> Bool = { processHasExited($0) }, makeRead: (AXReadBudget) -> AXRead = { AXRead(pass: $0) }) -> [MenuCheck] {
        let budget = AXReadBudget(64, duration: 1.2)
        var readers: [pid_t: AXRead] = [:]
        var exitedPIDs: [pid_t: Bool] = [:]
        var failedPIDs: Set<pid_t> = []
        return tokens.map { token in
            let exited: Bool
            if let cached = exitedPIDs[token.pid] { exited = cached }
            else {
                exited = processExited(token.pid)
                exitedPIDs[token.pid] = exited
            }
            // This evidence is independent of AX (dead refs may keep timing out).
            // Adoption still checks this exact token's epoch and incarnation.
            if exited { return MenuCheck(token: token, presence: .closed("process-exited")) }
            guard !failedPIDs.contains(token.pid) else {
                return MenuCheck(token: token, presence: .unknown("earlier-read-failure"))
            }
            let read: AXRead
            if let existing = readers[token.pid] { read = existing }
            else {
                read = makeRead(budget)
                readers[token.pid] = read
            }
            let result = presence(of: token.element, read: read)
            // AXRead remembers its first failure. Never reuse invalid-element
            // evidence from that failed ref to retire another menu in the process.
            if result.isUnknown || result == .closed("invalid-element") { failedPIDs.insert(token.pid) }
            return MenuCheck(token: token, presence: result)
        }
    }

    static func presence(of element: AXUIElement, read: AXRead) -> MenuPresence {
        do {
            guard let role = try read.requiredValue(element, kAXRoleAttribute) as? String,
                  role == kAXMenuRole else { return .unknown("not-menu") }
            guard let raw = try read.requiredValue(element, kAXSizeAttribute) else { return .unknown("missing-size") }
            guard CFGetTypeID(raw) == AXValueGetTypeID(), AXValueGetType(raw as! AXValue) == .cgSize else {
                return .unknown("malformed-size")
            }
            var size = CGSize.zero
            guard AXValueGetValue(raw as! AXValue, .cgSize, &size),
                  size.width.isFinite, size.height.isFinite, size.width >= 0, size.height >= 0 else {
                return .unknown("invalid-size")
            }
            // Native retained AXMenu refs report successful exact 0x0 after closing.
            // Empty children and AXShownMenuUIElement do not distinguish open menus.
            if size.width == 0 && size.height == 0 { return .closed("zero-size") }
            if size.width > 0 && size.height > 0 { return .open }
            return .unknown("degenerate-size")
        } catch let failure as AXReadFailure {
            if failure.code == .invalidUIElement { return .closed("invalid-element") }
            return .unknown(failure.code.map { "ax-\($0.rawValue)" } ?? "read-budget")
        } catch {
            return .unknown("read-failure")
        }
    }
}
