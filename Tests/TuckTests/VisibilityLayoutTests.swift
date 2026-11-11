import CoreGraphics
import XCTest
import TuckCore
@testable import Tuck

final class VisibilityLayoutTests: XCTestCase {
    private typealias Window = WindowLayoutSnapshot.Window
    private func window(_ id: UInt32, x: CGFloat, y: CGFloat = 0, width: CGFloat = 36,
                        height: CGFloat = 24, pid: Int32 = 42, onScreen: Bool = false) -> Window {
        .init(key: WindowKey(pid: pid, number: id), frame: CGRect(x: x, y: y, width: width, height: height), onScreen: onScreen)
    }
    private func snapshot(_ windows: [Window]) -> WindowLayoutSnapshot { .init(windows: windows) }
    private func icon(_ window: Window, movable: Bool = true) -> BarIcon {
        let id: String
        switch window.key.number {
        case 10: id = Inventory.separatorID
        case 11: id = Inventory.controlID
        default: id = String(window.key.number)
        }
        return BarIcon(id: id, metadata: ItemMetadata(bundleID: "test", label: id), pid: window.key.pid,
                       windowID: window.key.number, frame: window.frame, movable: movable)
    }
    private func icons(_ windows: [Window]) -> [BarIcon] { windows.map { icon($0) } }
    // CPU and Battery deliberately share PID AND width. Their own-control-relative
    // X, not width/PID alone or a 416px display edge, identifies their projections.
    private var known: [Window] {
        [window(1, x: 100, onScreen: true), window(2, x: 180, onScreen: true),
         window(10, x: 240, width: 4, pid: 900, onScreen: true),
         window(11, x: 280, width: 32, pid: 900, onScreen: true)]
    }
    private func replicas(_ sources: [Window]) -> [Window] {
        sources.map { window($0.key.number + 100, x: $0.frame.minX - 414, y: -1440,
                            width: $0.frame.width, height: $0.frame.height, pid: $0.key.pid) }
    }
    private var projected: [Window] { known + replicas(known) }
    private func replacing(_ windows: [Window], _ key: WindowKey, with replacement: Window) -> [Window] {
        windows.map { $0.key == key ? replacement : $0 }
    }
    private func exchangeRows(_ windows: [Window]) -> [Window] {
        windows.map { source in
            let otherID = source.key.number < 100 ? source.key.number + 100 : source.key.number - 100
            guard let other = windows.first(where: { $0.key == WindowKey(pid: source.key.pid, number: otherID) }) else { return source }
            return .init(key: source.key, frame: other.frame, onScreen: other.onScreen)
        }
    }
    private func certificate(_ windows: [Window], evidence: [BarIcon]? = nil) throws -> VerifiedVisibilityLayout {
        let after = snapshot(windows)
        return try XCTUnwrap(VerifiedVisibilityLayout(before: after.keys, after: after, icons: evidence ?? icons(known)))
    }

    func testValidCertificateUsesXOrderNotInputOrder() throws {
        let cert = try certificate(projected, evidence: icons(Array(known.reversed())))
        XCTAssertEqual(cert.knownOrder, known.map(\.key))
        XCTAssertEqual(cert.row, 0)
        XCTAssertTrue(cert.matches(snapshot(projected)))
    }

    func testEveryOriginalSourceAndReplicaMayReciprocallyExchangeRows() throws {
        let cert = try certificate(projected)
        let swapped = exchangeRows(projected)
        XCTAssertTrue(cert.matches(snapshot(swapped)), cert.mismatchReason(snapshot(swapped)) ?? "")
        XCTAssertTrue(cert.matches(snapshot(projected)))
        // Full AX role identity/order can precede the CG row exchange too.
        XCTAssertTrue(try certificate(swapped).matches(snapshot(projected)))
    }

    func testKnownOwnedSeparatorReplicaMayBecomeOnscreenAndChangeWidth() throws {
        let cert = try certificate(projected)
        let changed = projected.map { item -> Window in
            guard item.key == WindowKey(pid: 900, number: 110) else { return item }
            return window(110, x: item.frame.minX - 5000, y: -1440, width: 10_000, pid: 900, onScreen: true)
        }
        // Keep separator after the hidden roles and before control on its row.
        let reordered = changed.map { item -> Window in
            guard item.key.pid == 42 && item.frame.minY == -1440 else { return item }
            return window(item.key.number, x: item.frame.minX - 6000, y: -1440, pid: 42)
        }
        XCTAssertTrue(cert.matches(snapshot(reordered)), cert.mismatchReason(snapshot(reordered)) ?? "")
    }

    func testFreshCGSeparatorGeometryNotStaleAXWidthSelectsReplicas() throws {
        let hidden = projected.map { item -> Window in
            let shift: CGFloat = item.key.pid == 42 ? -10_000 : 0
            let width: CGFloat = [10, 110].contains(item.key.number) ? 10_000 : item.frame.width
            return window(item.key.number, x: item.frame.minX + shift, y: item.frame.minY,
                          width: width, pid: item.key.pid, onScreen: item.onScreen)
        }
        let cert = try certificate(hidden, evidence: icons(known))
        XCTAssertTrue(cert.matches(snapshot(exchangeRows(hidden))))
    }

    func testEqualWidthSamePIDRolesUseRelativeControlAnchor() throws {
        let cert = try certificate(projected)
        let swapped = exchangeRows(projected)
        XCTAssertTrue(cert.matches(snapshot(swapped)))
        // Swap CPU/Battery on just the replica row, retaining all identities.
        let changed = projected.map { item -> Window in
            guard item.key.pid == 42 && item.frame.minY == -1440 else { return item }
            return window(item.key.number, x: item.key.number == 101 ? -234 : -314, y: -1440)
        }
        XCTAssertFalse(cert.matches(snapshot(changed)))
        // Replica IDs have no prior identity at certificate creation: geometry
        // establishes the groups then. Once established, they cannot reorder.
        let newlyCertified = try certificate(changed)
        XCTAssertTrue(newlyCertified.matches(snapshot(changed)))
        XCTAssertFalse(newlyCertified.matches(snapshot(projected)))
    }

    func testOneMemberPerPhysicalRowIsRequired() throws {
        let cert = try certificate(projected)
        let duplicateRow = replacing(projected, known[0].key, with: window(1, x: 100, y: -1440))
        XCTAssertFalse(cert.matches(snapshot(duplicateRow)))
        let foreignRow = replacing(projected, known[0].key, with: window(1, x: 100, y: -1080))
        XCTAssertFalse(cert.matches(snapshot(foreignRow)))
    }

    func testMissingManagedReplicaCannotBeCertified() {
        let missing = projected.filter { $0.key.number != 101 }
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(missing).keys, after: snapshot(missing), icons: icons(known)))
    }

    func testSingletonFixedAudioVideoMayMoveRowsWithoutManagedOrderRequirement() throws {
        let av = window(40, x: 330, width: 30, pid: 55, onScreen: true)
        let original = projected + [av]
        let evidence = icons(known) + [icon(av, movable: false)]
        let cert = try certificate(original, evidence: evidence)
        let changed = exchangeRows(projected) + [window(40, x: -9000, y: -1440, width: 30, pid: 55)]
        XCTAssertTrue(cert.matches(snapshot(changed)), cert.mismatchReason(snapshot(changed)) ?? "")
        let movableEvidence = icons(known) + [icon(av)]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(original).keys, after: snapshot(original), icons: movableEvidence))
    }

    func testFixedReplicasMayExchangeRowsAndMovePastManagedRoles() throws {
        let clock = window(40, x: 330, width: 30, pid: 55)
        let original = projected + [clock] + replicas([clock])
        let cert = try certificate(original, evidence: icons(known) + [icon(clock, movable: false)])
        let changed = exchangeRows(original).map { item -> Window in
            guard item.key.pid == 55 else { return item }
            return window(item.key.number, x: -9000, y: item.frame.minY, width: 30, pid: 55)
        }
        XCTAssertTrue(cert.matches(snapshot(changed)))
    }

    private var differentFixedSlots: (sources: [Window], all: [Window]) {
        let sources = [window(1, x: 100), window(40, x: 136, width: 48, pid: 55),
                       window(2, x: 184), window(10, x: 220, width: 4, pid: 900),
                       window(3, x: 224, width: 48, pid: 43), window(11, x: 272, width: 32, pid: 900)]
        let other = [window(101, x: -314, y: -1440), window(102, x: -278, y: -1440),
                     window(110, x: -242, y: -1440, width: 4, pid: 900),
                     window(140, x: -238, y: -1440, width: 48, pid: 55),
                     window(103, x: -190, y: -1440, width: 48, pid: 43),
                     window(111, x: -142, y: -1440, width: 32, pid: 900)]
        return (sources, sources + other)
    }

    func testFixedIndicatorInDifferentExactGapsDoesNotBreakManagedProjection() throws {
        let fixture = differentFixedSlots
        let evidence = fixture.sources.map { icon($0, movable: $0.key.pid != 55) }
        let cert = try certificate(fixture.all, evidence: evidence)
        XCTAssertTrue(cert.matches(snapshot(exchangeRows(fixture.all))))
        let reordered = fixture.all.map { item -> Window in
            guard item.key.number == 101 else { return item }
            return window(101, x: -260, y: -1440)
        }
        XCTAssertFalse(cert.matches(snapshot(reordered)))
    }

    func testFixedWidthGhostOutsideManagedGapCannotBecomeMissingReplica() {
        let fixed = window(40, x: 330, width: 30, pid: 55)
        let ghost = window(140, x: 1000, y: -1440, width: 30, pid: 55)
        let all = projected + [fixed, ghost]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(all).keys, after: snapshot(all),
            icons: icons(known) + [icon(fixed, movable: false)]))
    }

    func testFixedSlotNormalizationRejectsAmbiguousOrBrokenGapEvidence() {
        let fixture = differentFixedSlots
        let evidence = fixture.sources.map { icon($0, movable: $0.key.pid != 55) }
        let ambiguous = fixture.all + [window(141, x: 1000, y: -1440, width: 48, pid: 55)]
        let openGap = replacing(fixture.all, WindowKey(pid: 55, number: 140),
                                with: window(140, x: -232, y: -1440, width: 48, pid: 55))
        let wrongWidth = replacing(fixture.all, WindowKey(pid: 55, number: 140),
                                   with: window(140, x: -238, y: -1440, width: 40, pid: 55))
        for all in [ambiguous, openGap, wrongWidth] {
            XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(all).keys, after: snapshot(all), icons: evidence))
        }
    }

    func testAllStatusMembershipIncludingUnknownsMustRemainUnchanged() throws {
        let ghost = window(99, x: -9000, y: -7, height: 500, pid: 77)
        let original = projected + [ghost]
        let cert = try certificate(original)
        XCTAssertFalse(cert.matches(snapshot(projected)))
        XCTAssertFalse(cert.matches(snapshot(original + [window(98, x: 400)])))
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(projected).keys, after: snapshot(original), icons: icons(known)))
    }

    func testUntrackedGhostCannotActivateOnEitherAnchoredRow() throws {
        for y: CGFloat in [0, -1440] {
            let ghost = window(99, x: 50, y: y)
            let original = projected + [ghost]
            let cert = try certificate(original)
            XCTAssertFalse(cert.matches(snapshot(projected + [window(99, x: 50, y: y, onScreen: true)])))
            XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(original).keys,
                after: snapshot(projected + [window(99, x: 50, y: y, onScreen: true)]), icons: icons(known)))
        }
    }

    func testUngroupedGhostGeometryAndRowsStayStrict() throws {
        let ghost = window(99, x: 50, y: -1440)
        let cert = try certificate(projected + [ghost])
        for changed in [window(99, x: 51, y: -1440), window(99, x: 50, y: -1440, width: 37),
                        window(99, x: 50, y: -1439.5), window(99, x: 464, y: 0)] {
            XCTAssertFalse(cert.matches(snapshot(projected + [changed])))
        }
    }

    func testUntrackedExactReplicaPairStillCannotSwapRowsOrReorder() throws {
        let ghosts = [window(90, x: 50), window(190, x: -364, y: -1440)]
        let cert = try certificate(projected + ghosts)
        XCTAssertFalse(cert.matches(snapshot(projected + exchangeRows(ghosts))))
        XCTAssertFalse(cert.matches(snapshot(projected + [window(90, x: 60), ghosts[1]])))
    }

    func testOutsideRowPanelKeepsStrictRowAndVisibilityButCanChangeGeometry() throws {
        let panel = window(99, x: 100, y: -7, height: 500, onScreen: true)
        let cert = try certificate(projected + [panel])
        XCTAssertTrue(cert.matches(snapshot(projected + [window(99, x: -9000, y: -7, width: 500, height: 600, onScreen: true)])))
        XCTAssertFalse(cert.matches(snapshot(projected + [window(99, x: 100, y: 0, height: 500, onScreen: true)])))
        XCTAssertFalse(cert.matches(snapshot(projected + [window(99, x: 100, y: -7, height: 500)])))
        // An exempt outside-row panel cannot become a menu-shaped window
        // without the same control-anchor evidence required at creation.
        XCTAssertFalse(cert.matches(snapshot(projected + [window(99, x: 100, y: -7, height: 24, onScreen: true)])))
    }

    func testDormantSamePIDGhostIsNotPromotedByWidthAlone() throws {
        // A dormant same-process same-width window lies elsewhere than the
        // logical role's anchor-relative X, and must remain untracked.
        let ghost = window(90, x: 50)
        let cert = try certificate(projected + [ghost])
        XCTAssertFalse(cert.matches(snapshot(exchangeRows(projected) + [window(90, x: 50, onScreen: true)])))
        let missingKnown = projected.filter { $0.key.number != 101 } + [window(90, x: -364, y: -1440)]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(missingKnown).keys, after: snapshot(missingKnown), icons: icons(known)))
    }

    func testAmbiguousSamePIDReplicaOverlapRejectsCreationAndReuse() throws {
        let overlap = window(90, x: -314, y: -1440)
        let ambiguous = projected + [overlap]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(ambiguous).keys, after: snapshot(ambiguous), icons: icons(known)))
        let ghost = window(90, x: 50, y: -1440)
        let cert = try certificate(projected + [ghost])
        let changed = replacing(projected, WindowKey(pid: 42, number: 101), with: window(101, x: 50, y: -1440))
        // Move both managed roles so their order still agrees; only the overlay
        // of CPU with the unchanged dormant ghost makes the match unsafe.
        let keptOrder = replacing(changed, WindowKey(pid: 42, number: 102), with: window(102, x: 100, y: -1440))
        XCTAssertFalse(cert.matches(snapshot(keptOrder + [ghost])))
    }

    func testAmbiguousOwnControlAnchorsAndMissingOwnedRolesRejectCreation() {
        let duplicateAnchor = projected + [window(90, x: 700, width: 32, pid: 900)]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(duplicateAnchor).keys, after: snapshot(duplicateAnchor), icons: icons(known)))
        for missingID: UInt32 in [10, 11] {
            XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(projected).keys, after: snapshot(projected),
                icons: icons(known.filter { $0.key.number != missingID })))
        }
        let missingAnchor = projected.filter { $0.key.number != 111 }
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(missingAnchor).keys, after: snapshot(missingAnchor), icons: icons(known)))
    }

    func testDormantOffscreenWindowOnDetachedRowIsUntrackedButMayNotActivate() throws {
        // A stale replica left at a previous display arrangement's menu row.
        let dormant = window(99, x: -416, y: -1080, width: 38, height: 37)
        let cert = try certificate(projected + [dormant])
        XCTAssertTrue(cert.matches(snapshot(projected + [dormant])))
        XCTAssertFalse(cert.matches(snapshot(projected + [window(99, x: -416, y: -1080, width: 38, height: 37, onScreen: true)])))
        XCTAssertFalse(cert.matches(snapshot(projected + [window(99, x: -416, y: -1079, width: 38, height: 37)])))
        let active = projected + [window(99, x: -416, y: -1080, width: 38, height: 37, onScreen: true)]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(active).keys, after: snapshot(active), icons: icons(known)))
    }

    func testFixedIndicatorIsDistinguishedFromNearWidthSameProcessDormantWindows() throws {
        let fixed = window(3, x: 320, width: 34, onScreen: true)
        let replica = window(103, x: 320 - 414, y: -1440, width: 34)
        let dormant = [window(90, x: 50, width: 33), window(190, x: -300, y: -1440, width: 33)]
        let all = projected + [fixed, replica] + dormant
        let evidence = icons(known) + [icon(fixed, movable: false)]
        let cert = try certificate(all, evidence: evidence)
        XCTAssertTrue(cert.matches(snapshot(all)))
        // The dormant windows stay untracked: they may not move or activate.
        let moved = projected + [fixed, replica, window(90, x: 51, width: 33), dormant[1]]
        XCTAssertFalse(cert.matches(snapshot(moved)))
        // Two near-width windows in the same control-relative slot stay ambiguous.
        let clash = projected + [fixed, replica, window(90, x: 320, width: 33), dormant[1]]
        XCTAssertNil(VerifiedVisibilityLayout(before: snapshot(clash).keys, after: snapshot(clash), icons: evidence))
    }

    func testSingleRowCertificateStillProtectsOrderAndUnknownGeometry() throws {
        let ghost = window(99, x: 50)
        let cert = try certificate(known + [ghost])
        XCTAssertTrue(cert.matches(snapshot(known + [ghost])))
        XCTAssertFalse(cert.matches(snapshot(known + [window(99, x: 51)])))
        let reordered = replacing(known, known[0].key, with: window(1, x: 200))
        XCTAssertFalse(cert.matches(snapshot(reordered + [ghost])))
        XCTAssertFalse(cert.matches(snapshot(exchangeRows(projected))))
    }

    func testEmptyDuplicateTiedAndInvalidEvidenceIsRejected() {
        let after = snapshot(projected)
        for evidence in [[], icons([known[0], known[0]]), icons(Array(known.dropLast())),
                         icons(replacing(known, known[0].key, with: window(1, x: 180))),
                         icons(replacing(known, known[0].key, with: window(1, x: 100, y: -1440)))] {
            XCTAssertNil(VerifiedVisibilityLayout(before: after.keys, after: after, icons: evidence))
        }
        XCTAssertNil(VerifiedVisibilityLayout(before: after.keys, after: snapshot(projected + [known[0]]), icons: icons(known)))
        let bad = replacing(projected, known[0].key, with: window(1, x: .nan))
        XCTAssertNil(VerifiedVisibilityLayout(before: after.keys, after: snapshot(bad), icons: icons(known)))
    }

    func testMatchingRejectsDuplicateNonfiniteAndEmptySnapshotRecords() throws {
        let cert = try certificate(projected)
        XCTAssertFalse(cert.matches(snapshot(projected + [known[0]])))
        XCTAssertFalse(cert.matches(snapshot(replacing(projected, known[0].key, with: window(1, x: .nan)))))
        XCTAssertFalse(cert.matches(snapshot(replacing(projected, known[0].key, with: window(1, x: 100, width: 0)))))
        XCTAssertFalse(cert.matches(snapshot([])))
    }
}
