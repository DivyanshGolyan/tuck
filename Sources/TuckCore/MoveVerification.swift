/// Observation policy after an action may have reached the operating system.
/// None of these decisions authorizes replaying the action automatically.
public enum VerificationDecision: Equatable, Sendable {
    case verified
    case wait
    case awaitChange
}

/// A bounded observation fact, not desired state or an action scheduler. The
/// caller clears it when desired configuration changes or verification succeeds.
public struct MoveVerification: Equatable, Sendable {
    public let itemID: String
    public let before: [String]
    public private(set) var unchangedReads: Int = 0

    public init(itemID: String, before: [String]) {
        self.itemID = itemID
        self.before = before
    }

    /// A changed order proves an effect occurred, not that the entire layout is
    /// correct. The caller still replans from the latest observation. Three
    /// unchanged observations stop automatic retries until an external change.
    public mutating func observe(order: [String], goalSatisfied: Bool) -> VerificationDecision {
        if goalSatisfied || order != before { return .verified }
        unchangedReads = min(unchangedReads + 1, 3)
        return unchangedReads < 3 ? .wait : .awaitChange
    }
}

/// Bounds fresh attempts at an order that will not converge. A resolved
/// "no effect" outcome permits a new attempt; this stops them for one exact
/// observed order so that a cosmetic reorder cannot hold visibility hostage.
/// Any different observed order is new evidence and starts a new count.
public struct MoveAttempts: Equatable, Sendable {
    public static let limit = 2
    private var order: [String] = []
    private var failures = 0
    private var reason: String?

    public init() {}

    /// `final` records a move that cannot be attempted at all in this order.
    public mutating func fail(order: [String], reason: String, final: Bool = false) {
        if self.order != order { self.order = order; failures = 0 }
        failures = final ? Self.limit : min(failures + 1, Self.limit)
        self.reason = reason
    }

    /// The recorded reason once this exact order has been given up on.
    public func abandoned(order: [String]) -> String? {
        failures >= Self.limit && self.order == order ? reason : nil
    }

    public mutating func reset() { self = MoveAttempts() }
}
