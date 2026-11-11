import AppKit
import XCTest
import TuckCore
@testable import Tuck

final class RunningAppsTests: XCTestCase {
    @MainActor func testAKeptListMatchesAFreshReadAndExcludesTuck() {
        let processes = RunningApps()
        let first = processes.current()
        let again = processes.current()
        XCTAssertEqual(again, first)
        XCTAssertEqual(Set(first.map(\.pid)).count, first.count)
        XCTAssertFalse(first.contains { $0.pid == getpid() })
        let fresh = Dictionary(uniqueKeysWithValues: RunningApps().current().map { ($0.pid, $0) })
        for process in first where AppProcess.incarnation(pid: process.pid, launchDate: nil) != nil {
            if let other = fresh[process.pid] { XCTAssertEqual(process, other) }
        }
    }
}
