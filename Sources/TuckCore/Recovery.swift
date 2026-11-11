import Foundation

/// Policy data, not execution: the native boundary decides how to schedule a retry,
/// which event can unblock waiting, and how to release discarded platform work.
public enum Recovery: String, Equatable, Sendable {
    case retry
    case awaitChange
    case discard
}

public struct WorkIssue: Equatable, Sendable {
    public let recovery: Recovery
    public let message: String

    public init(recovery: Recovery, message: String) {
        self.recovery = recovery
        self.message = message
    }
}

/// A deterministic delay sequence. Owns no clock, timer, task, or callback.
public struct RetryBackoff: Equatable, Sendable {
    private static let delays: [TimeInterval] = [0.25, 0.75, 2, 5, 15, 30]
    private var index = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        let delay = Self.delays[index]
        index = min(index + 1, Self.delays.count - 1)
        return delay
    }

    public mutating func reset() { index = 0 }
}
