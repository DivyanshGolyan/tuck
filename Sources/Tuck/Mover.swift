import AppKit
import ApplicationServices
import TuckCore

struct MovementFailure: LocalizedError {
    let message: String
    var recovery: Recovery = .awaitChange
    var errorDescription: String? { message }
}

// The platform mechanism is kept here: mouse events, delays and cleanup. Which points
// to drag between is decided by `assess`.
@MainActor
final class Mover {
    static let eventTag: Int64 = 0x5455434B

    // Query only when responding to work, never on an idle timer. This optional
    // WindowServer session field is a defensive compatibility check, not permission.
    static var sessionIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    var userIsBusy: Bool {
        if Self.sessionIsLocked { return true }
        if CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) { return true }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    /// Posts one Command-drag between points the verdict already resolved as hittable.
    func move(_ drag: Drag, label: String, tap: CGEventTapLocation = .cghidEventTap, isCurrent: () -> Bool = { true }, didBegin: () -> Void = {}) async throws {
        guard AXIsProcessTrusted() else { throw MovementFailure(message: "Cannot move \(label)") }
        guard !userIsBusy else { throw MovementFailure(message: "User input in progress; layout deferred", recovery: .retry) }
        guard let source = CGEventSource(stateID: .hidSystemState), let original = CGEvent(source: nil)?.location else {
            throw MovementFailure(message: "Cannot create mouse event source")
        }
        let (start, end) = (drag.from, drag.to)
        var released = false
        var pressed = false
        var lastPosition = original
        var lastStep = DispatchTime.now().uptimeNanoseconds
        func checkProgress() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            // A late continuation is not permission to continue stale coordinates.
            guard DispatchTime.now().uptimeNanoseconds - lastStep < 500_000_000 else {
                throw MovementFailure(message: "Gesture scheduling delayed; waiting to verify", recovery: .retry)
            }
            lastStep = DispatchTime.now().uptimeNanoseconds
        }
        func post(_ type: CGEventType, at point: CGPoint) throws {
            // Cleanup may release an existing synthetic press after locking, but
            // never begin or advance a drag into the login/lock screen.
            if type != .leftMouseUp && Self.sessionIsLocked {
                throw CancellationError()
            }
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw MovementFailure(message: "Cannot allocate movement event")
            }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: tap)
            lastPosition = point
        }
        defer {
            // Always release a synthetic drag, including cancellation/error paths.
            if pressed && !released { try? post(.leftMouseUp, at: lastPosition) }
            // Synthetic Command flags survive in the session after mouse-up unless
            // explicitly released. Leaving them set would defer all future work.
            if pressed, let release = CGEvent(source: source) {
                release.type = .flagsChanged; release.flags = []
                release.setIntegerValueField(.keyboardEventKeycode, value: 55)
                release.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
                release.post(tap: tap)
            }
            // Do not warp over a user who moved the pointer during the operation.
            if !Self.sessionIsLocked, let current = CGEvent(source: nil)?.location,
               hypot(current.x - lastPosition.x, current.y - lastPosition.y) < 5 {
                CGWarpMouseCursorPosition(original)
            }
        }
        // Establish the hit-test location before the button event. Event posting
        // is asynchronous; a single down at a previously untouched row can miss.
        if let position = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: start, mouseButton: .left) {
            position.flags = []
            position.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            position.post(tap: tap)
            lastPosition = start
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        try Task.checkCancellation()
        try checkProgress()
        try post(.leftMouseDown, at: start); pressed = true; didBegin()
        try await Task.sleep(nanoseconds: 100_000_000)
        try Task.checkCancellation()
        if let current = CGEvent(source: nil)?.location, hypot(current.x - lastPosition.x, current.y - lastPosition.y) > 8 {
            throw MovementFailure(message: "Pointer moved; layout deferred", recovery: .retry)
        }
        for step in 1...12 {
            try checkProgress()
            let fraction = CGFloat(step) / 12
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y)
            try post(.leftMouseDragged, at: point)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try Task.checkCancellation()
        if let current = CGEvent(source: nil)?.location, hypot(current.x - lastPosition.x, current.y - lastPosition.y) > 8 {
            throw MovementFailure(message: "Pointer moved; layout deferred", recovery: .retry)
        }
        try checkProgress()
        try post(.leftMouseUp, at: end); released = true
        // Allow WindowServer's rearrangement animation and AX frames to settle
        // before the caller verifies actual order; posting is not acknowledgement.
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}
