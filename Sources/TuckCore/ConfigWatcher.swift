import Foundation
import Dispatch
import Darwin

/// Event-driven configuration watcher. Construct on the main thread. File-system
/// setup and event processing run on a private serial utility queue; callbacks run
/// on main and are coalesced. One initial invalidation is delivered after setup,
/// covering changes made while asynchronous attachment was in progress.
/// The containing directory may disappear and be recreated, provided its parent
/// remains present. No polling or recurring timers are used.
public final class ConfigWatcher {
    private let queue: DispatchQueue
    private let state: IOState
    private let relay: CallbackRelay

    public init(url: URL, changed: @escaping () -> Void) {
        precondition(Thread.isMainThread, "ConfigWatcher must be created on the main thread")
        let queue = DispatchQueue(label: "local.tuck.config-watcher", qos: .utility)
        let relay = CallbackRelay(changed: changed)
        let state = IOState(file: url, queue: queue, relay: relay)
        self.queue = queue
        self.state = state
        self.relay = relay
        queue.async { state.start() }
    }

    deinit {
        // Suppress deliveries immediately, including startup already enqueued.
        // Teardown may wait behind an OS call on the worker, never on the UI.
        relay.cancel()
        let state = state
        queue.async { state.stop() }
    }

    /// A short memory-only lock coalesces worker events into one main-queue block
    /// and permits lifetime cancellation without waiting for the I/O queue.
    private final class CallbackRelay {
        private let lock = NSLock()
        private var callback: (() -> Void)?
        private var pending = false

        init(changed: @escaping () -> Void) { callback = changed }

        func invalidate() {
            lock.lock()
            guard callback != nil, !pending else { lock.unlock(); return }
            pending = true
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.deliver() }
        }

        private func deliver() {
            lock.lock()
            pending = false
            let callback = callback
            lock.unlock()
            callback?()
        }

        func cancel() {
            lock.lock()
            let discarded = callback
            callback = nil
            pending = false
            lock.unlock()
            // Release user captures outside the lock (their deinitializers may
            // have arbitrary behavior).
            withExtendedLifetime(discarded) {}
        }
    }

    /// All source ownership and file-system access are confined to queue. The
    /// wrapper retains this state until asynchronous teardown has been enqueued;
    /// sources capture it weakly so cancellation cannot leave a retain cycle.
    private final class IOState {
        private struct Identity: Equatable {
            let device: dev_t
            let inode: ino_t
            init(_ status: stat) { device = status.st_dev; inode = status.st_ino }
        }
        private struct Watch {
            let identity: Identity
            let source: DispatchSourceFileSystemObject
        }
        private let file: URL
        private let directory: URL
        private let parent: URL
        private let queue: DispatchQueue
        private let relay: CallbackRelay
        private var parentWatch: Watch?
        private var directoryWatch: Watch?
        private var fileWatch: Watch?
        private var stopped = false

        init(file: URL, queue: DispatchQueue, relay: CallbackRelay) {
            self.file = file
            directory = file.deletingLastPathComponent()
            parent = directory.deletingLastPathComponent()
            self.queue = queue
            self.relay = relay
        }

        func start() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !stopped else { return }
            // Attach ancestors first to detect replacement during child setup.
            parentWatch = makeWatch(parent, fileEvents: false)
            directoryWatch = makeWatch(directory, fileEvents: false)
            fileWatch = makeWatch(file, fileEvents: true)
            relay.invalidate()
        }

        func stop() {
            dispatchPrecondition(condition: .onQueue(queue))
            stopped = true
            parentWatch?.source.cancel()
            directoryWatch?.source.cancel()
            fileWatch?.source.cancel()
            parentWatch = nil
            directoryWatch = nil
            fileWatch = nil
        }

        private func identity(at url: URL) -> Identity? {
            dispatchPrecondition(condition: .onQueue(queue))
            var status = stat()
            guard fstatat(AT_FDCWD, url.path, &status, 0) == 0 else { return nil }
            return Identity(status)
        }

        private func makeWatch(_ url: URL, fileEvents: Bool) -> Watch? {
            dispatchPrecondition(condition: .onQueue(queue))
            let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var status = stat()
            guard fstat(fd, &status) == 0 else { close(fd); return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                let identitiesChanged = self.refresh()
                // Ignore unrelated sibling writes (runtime.json, lock files).
                // In-place writes arrive on the file's own source.
                if fileEvents || identitiesChanged { self.relay.invalidate() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return Watch(identity: Identity(status), source: source)
        }

        private func refreshWatch(_ watch: inout Watch?, at url: URL, fileEvents: Bool) -> Bool {
            let current = identity(at: url)
            if current == watch?.identity { return false }
            watch?.source.cancel()
            watch = makeWatch(url, fileEvents: fileEvents)
            return true
        }

        private func refresh() -> Bool {
            dispatchPrecondition(condition: .onQueue(queue))
            let directoryChanged = refreshWatch(&directoryWatch, at: directory, fileEvents: false)
            let fileChanged = refreshWatch(&fileWatch, at: file, fileEvents: true)
            return directoryChanged || fileChanged
        }
    }
}
