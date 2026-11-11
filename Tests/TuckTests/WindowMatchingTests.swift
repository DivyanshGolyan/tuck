import CoreGraphics
import XCTest
@testable import Tuck

final class WindowMatchingTests: XCTestCase {
    private func window(_ id: CGWindowID, _ frame: CGRect, onScreen: Bool = true) -> StatusWindow {
        StatusWindow(id: id, frame: frame, publicTitle: "", onScreen: onScreen)
    }

    func testBatteryExactAndInsetGeometryExcludeOverlappingFocusGhost() {
        // Observed secondary-display bounds. Battery's midpoint (1675,-1428)
        // lies inside both windows, so midpoint-only matching was ambiguous.
        let battery = window(14, CGRect(x: 1654, y: -1440, width: 42, height: 24))
        let focus = window(3082, CGRect(x: 1673, y: -1440, width: 38, height: 24), onScreen: false)
        let candidates = [focus, battery]
        XCTAssertTrue(focus.frame.contains(CGPoint(x: battery.frame.midX, y: battery.frame.midY)))
        XCTAssertEqual(matchWindow(battery.frame, candidates: candidates, used: [])?.id, 14)
        XCTAssertEqual(matchWindow(battery.frame.insetBy(dx: 3, dy: 3), candidates: candidates, used: [])?.id, 14)
    }

    func testDuplicateExactBoundsAreRejectedRegardlessOfVisibility() {
        let frame = CGRect(x: 1654, y: -1440, width: 42, height: 24)
        let candidates = [window(14, frame), window(99, frame, onScreen: false)]
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: []))
        // Removing an already-used candidate must not invent unique evidence.
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: [99]))
    }

    func testUsedExactWindowCannotFallBackToWeakerContainingGhost() {
        let frame = CGRect(x: 1654, y: -1440, width: 42, height: 24)
        let candidates = [window(14, frame), window(99, frame.insetBy(dx: -10, dy: -5), onScreen: false)]
        XCTAssertEqual(matchWindow(frame, candidates: candidates, used: [])?.id, 14)
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: [14]))
    }

    func testAmbiguousWholeRectangleContainmentIsRejected() {
        let frame = CGRect(x: 1670, y: -1435, width: 20, height: 12)
        let candidates = [
            window(14, CGRect(x: 1654, y: -1440, width: 42, height: 24)),
            window(99, CGRect(x: 1660, y: -1440, width: 40, height: 24))
        ]
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: []))
        XCTAssertNil(matchWindow(frame, candidates: candidates, used: [99]))
    }

    func testUniqueOffscreenNegativeCoordinateWindowIsLegitimate() {
        let frame = CGRect(x: -3516, y: -1440, width: 36, height: 24)
        let candidate = window(16, frame, onScreen: false)
        XCTAssertEqual(matchWindow(frame, candidates: [candidate], used: [])?.id, 16)
        XCTAssertEqual(matchWindow(frame.insetBy(dx: 3, dy: 3), candidates: [candidate], used: [])?.id, 16)
        XCTAssertNil(matchWindow(frame, candidates: [candidate], used: [16]))
    }

    func testOwnedReplicaUsesNamedRoleAndUniqueWidthOnRequestedRow() {
        let source = StatusWindow(id: 1, frame: CGRect(x: 1928, y: -1440, width: 36, height: 24),
                                  publicTitle: "TuckControl", onScreen: true)
        let replica = window(2, CGRect(x: 1514, y: 0, width: 36, height: 37))
        let separator = window(3, CGRect(x: -3632, y: 0, width: 5016, height: 37), onScreen: false)
        let candidates = [source, replica, separator]
        XCTAssertEqual(ownedStatusWindow(title: "TuckControl", menuY: -1440, candidates: candidates)?.id, 1)
        XCTAssertEqual(ownedStatusWindow(title: "TuckControl", menuY: 0, candidates: candidates)?.id, 2)
        XCTAssertNil(ownedStatusWindow(title: "Missing", menuY: 0, candidates: candidates))
        XCTAssertNil(ownedStatusWindow(title: "TuckControl", menuY: 500, candidates: candidates))
        XCTAssertNil(ownedStatusWindow(title: "TuckControl", menuY: 0,
            candidates: candidates + [window(4, replica.frame, onScreen: false)]))
        XCTAssertNil(ownedStatusWindow(title: "TuckControl", menuY: 0, candidates: candidates + [source]))
    }

    func testOwnedHiddenSeparatorReplicaMayBeOffscreen() {
        let source = StatusWindow(id: 1, frame: CGRect(x: -3266, y: -1440, width: 5016, height: 24),
                                  publicTitle: "TuckSeparator", onScreen: false)
        let replica = window(2, CGRect(x: -3632, y: 0, width: 5016, height: 37), onScreen: false)
        XCTAssertEqual(ownedStatusWindow(title: "TuckSeparator", menuY: 0, candidates: [source, replica])?.id, 2)
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

}
