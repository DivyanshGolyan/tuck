import Foundation
import Darwin
import XCTest
@testable import TuckCore

final class ConfigVisibilityTests: XCTestCase {
    func testLegacyVisibilityDefaultsFalseAndWrongTypesThrow() throws {
        let legacy = Data(#"{"version":1,"visible":[],"hidden":[],"items":{}}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(TuckConfig.self, from: legacy).showHidden)
        for value in ["true", "false"] {
            let bytes = Data("{\"version\":1,\"visible\":[],\"hidden\":[],\"items\":{},\"showHidden\":\(value)}".utf8)
            let config = try JSONDecoder().decode(TuckConfig.self, from: bytes)
            XCTAssertEqual(config.showHidden, value == "true")
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: JSONEncoder().encode(config)), config)
        }
        for value in ["null", "0", "1", "\"true\"", "[]", "{}"] {
            let bytes = Data("{\"version\":1,\"visible\":[],\"hidden\":[],\"items\":{},\"showHidden\":\(value)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(TuckConfig.self, from: bytes))
        }
    }

    func testRegistrationPreservesVisibilityInModelAndStore() throws {
        for showHidden in [false, true] {
            var config = TuckConfig(showHidden: showHidden)
            try config.register(["a": ItemMetadata(bundleID: "app.a", label: "A")])
            XCTAssertEqual(config.showHidden, showHidden)
            try withStore { store, url in
                try JSONEncoder().encode(config).write(to: url)
                let snapshot = try store.registerSnapshot(["b": ItemMetadata(bundleID: "app.b", label: "B")])
                XCTAssertEqual(snapshot.config.showHidden, showHidden)
                XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: snapshot.bytes), snapshot.config)
            }
        }
    }

    func testSequentialTogglesAndEditorRevisionArePreserved() throws {
        try withStore { store, url in
            let initial = try store.loadSnapshot()
            XCTAssertFalse(initial.config.showHidden)
            let shown = try store.toggleShowHiddenSnapshot()
            XCTAssertTrue(shown.config.showHidden)
            XCTAssertEqual(shown.bytes, try Data(contentsOf: url))
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: shown.bytes), shown.config)
            let hidden = try store.toggleShowHiddenSnapshot()
            XCTAssertFalse(hidden.config.showHidden)
            XCTAssertEqual(hidden.bytes, try Data(contentsOf: url))
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: hidden.bytes), hidden.config)
            let edited = TuckConfig(visible: ["v2", "v1"], hidden: ["h"], items: [
                "v1": ItemMetadata(bundleID: "app.v1", label: "User V1", movable: true),
                "v2": ItemMetadata(bundleID: "app.v2", label: "User V2"),
                "h": ItemMetadata(bundleID: "app.h", label: "User H", item: "stable", movable: false)
            ], showHidden: true)
            try JSONEncoder().encode(edited).write(to: url)
            let toggled = try store.toggleShowHiddenSnapshot()
            var expected = edited
            expected.showHidden = false
            XCTAssertEqual(toggled.config, expected)
            XCTAssertEqual(toggled.bytes, try Data(contentsOf: url))
            XCTAssertEqual(try JSONDecoder().decode(TuckConfig.self, from: toggled.bytes), expected)
        }
        try withStore { store, url in
            // Missing file uses the default baseline, then persists the toggle.
            let snapshot = try store.toggleShowHiddenSnapshot()
            XCTAssertTrue(snapshot.config.showHidden)
            XCTAssertEqual(snapshot.bytes, try Data(contentsOf: url))
        }
    }

    func testToggleRejectsInvalidLockContentionAndSymlinkWithoutMutation() throws {
        try withStore { store, url in
            let valid = try store.loadSnapshot().bytes
            for invalid in [Data("invalid json".utf8), try JSONEncoder().encode(TuckConfig(version: 2)), Data(#"{"version":1,"visible":[],"hidden":[],"items":{},"showHidden":"false"}"#.utf8)] {
                try invalid.write(to: url)
                XCTAssertThrowsError(try store.toggleShowHiddenSnapshot())
                XCTAssertEqual(try Data(contentsOf: url), invalid)
            }
            try valid.write(to: url)
            let fd = open(url.path + ".lock", O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            defer { _ = close(fd) }
            XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try store.toggleShowHiddenSnapshot()) { error in
                guard case ConfigStoreError.busy = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: url), valid)
            XCTAssertEqual(flock(fd, LOCK_UN), 0)
            let target = url.deletingLastPathComponent().appendingPathComponent("target.json")
            try FileManager.default.moveItem(at: url, to: target)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
            XCTAssertThrowsError(try store.toggleShowHiddenSnapshot()) { error in
                guard case ConfigStoreError.symbolicLink = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: target), valid)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
        }
    }

    private func withStore(_ body: (ConfigStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try body(ConfigStore(url: url), url)
    }
}
