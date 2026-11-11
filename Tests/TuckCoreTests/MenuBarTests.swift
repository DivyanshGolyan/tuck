import CoreGraphics
import XCTest
@testable import TuckCore

final class MenuBarTests: XCTestCase {
    private func key(_ number: UInt32) -> WindowKey { WindowKey(pid: 42, number: number) }
    private func window(_ number: UInt32, _ frame: CGRect, onScreen: Bool = true, title: String = "") -> StatusWindow {
        StatusWindow(key: key(number), frame: frame, onScreen: onScreen, title: title)
    }

    func testBatteryExactAndInsetGeometryExcludeOverlappingFocusGhost() {
        // Observed secondary-display bounds. Battery's midpoint (1675,-1428)
        // lies inside both windows, so midpoint-only matching was ambiguous.
        let battery = window(14, CGRect(x: 1654, y: -1440, width: 42, height: 24))
        let focus = window(3082, CGRect(x: 1673, y: -1440, width: 38, height: 24), onScreen: false)
        let candidates = [focus, battery]
        XCTAssertTrue(focus.frame.contains(CGPoint(x: battery.frame.midX, y: battery.frame.midY)))
        XCTAssertEqual(matchWindow(battery.frame, candidates: candidates, used: [])?.key, key(14))
        XCTAssertEqual(matchWindow(battery.frame.insetBy(dx: 3, dy: 3), candidates: candidates, used: [])?.key, key(14))
    }

    func testDuplicateExactBoundsAreRejectedRegardlessOfVisibility() {
        let frame = CGRect(x: 1654, y: -1440, width: 42, height: 24)
        let candidates = [window(14, frame), window(99, frame, onScreen: false)]
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: []))
        // Removing an already-used candidate must not invent unique evidence.
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: [key(99)]))
    }

    func testUsedExactWindowCannotFallBackToWeakerContainingGhost() {
        let frame = CGRect(x: 1654, y: -1440, width: 42, height: 24)
        let candidates = [window(14, frame), window(99, frame.insetBy(dx: -10, dy: -5), onScreen: false)]
        XCTAssertEqual(matchWindow(frame, candidates: candidates, used: [])?.key, key(14))
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: [key(14)]))
    }

    func testAmbiguousWholeRectangleContainmentIsRejected() {
        let frame = CGRect(x: 1670, y: -1435, width: 20, height: 12)
        let candidates = [
            window(14, CGRect(x: 1654, y: -1440, width: 42, height: 24)),
            window(99, CGRect(x: 1660, y: -1440, width: 40, height: 24))
        ]
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: []))
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: [key(99)]))
    }

    func testUniqueOffscreenNegativeCoordinateWindowIsLegitimate() {
        let frame = CGRect(x: -3516, y: -1440, width: 36, height: 24)
        let candidate = window(16, frame, onScreen: false)
        XCTAssertEqual(matchWindow(frame, candidates: [candidate], used: [])?.key, key(16))
        XCTAssertEqual(matchWindow(frame.insetBy(dx: 3, dy: 3), candidates: [candidate], used: [])?.key, key(16))
        XCTAssertNil(matchWindow(frame, candidates: [candidate], used: [key(16)]))
    }

    func testOwnItemsAreTheNamedSourceAndItsSameWidthReplicaOnEachRow() {
        let control = window(1, CGRect(x: 1928, y: -1440, width: 36, height: 24), title: OwnItem.control.title)
        let replica = window(2, CGRect(x: 1514, y: 0, width: 36, height: 37))
        // A hidden separator and its replica may both be offscreen.
        let separator = window(5, CGRect(x: -3266, y: -1440, width: 5016, height: 24), onScreen: false,
                               title: OwnItem.separator.title)
        let separatorReplica = window(3, CGRect(x: -3632, y: 0, width: 5016, height: 37), onScreen: false)
        let own = [control, replica, separator, separatorReplica]
        func rows(_ windows: [StatusWindow]) -> MenuRows {
            MenuRows(WindowList(skippingMalformed: windows), ownPID: 42, displays: [])
        }
        let anchored = rows(own)
        XCTAssertNil(anchored.fault)
        XCTAssertEqual(anchored.rows, [-1440, 0])
        XCTAssertEqual(anchored.control.map(\.key), [key(1), key(2)])
        XCTAssertEqual(anchored.separator.map(\.key), [key(5), key(3)])
        XCTAssertFalse(anchored.boundaryRevealed)
        // A second same-width window on a row, or a second named source, identifies nothing.
        XCTAssertEqual(rows(own + [window(4, replica.frame, onScreen: false)]).fault, "ambiguous control anchors")
        XCTAssertEqual(rows(own + [window(6, control.frame.offsetBy(dx: 0, dy: 500), title: OwnItem.control.title)]).fault,
                       "Tuck's menu bar items not identified")
        XCTAssertEqual(rows(own.filter { $0.key != key(1) }).fault, "Tuck's menu bar items not identified")
    }

    func testUnknownOffscreenGhostDoesNotBlockSuccessfulEmptyExtras() {
        let ghost = window(263, CGRect(x: 0, y: 0, width: 38, height: 24), onScreen: false)
        XCTAssertFalse(shouldBlockEmptyExtras(candidates: [ghost], hasLastGood: false))
        XCTAssertTrue(shouldBlockEmptyExtras(candidates: [ghost], hasLastGood: true))
    }

    func testOnscreenWindowBlocksEmptyExtrasEvenWithoutHistory() {
        let visible = window(263, CGRect(x: 100, y: 0, width: 38, height: 24))
        XCTAssertTrue(shouldBlockEmptyExtras(candidates: [visible], hasLastGood: false))
    }

    func testNoRemainingWindowsAllowsKnownLastItemRemoval() {
        XCTAssertFalse(shouldBlockEmptyExtras(candidates: [], hasLastGood: true))
        XCTAssertFalse(shouldBlockEmptyExtras(candidates: [], hasLastGood: false))
    }

    func testWindowListDropsDuplicateKeysAndUnusableFrames() {
        let good = window(1, CGRect(x: 10, y: 0, width: 36, height: 24))
        let duplicate = window(1, CGRect(x: 60, y: 0, width: 36, height: 24))
        let empty = window(2, CGRect(x: 10, y: 0, width: 0, height: 24))
        let infinite = window(3, CGRect(x: CGFloat.infinity, y: 0, width: 36, height: 24))
        XCTAssertEqual(WindowList(skippingMalformed: [good]).windows, [good])
        for bad in [[good, duplicate], [good, empty], [infinite]] {
            XCTAssertEqual(WindowList(skippingMalformed: bad).windows, bad.first == good ? [good] : [])
        }
        XCTAssertEqual(WindowList(skippingMalformed: [good, duplicate, empty, infinite]).windows, [good])
    }

    func testIconIdentityKeyAndFixedSystemItems() {
        XCTAssertEqual(IconIdentity(bundle: "com.example", item: nil).key, "com.example")
        XCTAssertEqual(IconIdentity(bundle: "com.example", item: "a").key, "com.example::a")
        XCTAssertFalse(IconIdentity.isMovable(bundle: "com.apple.controlcenter", item: "Clock"))
        XCTAssertTrue(IconIdentity.isMovable(bundle: "com.apple.controlcenter", item: "Battery"))
        XCTAssertFalse(IconIdentity.isMovable(bundle: "com.apple.notificationcenterui", item: "x"))
        XCTAssertTrue(IconIdentity.isMovable(bundle: "com.example", item: "x"))
    }
}
