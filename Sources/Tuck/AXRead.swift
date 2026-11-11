import ApplicationServices
import Darwin
import Foundation
import TuckCore

/// Only used on SerialWorker.system. An IPC timeout is not evidence of absence.
struct AXReadFailure: Error, LocalizedError {
    let issue: WorkIssue
    let code: AXError?
    var errorDescription: String? { issue.message }

    init(_ code: AXError, operation: String) {
        self.code = code
        let recovery: Recovery
        switch code {
        case .cannotComplete, .failure, .invalidUIElement: recovery = .retry
        case .apiDisabled, .attributeUnsupported, .actionUnsupported,
             .notificationUnsupported, .notImplemented, .noValue: recovery = .awaitChange
        default: recovery = .awaitChange
        }
        issue = WorkIssue(recovery: recovery, message: "\(operation): AX error \(code.rawValue)")
    }
    init(_ message: String) {
        code = nil
        issue = WorkIssue(recovery: .retry, message: message)
    }
}

/// Cooperative call/deadline budget: it cannot interrupt a synchronous AX IPC.
final class AXReadBudget {
    private(set) var remaining: Int
    let now: () -> TimeInterval
    private let expiresAt: TimeInterval
    init(_ limit: Int = 512, duration: TimeInterval = 2,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        remaining = limit; self.now = now; expiresAt = now() + duration
    }
    var timeRemaining: TimeInterval { max(0, expiresAt - now()) }
    func consume() throws {
        guard remaining > 0, now() < expiresAt else {
            throw AXReadFailure("Accessibility pass budget exhausted; waiting to retry")
        }
        remaining -= 1
    }
}

final class AXRead {
    static let messagingTimeout: Float = 0.35
    private var remaining: Int
    private let pass: AXReadBudget
    private var firstFailure: AXReadFailure?
    private let processDeadline: TimeInterval
    private let setTimeout: (AXUIElement, Float) -> AXError
    private let copyAttribute: (AXUIElement, String) -> (AXError, CFTypeRef?)

    init(limit: Int = 64, pass: AXReadBudget = AXReadBudget(), processDuration: TimeInterval = 0.8,
         setTimeout: @escaping (AXUIElement, Float) -> AXError = { AXUIElementSetMessagingTimeout($0, $1) },
         copyAttribute: @escaping (AXUIElement, String) -> (AXError, CFTypeRef?) = { element, attribute in
             var value: CFTypeRef?
             let code = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
             return (code, value)
         }) {
        remaining = limit; self.pass = pass; self.setTimeout = setTimeout; self.copyAttribute = copyAttribute
        processDeadline = pass.now() + processDuration
    }

    func value(_ element: AXUIElement, _ attribute: String, optional: Bool = true) throws -> CFTypeRef? {
        try readValue(element, attribute, optional: optional, allowNoValue: true)
    }

    // Presence predicates must distinguish an absent value from an unsupported read.
    func requiredValue(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef? {
        try readValue(element, attribute, optional: false, allowNoValue: false)
    }

    private func readValue(_ element: AXUIElement, _ attribute: String, optional: Bool, allowNoValue: Bool) throws -> CFTypeRef? {
        // Even if a caller catches an error and continues, this process reader
        // never sends a second IPC after its first failing read.
        if let firstFailure { throw firstFailure }
        do {
            guard remaining > 0, pass.now() < processDeadline else { throw AXReadFailure("Accessibility process budget exhausted; waiting to retry") }
            try pass.consume(); remaining -= 1
            // Timeouts are object-instance local, not inherited by children/equal refs.
            let timeoutResult = setTimeout(element, Self.messagingTimeout)
            guard timeoutResult == .success else { throw AXReadFailure(timeoutResult, operation: "Set AX timeout") }
            let (code, result) = copyAttribute(element, attribute)
            if code == .success { return result }
            if allowNoValue && code == .noValue { return nil }
            if optional && (code == .attributeUnsupported || code == .notImplemented) { return nil }
            throw AXReadFailure(code, operation: "Read \(attribute)")
        } catch let failure as AXReadFailure {
            firstFailure = failure; throw failure
        }
    }

    func frame(_ element: AXUIElement) throws -> CGRect? {
        guard let p = try value(element, kAXPositionAttribute, optional: false),
              let s = try value(element, kAXSizeAttribute, optional: false),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

/// Captured on main. The incarnation tells one process from a later one that
/// reuses its PID; without one, nothing remembered about the PID is reused.
struct AXApplicationContext: Sendable {
    let pid: pid_t
    let bundle: String
    let name: String
    let incarnation: String

    /// Launch Services gives agents such as Control Centre no launch date. The
    /// kernel's start time identifies the same process instance just as well.
    static func incarnation(pid: pid_t, launchDate: Date?) -> String {
        if let launchDate { return String(launchDate.timeIntervalSince1970) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            return "kernel-\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
        }
        return UUID().uuidString
    }
}
