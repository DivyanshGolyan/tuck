import Foundation
import Dispatch

/// A serial boundary for synchronous OS/file calls. No waits on a cooperative
/// executor. Cancellation skips queued jobs and discards in-flight results, but
/// never pretends that a running OS call has been interrupted.
public final class SerialWorker: @unchecked Sendable {
    public static let system = SerialWorker(label: "local.tuck.system")
    private let queue: DispatchQueue
    public init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    public func run<T>(_ operation: @escaping () throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result: T = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    do { continuation.resume(returning: try operation()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
    }
}
