/// A single-owner state machine for one running operation and one coalesced latest
/// intent. This is a value, not synchronization: mutate it on one executor or under
/// the caller's lock. It never starts, cancels, or schedules platform operations.
public struct LatestWork: Equatable, Sendable {
    public private(set) var generation: Int = 0
    public private(set) var running: Int?
    public private(set) var pending: Bool = false
    /// Most recently applied desired generation, not an execution token.
    public private(set) var applied: Int?
    private var nextToken: Int = 0
    private var runningGeneration: Int?

    public init() {}

    /// An external event supersedes previous intent without queuing another job.
    public mutating func request() {
        generation += 1
        pending = true
    }

    /// Reserves the latest intent only when no operation is still running.
    /// Every reservation gets a unique token, including same-generation retries.
    public mutating func begin() -> Int? {
        guard running == nil, pending else { return nil }
        pending = false
        nextToken += 1
        running = nextToken
        runningGeneration = generation
        return nextToken
    }

    /// Complete or cancel a reserved operation. Stale callbacks cannot release a
    /// newer reservation or mark old results applied. A newer pending request is
    /// preserved, as is an explicit abandonPending() decision by the caller.
    public mutating func finish(token: Int, applied didApply: Bool) {
        guard running == token else { return }
        if didApply && isCurrent(token: token) { applied = generation }
        running = nil
        runningGeneration = nil
    }

    /// Wait for a real external change rather than automatically rerunning.
    /// Does not cancel or release a currently running platform operation.
    public mutating func abandonPending() { pending = false }

    /// Reattempt the same intent after a delay without inventing an external event.
    /// A still-running operation must finish before begin() can reserve it again.
    public mutating func deferPending() { pending = true }

    /// An execution is current only while it owns the reservation and its bound
    /// desired generation is still latest. Completed and retried tokens are stale.
    public func isCurrent(token: Int) -> Bool {
        running == token && runningGeneration == generation
    }
}
