import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ConfigStoreError: Error, CustomStringConvertible {
    case symbolicLink
    case busy
    case tooLarge
    case concurrentModification
    case io(String, Int32)

    public var description: String {
        switch self {
        case .symbolicLink: return "Automatic registration cannot replace a symbolic-link configuration; use a regular writable file for discovery writes."
        case .busy: return "Configuration is locked by another process; retry when it finishes."
        case .tooLarge: return "Configuration exceeds the 1 MiB size limit."
        case .concurrentModification: return "Configuration changed during registration; retry after the editor saves."
        case .io(let operation, let code): return "Configuration \(operation) failed (errno \(code))."
        }
    }
}

/// Configuration paired with the exact bytes parsed or written by a store operation.
/// An external editor may change the on-disk file after this snapshot is captured.
public struct ConfigSnapshot: Equatable, Sendable {
    public let config: TuckConfig
    let bytes: Data

    init(config: TuckConfig, bytes: Data) {
        self.config = config
        self.bytes = bytes
    }
}

/// Uses a persistent sidecar lock because locking the replaced file's inode would
/// not serialize subsequent readers. All cooperating readers/writers must use this
/// store. External editors do not honor that lock: byte comparison detects most
/// races, but there remains an unavoidable check-to-rename window.
public final class ConfigStore {
    public static let maximumBytes = 1_048_576
    let url: URL

    public init(url: URL) { self.url = url }

    /// Creates a default configuration only when no file exists.
    func load() throws -> TuckConfig {
        try loadSnapshot().config
    }

    /// Returns the exact bytes decoded, or the exact bytes written on creation.
    public func loadSnapshot() throws -> ConfigSnapshot {
        try updateSnapshot { _ in }
    }

    /// Re-reads under the lock and merges only unknown IDs. Invalid existing files
    /// are never replaced. Known-only discoveries cause no write whatsoever.
    @discardableResult
    func register(_ discovered: [String: ItemMetadata], orderedIDs: [String]? = nil, preserveObservedPositions: Bool = false) throws -> TuckConfig {
        try registerSnapshot(discovered, orderedIDs: orderedIDs, preserveObservedPositions: preserveObservedPositions).config
    }

    /// Pairs the merged configuration with its exact serialized bytes, without a
    /// later independent read that could fingerprint a different editor revision.
    @discardableResult
    public func registerSnapshot(_ discovered: [String: ItemMetadata], orderedIDs: [String]? = nil, preserveObservedPositions: Bool = false) throws -> ConfigSnapshot {
        try updateSnapshot { config in
            try config.register(discovered, orderedIDs: orderedIDs, preserveObservedPositions: preserveObservedPositions)
        }
    }

    /// Toggles visibility in the latest on-disk revision, never a stale UI copy.
    /// Consumers should adopt visibility through their normal configuration watch.
    @discardableResult
    public func toggleShowHiddenSnapshot() throws -> ConfigSnapshot {
        try updateSnapshot { config in config.showHidden.toggle() }
    }

    private func updateSnapshot(_ update: (inout TuckConfig) throws -> Void) throws -> ConfigSnapshot {
        try withLock {
            let original = try readBytes()
            let previous = try original.map(decode) ?? TuckConfig()
            var config = previous
            try update(&config)
            try config.validate()
            let bytes: Data
            if config != previous || original == nil {
                bytes = try write(config, replacing: original)
            } else {
                bytes = original!
            }
            return ConfigSnapshot(config: config, bytes: bytes)
        }
    }

    private func decode(_ bytes: Data) throws -> TuckConfig {
        let config = try JSONDecoder().decode(TuckConfig.self, from: bytes)
        try config.validate()
        return config
    }

    private func readBytes() throws -> Data? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) { return nil }
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return nil }
            throw error
        }
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumBytes {
            guard let chunk = try handle.read(upToCount: Self.maximumBytes + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumBytes else { throw ConfigStoreError.tooLarge }
        return data
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw ConfigStoreError.io("open lock", errno) }
        defer { _ = close(fd) }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw ConfigStoreError.busy }
            if errno != EINTR { throw ConfigStoreError.io("lock", errno) }
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func write(_ config: TuckConfig, replacing original: Data?) throws -> Data {
        // Reads may follow dotfile symlinks, but rename would replace the link
        // itself rather than update its target. Never do that automatically.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw ConfigStoreError.symbolicLink
        }
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(config)
        bytes.append(0x0A)
        guard bytes.count <= Self.maximumBytes else { throw ConfigStoreError.tooLarge }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard fd >= 0 else { throw ConfigStoreError.io("create temporary file", errno) }
        defer { _ = close(fd); try? FileManager.default.removeItem(at: temporary) }
        if original != nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                guard fchmod(fd, mode_t(permissions.uint16Value)) == 0 else { throw ConfigStoreError.io("preserve permissions", errno) }
            }
        }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                #else
                let count = Glibc.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ConfigStoreError.io("write", errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ConfigStoreError.io("sync", errno) }
        guard try readBytes() == original else { throw ConfigStoreError.concurrentModification }
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw ConfigStoreError.symbolicLink
        }
        guard rename(temporary.path, url.path) == 0 else { throw ConfigStoreError.io("replace", errno) }
        return bytes
    }
}
