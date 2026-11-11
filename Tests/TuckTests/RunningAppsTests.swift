import AppKit
import XCTest
import TuckCore
@testable import Tuck

final class RunningAppsTests: XCTestCase {
    /// A remembered process is the one a fresh read describes. Prints the cost of a
    /// first read and of a remembered one (`swift test -c release --filter RunningAppsTests`).
    @MainActor func testRememberedProcessesMatchAFreshRead() {
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let processes = RunningApps()
        var first: [AppProcess] = []
        let cold = milliseconds { first = processes.current() }
        var warm: [Double] = []
        var again: [AppProcess] = []
        for _ in 0..<30 { warm.append(milliseconds { again = processes.current() }) }
        let fresh = Dictionary(uniqueKeysWithValues: RunningApps().current().map { ($0.pid, $0) })
        let unknowable = Set(fresh.values.filter { AppProcess.incarnation(pid: $0.pid, launchDate: nil) == nil
            && NSRunningApplication(processIdentifier: $0.pid)?.launchDate == nil }.map(\.pid))
        XCTAssertEqual(Set(again.map(\.pid)), Set(fresh.keys))
        for process in again where !unknowable.contains(process.pid) { XCTAssertEqual(process, fresh[process.pid]) }
        // Without a knowable incarnation nothing is remembered: every read is a new one.
        let before = Dictionary(uniqueKeysWithValues: first.map { ($0.pid, $0.incarnation) })
        for process in again where unknowable.contains(process.pid) { XCTAssertNotEqual(process.incarnation, before[process.pid]) }
        XCTAssertEqual(Set(first.map(\.pid)).count, first.count)
        XCTAssertFalse(again.contains { $0.pid == getpid() })
        print(String(format: "BENCH RunningApps: %d apps, first %.3f ms, remembered %.3f ms (median)",
                     again.count, cold, warm.sorted()[warm.count / 2]))
    }
}
