import Foundation
import XCTest
@testable import TuckCore

final class ConfigWatcherTests: XCTestCase {
    private func withWatcher(_ body: (WatcherFixture) throws -> Void) throws {
        XCTAssertTrue(Thread.isMainThread)
        let fixture = try WatcherFixture()
        defer { fixture.cleanup() }
        try body(fixture)
    }

    func testInitialInvalidationIsAsynchronousOnMainWithoutFileChanges() throws {
        try withWatcher { fixture in
            // No write is necessary: asynchronous startup must invalidate once.
            try fixture.expectChange(to: "initial") {}
            try fixture.expectNoChange {}
        }
    }

    func testImmediateReleaseSuppressesQueuedStartupAndLaterEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("initial".utf8).write(to: file)
        let unexpected = expectation(description: "No callback after immediate release")
        unexpected.isInverted = true
        var initializerReturned = false
        var watcher: ConfigWatcher? = ConfigWatcher(url: file) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(initializerReturned, "Initialization must never call back synchronously")
            unexpected.fulfill()
        }
        initializerReturned = true
        XCTAssertNotNil(watcher)
        watcher = nil
        try Data("after release".utf8).write(to: file, options: .atomic)
        wait(for: [unexpected], timeout: 0.15)
    }

    func testReleaseAfterStartupSuppressesFutureEvents() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: "initial") {}
            fixture.releaseWatcher()
            try fixture.expectNoChange {
                try Data("after release".utf8).write(to: fixture.file, options: .atomic)
                try FileManager.default.removeItem(at: fixture.directory)
                try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
                try Data("recreated after release".utf8).write(to: fixture.file)
            }
        }
    }

    func testUnrelatedSiblingWritesDoNotInvalidateConfiguration() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: "initial") {}
            try fixture.expectNoChange {
                let runtime = fixture.directory.appendingPathComponent("runtime.json")
                let parentSibling = fixture.parent.appendingPathComponent("unrelated.txt")
                try Data("runtime".utf8).write(to: runtime, options: .atomic)
                try Data("sibling".utf8).write(to: parentSibling)
                try FileManager.default.removeItem(at: runtime)
                try FileManager.default.removeItem(at: parentSibling)
            }
            try fixture.expectChange(to: "still attached") {
                try Data("still attached".utf8).write(to: fixture.file)
            }
        }
    }

    func testInPlaceWrite() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: "in-place") {
                try Data("in-place".utf8).write(to: fixture.file)
            }
        }
    }

    func testAtomicRenameOverThenInPlaceWrite() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: "replacement") {
                try Data("replacement".utf8).write(to: fixture.file, options: .atomic)
            }
            try fixture.expectChange(to: "updated replacement") {
                try Data("updated replacement".utf8).write(to: fixture.file)
            }
        }
    }

    func testFileDeletionRecreationThenWrite() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: nil) { try FileManager.default.removeItem(at: fixture.file) }
            try fixture.expectChange(to: "recreated") {
                try Data("recreated".utf8).write(to: fixture.file)
            }
            try fixture.expectChange(to: "recreated update") {
                try Data("recreated update".utf8).write(to: fixture.file)
            }
        }
    }

    func testContainingDirectoryReplacementThenWrite() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: "new directory") {
                let old = fixture.parent.appendingPathComponent("old-config")
                try FileManager.default.moveItem(at: fixture.directory, to: old)
                try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
                try Data("new directory".utf8).write(to: fixture.file)
            }
            try fixture.expectChange(to: "new directory update") {
                try Data("new directory update".utf8).write(to: fixture.file)
            }
        }
    }

    func testContainingDirectoryDeletionAndLaterRecreation() throws {
        try withWatcher { fixture in
            try fixture.expectChange(to: nil) { try FileManager.default.removeItem(at: fixture.directory) }
            try fixture.expectChange(to: "directory recreated") {
                try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
                try Data("directory recreated".utf8).write(to: fixture.file)
            }
            try fixture.expectChange(to: "directory recreated update") {
                try Data("directory recreated update".utf8).write(to: fixture.file)
            }
        }
    }
}

private final class WatcherFixture {
    let parent: URL
    let directory: URL
    let file: URL
    private var watcher: ConfigWatcher?
    private var onChange: (() -> Void)?

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = parent.appendingPathComponent("config")
        file = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("initial".utf8).write(to: file)
        watcher = ConfigWatcher(url: file) { [weak self] in
            XCTAssertTrue(Thread.isMainThread)
            self?.onChange?()
        }
    }

    func expectChange(to contents: String?, action: () throws -> Void) throws {
        let expectation = XCTestExpectation(description: "Watch config change to \(contents ?? "absent")")
        var fulfilled = false
        onChange = { [weak self] in
            guard let self, !fulfilled else { return }
            let actual = try? Data(contentsOf: self.file)
            let expected = contents.map { Data($0.utf8) }
            if actual == expected {
                fulfilled = true
                expectation.fulfill()
            }
        }
        defer { onChange = nil }
        try action()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    func expectNoChange(action: () throws -> Void) throws {
        let unexpected = XCTestExpectation(description: "No unrelated or post-release invalidation")
        unexpected.isInverted = true
        onChange = { unexpected.fulfill() }
        defer { onChange = nil }
        try action()
        XCTAssertEqual(XCTWaiter.wait(for: [unexpected], timeout: 0.15), .completed)
    }

    func releaseWatcher() { watcher = nil }

    func cleanup() {
        watcher = nil
        onChange = nil
        try? FileManager.default.removeItem(at: parent)
    }
}
