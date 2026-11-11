import Foundation
import XCTest
import Darwin
@testable import TuckCore

final class TuckCoreTests: XCTestCase {
    let metadata = ItemMetadata(bundleID: "org.example.app", label: "Example", item: "status")

    func unique(_ id: String) -> ItemMetadata { ItemMetadata(bundleID: "org.example." + id, label: id) }

    func testConfigurationRoundTripAndRegistration() throws {
        var config = TuckConfig(visible: ["b"], hidden: ["a"], items: ["a": metadata, "b": unique("b")])
        let original = config
        XCTAssertFalse(try config.register(["a": ItemMetadata(bundleID: "changed", label: "changed")]))
        XCTAssertEqual(config, original)
        XCTAssertTrue(try config.register(["d": unique("d"), "c": unique("c")]))
        XCTAssertEqual(config.visible, ["b", "c", "d"])
        XCTAssertEqual(config.hidden, ["a"])
        XCTAssertEqual(config.items["a"], metadata)
        XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testOptionalMovabilityMetadataRoundTripAndLegacyDecode() throws {
        for movable in [nil, true, false] as [Bool?] {
            let metadata = ItemMetadata(bundleID: "org.example.app", label: "Example", item: "status", movable: movable)
            let config = TuckConfig(visible: ["a"], items: ["a": metadata])
            let bytes = try JSONEncoder().encode(config)
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: bytes), config)
        }
        let legacy = Data(#"{"bundleID":"org.example.app","label":"Example","item":"status"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ItemMetadata.self, from: legacy).movable)
    }

    func testValidation() throws {
        XCTAssertThrowsError(try TuckConfig(version: 2).validate())
        XCTAssertThrowsError(try TuckConfig(visible: ["a", "a"], items: ["a": metadata]).validate())
        XCTAssertThrowsError(try TuckConfig(visible: ["a"], hidden: ["a"], items: ["a": metadata]).validate())
        XCTAssertThrowsError(try TuckConfig(visible: ["a"]).validate())
        XCTAssertThrowsError(try TuckConfig(items: ["a": metadata]).validate())
        var config = TuckConfig()
        XCTAssertThrowsError(try config.register(["": metadata]))
        XCTAssertEqual(config, TuckConfig())
        try config.validate()
    }

    func testSelectorsMetadataReservedIDsAndTransactionalRegistration() throws {
        for id in ["__tuck_separator__", "__tuck_control__"] {
            XCTAssertThrowsError(try TuckConfig(visible: [id], items: [id: metadata]).validate())
        }
        for invalid in [ItemMetadata(bundleID: "", label: "label"), ItemMetadata(bundleID: "bundle", label: ""), ItemMetadata(bundleID: " ", label: "label")] {
            XCTAssertThrowsError(try TuckConfig(visible: ["a"], items: ["a": invalid]).validate())
        }
        XCTAssertThrowsError(try TuckConfig(visible: ["a", "b"], items: ["a": metadata, "b": metadata]).validate())
        var config = TuckConfig(visible: ["a"], items: ["a": metadata])
        let original = config
        XCTAssertThrowsError(try config.register(["b": metadata, "c": unique("c")]))
        XCTAssertEqual(config, original)
        let sameBundleDistinctItems = TuckConfig(visible: ["a", "b", "c"], items: [
            "a": ItemMetadata(bundleID: "bundle", label: "A"),
            "b": ItemMetadata(bundleID: "bundle", label: "B", item: "one"),
            "c": ItemMetadata(bundleID: "bundle", label: "C", item: "two")])
        try sameBundleDistinctItems.validate()
    }

    func testOrderedRegistration() throws {
        var config = TuckConfig(visible: ["old"], items: ["old": unique("old")])
        let discovered = ["a": unique("a"), "b": unique("b"), "c": unique("c"), "d": unique("d")]
        XCTAssertTrue(try config.register(discovered, orderedIDs: ["c", "unknown", "a", "c", "old"]))
        XCTAssertEqual(config.visible, ["old", "c", "a", "b", "d"])
        try withStore { store, _ in
            let result = try store.register(discovered, orderedIDs: ["d", "b", "a", "c"])
            XCTAssertEqual(result.visible, ["d", "b", "a", "c"])
        }
    }

    func testPreservesObservedPositionsAcrossPartialDiscovery() throws {
        var config = TuckConfig()
        try config.register(["c": unique("c"), "e": unique("e")], orderedIDs: ["c", "e"], preserveObservedPositions: true)
        let originalMetadata = config.items
        let discovered = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d", "e", "f", "z", "y"].map { ($0, unique($0)) })
        try config.register(discovered, orderedIDs: ["a", "b", "c", "d", "e", "f"], preserveObservedPositions: true)
        XCTAssertEqual(config.visible, ["a", "b", "c", "d", "e", "f", "y", "z"])
        XCTAssertEqual(config.items["c"], originalMetadata["c"])
        XCTAssertEqual(config.items["e"], originalMetadata["e"])
        try withStore { store, _ in
            _ = try store.register(["c": unique("c"), "e": unique("e")], orderedIDs: ["c", "e"], preserveObservedPositions: true)
            let result = try store.register(discovered, orderedIDs: ["a", "b", "c", "d", "e", "f"], preserveObservedPositions: true)
            XCTAssertEqual(result, config)
        }
    }

    func testObservedDiscoveryNeverReordersUserPlacementOrAnchorsToHidden() throws {
        let original = TuckConfig(visible: ["c", "a"], hidden: ["h"], items: ["a": unique("a"), "c": unique("c"), "h": unique("h")])
        var config = original
        let discovery = ["a": ItemMetadata(bundleID: "ignored", label: "ignored"), "b": unique("b"), "d": unique("d"), "f": unique("f")]
        try config.register(discovery, orderedIDs: ["f", "h", "a", "b", "c", "d", "b"], preserveObservedPositions: true)
        XCTAssertEqual(config.visible, ["b", "c", "f", "a", "d"])
        XCTAssertEqual(config.visible.filter { original.visible.contains($0) }, original.visible)
        XCTAssertEqual(config.hidden, original.hidden)
        XCTAssertEqual(config.items["a"], original.items["a"])
        XCTAssertEqual(config.items["h"], original.items["h"])
        var defaultConfig = original
        try defaultConfig.register(discovery, orderedIDs: ["f", "h", "a", "b", "c", "d"])
        XCTAssertEqual(defaultConfig.visible, ["c", "a", "f", "b", "d"])
        var noObservedOrder = original
        try noObservedOrder.register(discovery, preserveObservedPositions: true)
        XCTAssertEqual(noObservedOrder.visible, ["c", "a", "b", "d", "f"])
    }

    func testLockContentionFailsPromptly() throws {
        try withStore { store, url in
            _ = try store.load()
            let fd = open(url.path + ".lock", O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { _ = flock(fd, LOCK_UN); _ = close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            let start = Date()
            XCTAssertThrowsError(try store.load()) { error in
                guard case ConfigStoreError.busy = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertThrowsError(try store.register(["a": metadata]))
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func testPlannerExhaustivelyMinimal() throws {
        let target = ["a", "b", "separator", "c", "d", "e"]
        func permutations(_ values: [String]) -> [[String]] {
            if values.isEmpty { return [[]] }
            return values.enumerated().flatMap { index, element in
                var rest = values
                rest.remove(at: index)
                return permutations(rest).map { [element] + $0 }
            }
        }
        for observed in permutations(target) {
            let moves = try LayoutPlanner.plan(hidden: ["a", "b"], visible: ["c", "d", "e"], observed: observed, separatorID: "separator")
            var actual = observed
            for move in moves {
                actual.remove(at: actual.firstIndex(of: move.id)!)
                let insertion = move.before.map { actual.firstIndex(of: $0)! } ?? actual.count
                actual.insert(move.id, at: insertion)
            }
            XCTAssertEqual(actual, target, "\(observed)")
            // Independent quadratic LIS oracle.
            let ranks = observed.map { target.firstIndex(of: $0)! }
            var lengths = Array(repeating: 1, count: ranks.count)
            for i in ranks.indices {
                for j in 0..<i where ranks[j] < ranks[i] { lengths[i] = max(lengths[i], lengths[j] + 1) }
            }
            XCTAssertEqual(moves.count, target.count - lengths.max()!)
            XCTAssertEqual(moves, try LayoutPlanner.plan(hidden: ["a", "b"], visible: ["c", "d", "e"], observed: observed, separatorID: "separator"))
        }
    }

    func testPlannerOfflineUnknownAndInvalidIDs() throws {
        let moves = try LayoutPlanner.plan(hidden: ["a", "offline"], visible: ["b"], observed: ["unknown", "b", "s", "a"], separatorID: "s")
        XCTAssertTrue(moves.allSatisfy { $0.id != "unknown" && $0.id != "offline" && $0.before != "unknown" })
        XCTAssertThrowsError(try LayoutPlanner.plan(hidden: ["a"], visible: ["a"], observed: ["s"], separatorID: "s"))
        XCTAssertThrowsError(try LayoutPlanner.plan(hidden: [], visible: [], observed: ["s", "s"], separatorID: "s"))
        XCTAssertThrowsError(try LayoutPlanner.plan(hidden: ["s"], visible: [], observed: ["s"], separatorID: "s"))
        XCTAssertThrowsError(try LayoutPlanner.plan(hidden: [], visible: [], observed: [], separatorID: "s"))
    }

    func withStore(_ body: (ConfigStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try body(ConfigStore(url: url), url)
    }

    func testStoreCreationNoOpMergePermissionsAndEditorChanges() throws {
        try withStore { store, url in
            XCTAssertEqual(try store.load(), TuckConfig())
            _ = try store.register(["a": metadata])
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
            let before = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            _ = try store.register(["a": ItemMetadata(bundleID: "ignored", label: "ignored")])
            XCTAssertEqual(try Data(contentsOf: url), before)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
            var edited = try store.load()
            edited.visible = []
            edited.hidden = ["a"]
            edited.items["a"]?.label = "User label"
            try JSONEncoder().encode(edited).write(to: url)
            let merged = try ConfigStore(url: url).register(["b": unique("b")])
            XCTAssertEqual(merged.hidden, ["a"])
            XCTAssertEqual(merged.visible, ["b"])
            XCTAssertEqual(merged.items["a"]?.label, "User label")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o640)
        }
    }

    func testSnapshotsUseExactReadOrWrittenBytes() throws {
        try withStore { store, url in
            let created = try store.loadSnapshot()
            XCTAssertEqual(created.config, TuckConfig())
            XCTAssertEqual(created.bytes, try Data(contentsOf: url))
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: created.bytes), created.config)
            let written = try store.registerSnapshot(["a": unique("a"), "b": unique("b")], orderedIDs: ["b", "a"], preserveObservedPositions: true)
            XCTAssertEqual(written.config.visible, ["b", "a"])
            XCTAssertEqual(written.bytes, try Data(contentsOf: url))
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: written.bytes), written.config)
            let formatted = Data(#" { "items": { "a": { "label":"A", "bundleID":"org.example.a" } }, "hidden":[], "version":1, "visible":["a"] } "#.utf8)
            try formatted.write(to: url)
            let loaded = try store.loadSnapshot()
            XCTAssertEqual(loaded.bytes, formatted)
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: loaded.bytes), loaded.config)
            let unchanged = try store.registerSnapshot(["a": ItemMetadata(bundleID: "ignored", label: "ignored")])
            XCTAssertEqual(unchanged, loaded)
            XCTAssertEqual(try Data(contentsOf: url), formatted)
            // Snapshots remain self-consistent after a later editor revision.
            try created.bytes.write(to: url)
            XCTAssertEqual(loaded.bytes, formatted)
            XCTAssertEqual(loaded.config.visible, ["a"])
            XCTAssertEqual(try store.load(), created.config)
        }
        try withStore { store, url in
            let created = try store.registerSnapshot([:])
            XCTAssertEqual(created.config, TuckConfig())
            XCTAssertEqual(created.bytes, try Data(contentsOf: url))
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: created.bytes), created.config)
        }
    }

    func testSymlinkReadsAndNoOpAllowedButDiscoveryWriteRefused() throws {
        try withStore { store, url in
            let target = url.deletingLastPathComponent().appendingPathComponent("dotfile-target.json")
            let config = TuckConfig(visible: ["a"], items: ["a": unique("a")])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = try JSONEncoder().encode(config)
            try original.write(to: target)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
            XCTAssertEqual(try store.load(), config)
            XCTAssertEqual(try store.registerSnapshot(["a": unique("a")]).bytes, original)
            let contentsBefore = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
            XCTAssertThrowsError(try store.register(["b": unique("b")])) { error in
                guard case ConfigStoreError.symbolicLink = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted(), contentsBefore)
            // A dangling symlink must not be replaced by default creation either.
            try FileManager.default.removeItem(at: target)
            XCTAssertThrowsError(try store.load()) { error in
                guard case ConfigStoreError.symbolicLink = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testStoreRejectsInvalidAndOversizedWithoutOverwrite() throws {
        try withStore { store, url in
            _ = try store.load()
            for data in [Data("not json".utf8), try JSONEncoder().encode(TuckConfig(version: 7)), try JSONEncoder().encode(TuckConfig(visible: ["missing"])), Data(repeating: 32, count: ConfigStore.maximumBytes + 1)] {
                try data.write(to: url)
                XCTAssertThrowsError(try store.load())
                XCTAssertThrowsError(try store.register(["a": metadata]))
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    func testConcurrentRegistrationMerges() throws {
        try withStore { store, url in
            _ = try store.load()
            let errors = ErrorCollector()
            DispatchQueue.concurrentPerform(iterations: 30) { index in
                do {
                    var succeeded = false
                    for _ in 0..<500 {
                        do {
                            _ = try ConfigStore(url: url).register(["item-\(index)": unique("item-\(index) ")])
                            succeeded = true
                            break
                        } catch ConfigStoreError.busy { Thread.sleep(forTimeInterval: 0.002) }
                    }
                    if !succeeded { errors.append(ConfigStoreError.busy) }
                } catch { errors.append(error) }
            }
            XCTAssertTrue(errors.values.isEmpty)
            let result = try store.load()
            XCTAssertEqual(result.items.count, 30)
            XCTAssertEqual(result.visible.count, 30)
            try result.validate()
        }
    }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; storage.append(error) }
    var values: [Error] { lock.lock(); defer { lock.unlock() }; return storage }
}
