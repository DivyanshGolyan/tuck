import CoreGraphics
import Foundation
import XCTest
@testable import TuckCore

/// A no-change observation of a bar the size of a busy real one: 25 icons across 12 apps
/// on 2 rows, three fixed indicators, 300 unrelated status windows and 110 running apps.
/// Run with `swift test -c release --filter MenuBarBenchmarkTests`; it prints medians.
final class MenuBarBenchmarkTests: XCTestCase {
    static let ownPID: Int32 = 900
    static let controlCentre: Int32 = 1000

    struct Fixture {
        let list: WindowList
        let displays: [Display]
        let running: [AppProcess]
        let readings: [AppReading]
    }

    static func fixture() -> Fixture {
        let displays = [Display(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), usableLeft: 180),
                        Display(frame: CGRect(x: -204, y: -1117, width: 1920, height: 1080), usableLeft: -24)]
        // 22 movable icons from 11 apps, then the separator among them, the control, and
        // Control Centre's fixed indicators right of everything.
        let counts = [4, 3, 3, 2, 2, 2, 1, 1, 1, 1, 2]
        var slots: [(pid: Int32, item: String, width: CGFloat, movable: Bool)] = []
        for (app, count) in counts.enumerated() {
            for index in 0..<count {
                slots.append((1001 + Int32(app), "item\(index)", CGFloat(22 + (app * 7 + index * 5) % 20), true))
            }
        }
        var rng = SplitMix64(state: 7)
        slots.shuffle(using: &rng)
        slots.insert((ownPID, OwnItem.separator.id, 4, true), at: 12)
        slots.append((ownPID, OwnItem.control.id, 20, true))
        for (item, width) in [("AudioVideoModule", 26), ("BentoBox", 44), ("Clock", 70)] {
            slots.append((controlCentre, item, CGFloat(width), false))
        }

        var windows: [StatusWindow] = []
        var numbers: [Int32: UInt32] = [:]
        var bound: [Int32: [AppReading.BoundIcon]] = [:]
        for (row, display) in displays.enumerated() {
            var x = display.frame.maxX - 10 - slots.reduce(0) { $0 + $1.width }
            for slot in slots {
                let number = numbers[slot.pid, default: 0] + 1
                numbers[slot.pid] = number
                let title = row == 0 ? OwnItem(rawValue: slot.item)?.title ?? "" : ""
                let key = WindowKey(pid: slot.pid, number: number)
                windows.append(StatusWindow(key: key, frame: CGRect(x: x, y: display.frame.minY, width: slot.width, height: 24),
                                            onScreen: true, title: title))
                if row == 0 && slot.pid != ownPID {
                    let icons = bound[slot.pid, default: []]
                    bound[slot.pid] = icons + [AppReading.BoundIcon(
                        identity: IconIdentity(bundle: bundle(slot.pid), item: slot.item), label: slot.item,
                        movable: slot.movable, window: key, element: icons.count)]
                }
                x += slot.width
            }
        }
        // Panels, popovers and dormant replicas of other apps, and a few of the icon apps.
        for index in 0..<300 {
            let pid = index % 10 == 0 ? 1001 + Int32(index / 10 % 11) : 2000 + Int32(index % 98)
            let number = numbers[pid, default: 0] + 1
            numbers[pid] = number
            let frame = index % 3 == 0
                ? CGRect(x: CGFloat(index * 13 % 1400), y: 5000, width: 30, height: 24)
                : CGRect(x: CGFloat(index * 17 % 1400), y: 40 + CGFloat(index % 50), width: 320, height: 200 + CGFloat(index % 7))
            windows.append(StatusWindow(key: WindowKey(pid: pid, number: number), frame: frame, onScreen: index % 3 == 1))
        }
        windows.shuffle(using: &rng)

        let running = (1001...1011).map(app) + [app(controlCentre)] + (2000..<2098).map(app)
        let readings = running.compactMap { process in
            bound[process.pid].map { AppReading(app: process, outcome: .clean($0)) }
        }
        return Fixture(list: WindowList(skippingMalformed: windows), displays: displays, running: running, readings: readings)
    }

    static func bundle(_ pid: Int32) -> String { pid == controlCentre ? "com.apple.controlcenter" : "app.\(pid)" }
    static func app(_ pid: Int32) -> AppProcess {
        AppProcess(pid: pid, bundle: bundle(pid), name: "App \(pid)", incarnation: "1")
    }

    private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testNoChangeObservation() {
        let fixture = Self.fixture()
        let first = MenuRows(fixture.list, ownPID: Self.ownPID, displays: fixture.displays)
        XCTAssertNil(first.fault)
        XCTAssertEqual(first.rows.count, 2)
        let bar = MenuBar.observe(first, running: fixture.running, readings: fixture.readings, previous: .none)
        XCTAssertTrue(bar.complete, "\(bar.issues)")
        XCTAssertTrue(bar.reusable)
        XCTAssertEqual(bar.roles.count, 25)
        XCTAssertEqual(bar.roles.filter(\.grouped).count, 25)

        var rowsTimes: [Double] = [], pureTimes: [Double] = []
        for _ in 0..<200 {
            var rows: MenuRows!
            rowsTimes.append(milliseconds { rows = MenuRows(fixture.list, ownPID: Self.ownPID, displays: fixture.displays) })
            var next: MenuBar!
            var stale: [Int32: String] = [:]
            pureTimes.append(milliseconds {
                let survey = bar.survey(rows, running: fixture.running)
                stale = survey.stale
                next = MenuBar.observe(survey, readings: [])
            })
            XCTAssertEqual(stale, [:])
            XCTAssertTrue(next.complete)
            XCTAssertTrue(next.reusable)
            XCTAssertEqual(next.order, bar.order)
        }
        print(String(format: "BENCH no-change: MenuRows %.3f ms, survey+observe %.3f ms (median of %d)",
                     median(rowsTimes), median(pureTimes), pureTimes.count))
    }
}
