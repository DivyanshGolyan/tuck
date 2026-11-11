import CoreGraphics
import XCTest
import TuckCore

/// Ported from VisibilityLayoutTests with the same fixtures. A valid certificate is now
/// a reusable bar built from clean readings; "matches" is the observe-only hide finding
/// nothing stale; a certificate that could not be built is an app that is ungrouped, so
/// stale, or rows with a fault.
final class MenuBarReplicaTests: XCTestCase {
    private let ownPID: Int32 = 900

    private func window(_ id: UInt32, x: CGFloat, y: CGFloat = 0, width: CGFloat = 36,
                        height: CGFloat = 24, pid: Int32 = 42, onScreen: Bool = false) -> StatusWindow {
        // Tuck's own source windows carry their autosave titles, as AppKit gives them.
        let title = pid == ownPID && id == 10 ? OwnItem.separator.title : pid == ownPID && id == 11 ? OwnItem.control.title : ""
        return StatusWindow(key: WindowKey(pid: pid, number: id),
                            frame: CGRect(x: x, y: y, width: width, height: height), onScreen: onScreen, title: title)
    }
    private struct Seen { let window: StatusWindow; let movable: Bool }
    private func icon(_ window: StatusWindow, movable: Bool = true) -> Seen { Seen(window: window, movable: movable) }
    private func icons(_ windows: [StatusWindow]) -> [Seen] { windows.map { icon($0) } }
    // CPU and Battery deliberately share PID AND width. Their own-control-relative
    // X, not width/PID alone or a 416px display edge, identifies their projections.
    private var known: [StatusWindow] {
        [window(1, x: 100, onScreen: true), window(2, x: 180, onScreen: true),
         window(10, x: 240, width: 4, pid: 900, onScreen: true),
         window(11, x: 280, width: 32, pid: 900, onScreen: true)]
    }
    private func replicas(_ sources: [StatusWindow]) -> [StatusWindow] {
        sources.map { window($0.key.number + 100, x: $0.frame.minX - 414, y: -1440,
                             width: $0.frame.width, height: $0.frame.height, pid: $0.key.pid) }
    }
    private var projected: [StatusWindow] { known + replicas(known) }
    private func replacing(_ windows: [StatusWindow], _ key: WindowKey, with replacement: StatusWindow) -> [StatusWindow] {
        windows.map { $0.key == key ? replacement : $0 }
    }
    private func exchangeRows(_ windows: [StatusWindow]) -> [StatusWindow] {
        windows.map { source in
            let otherID = source.key.number < 100 ? source.key.number + 100 : source.key.number - 100
            guard let other = windows.first(where: { $0.key == WindowKey(pid: source.key.pid, number: otherID) }) else { return source }
            return StatusWindow(key: source.key, frame: other.frame, onScreen: other.onScreen, title: source.title)
        }
    }

    private func app(_ pid: Int32, incarnation: String = "1") -> AppProcess {
        AppProcess(pid: pid, bundle: "app\(pid)", name: "App \(pid)", incarnation: incarnation)
    }
    private var apps: [AppProcess] { [42, 43, 55, 77].map { app($0) } }
    private func id(_ pid: Int32, _ number: UInt32) -> String { "app\(pid)::\(number)" }

    private func rows(_ windows: [StatusWindow]) -> MenuRows {
        let list = WindowList(skippingMalformed: windows)
        return MenuRows(list, ownPID: ownPID, displays: [], skippedMalformed: list.windows.count != windows.count)
    }
    /// Clean readings of what AX saw, as the post-pass bridge builds them: every running
    /// app with a status window is read, Tuck's own items come from the list.
    private func readings(_ evidence: [Seen], in windows: [StatusWindow], running: [AppProcess]) -> [AppReading] {
        let byPID = Dictionary(grouping: evidence.filter { $0.window.key.pid != ownPID }, by: \.window.key.pid)
        let present = Set(windows.map(\.key.pid))
        return running.filter { byPID[$0.pid] != nil || present.contains($0.pid) }.map { app in
            AppReading(app: app, outcome: .clean((byPID[app.pid] ?? []).enumerated().map { index, seen in
                AppReading.BoundIcon(identity: IconIdentity(bundle: app.bundle, item: String(seen.window.key.number)),
                                     label: app.name, movable: seen.movable, window: seen.window.key, element: index)
            }))
        }
    }
    private func certify(_ windows: [StatusWindow], evidence: [Seen]? = nil, running: [AppProcess]? = nil) -> MenuBar {
        let running = running ?? apps
        return MenuBar.observe(rows(windows), running: running,
                               readings: readings(evidence ?? icons(known), in: windows, running: running), previous: .none)
    }
    private func stale(_ bar: MenuBar, _ windows: [StatusWindow], running: [AppProcess]? = nil) -> [Int32: String] {
        bar.staleApps(in: rows(windows), running: running ?? apps)
    }
    /// The observe-only hide as App runs it: nil when it would hide, else why not.
    private func decline(_ bar: MenuBar, _ windows: [StatusWindow], running: [AppProcess]? = nil,
                         file: StaticString = #filePath, line: UInt = #line) -> String? {
        let running = running ?? apps
        guard bar.reusable else { return "no verified layout" }
        let rows = rows(windows)
        if rows.skippedMalformed { return "invalid window snapshot" }
        let stale = bar.staleApps(in: rows, running: running)
        let observed = MenuBar.observe(rows, running: running, readings: [], previous: bar)
        XCTAssertEqual(observed.complete, stale.isEmpty && rows.fault == nil, "complete exactly when nothing is stale", file: file, line: line)
        if let fault = rows.fault { return fault }
        if let pid = stale.keys.min() { return stale[pid] }
        return observed.order == bar.order ? nil : "known window order changed"
    }
    private func assertCertified(_ bar: MenuBar, _ windows: [StatusWindow], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bar.complete, "\(bar.issues)", file: file, line: line)
        XCTAssertTrue(bar.reusable, "\(stale(bar, windows))", file: file, line: line)
        XCTAssertNil(decline(bar, windows), file: file, line: line)
    }

    func testValidCertificateUsesXOrderNotInputOrder() {
        let bar = certify(projected, evidence: icons(Array(known.reversed())))
        XCTAssertEqual(bar.order, [id(42, 1), id(42, 2), OwnItem.separator.id, OwnItem.control.id])
        XCTAssertEqual(bar.roles.map(\.identity.key), [id(42, 1), id(42, 2)])
        XCTAssertEqual(bar.activeRow.map { bar.rows.rows[$0] }, 0)
        assertCertified(bar, projected)
    }

    func testEveryOriginalSourceAndReplicaMayReciprocallyExchangeRows() {
        let bar = certify(projected)
        let swapped = exchangeRows(projected)
        XCTAssertNil(decline(bar, swapped))
        XCTAssertNil(decline(bar, projected))
        // Full AX role identity/order can precede the CG row exchange too.
        XCTAssertNil(decline(certify(swapped), projected))
    }

    func testKnownOwnedSeparatorReplicaMayBecomeOnscreenAndChangeWidth() {
        let bar = certify(projected)
        let changed = projected.map { item -> StatusWindow in
            guard item.key == WindowKey(pid: 900, number: 110) else { return item }
            return window(110, x: item.frame.minX - 5000, y: -1440, width: 10_000, pid: 900, onScreen: true)
        }
        // Keep separator after the hidden roles and before control on its row.
        let reordered = changed.map { item -> StatusWindow in
            guard item.key.pid == 42 && item.frame.minY == -1440 else { return item }
            return window(item.key.number, x: item.frame.minX - 6000, y: -1440, pid: 42)
        }
        XCTAssertNil(decline(bar, reordered))
    }

    func testFreshCGSeparatorGeometryNotStaleAXWidthSelectsReplicas() {
        let hidden = projected.map { item -> StatusWindow in
            let shift: CGFloat = item.key.pid == 42 ? -10_000 : 0
            let width: CGFloat = [10, 110].contains(item.key.number) ? 10_000 : item.frame.width
            return window(item.key.number, x: item.frame.minX + shift, y: item.frame.minY,
                          width: width, pid: item.key.pid, onScreen: item.onScreen)
        }
        // Readings carry window keys only; the bar takes every frame from the list.
        let bar = certify(hidden, evidence: icons(known))
        assertCertified(bar, hidden)
        XCTAssertNil(decline(bar, exchangeRows(hidden)))
    }

    func testEqualWidthSamePIDRolesUseRelativeControlAnchor() {
        let bar = certify(projected)
        XCTAssertNil(decline(bar, exchangeRows(projected)))
        // Swap CPU/Battery on just the replica row, retaining all identities.
        let changed = projected.map { item -> StatusWindow in
            guard item.key.pid == 42 && item.frame.minY == -1440 else { return item }
            return window(item.key.number, x: item.key.number == 101 ? -234 : -314, y: -1440)
        }
        XCTAssertEqual(stale(bar, changed)[42], "known window order changed")
        XCTAssertNotNil(decline(bar, changed))
        // Replica IDs have no prior identity when an app is read: geometry
        // establishes the groups then. Once established, they cannot reorder.
        let newlyCertified = certify(changed)
        assertCertified(newlyCertified, changed)
        XCTAssertEqual(stale(newlyCertified, projected)[42], "known window order changed")
    }

    func testOneMemberPerPhysicalRowIsRequired() {
        let bar = certify(projected)
        let duplicateRow = replacing(projected, known[0].key, with: window(1, x: 100, y: -1440))
        XCTAssertEqual(stale(bar, duplicateRow)[42], "logical role row membership changed")
        let foreignRow = replacing(projected, known[0].key, with: window(1, x: 100, y: -1080))
        XCTAssertEqual(stale(bar, foreignRow)[42], "logical role row membership changed")
        XCTAssertNotNil(decline(bar, foreignRow))
    }

    func testMissingManagedReplicaCannotBeCertified() {
        let missing = projected.filter { $0.key.number != 101 }
        let bar = certify(missing)
        XCTAssertFalse(bar.reusable)
        XCTAssertEqual(stale(bar, missing), [42: "icon not grouped across rows"])
    }

    func testSingletonFixedAudioVideoMayMoveRowsWithoutManagedOrderRequirement() {
        let av = window(40, x: 330, width: 30, pid: 55, onScreen: true)
        let original = projected + [av]
        let bar = certify(original, evidence: icons(known) + [icon(av, movable: false)])
        assertCertified(bar, original)
        let changed = exchangeRows(projected) + [window(40, x: -9000, y: -1440, width: 30, pid: 55)]
        XCTAssertNil(decline(bar, changed))
        let movable = certify(original, evidence: icons(known) + [icon(av)])
        XCTAssertFalse(movable.reusable)
        XCTAssertEqual(stale(movable, original), [55: "icon not grouped across rows"])
    }

    func testFixedReplicasMayExchangeRowsAndMovePastManagedRoles() {
        let clock = window(40, x: 330, width: 30, pid: 55)
        let original = projected + [clock] + replicas([clock])
        let bar = certify(original, evidence: icons(known) + [icon(clock, movable: false)])
        assertCertified(bar, original)
        let changed = exchangeRows(original).map { item -> StatusWindow in
            guard item.key.pid == 55 else { return item }
            return window(item.key.number, x: -9000, y: item.frame.minY, width: 30, pid: 55)
        }
        XCTAssertNil(decline(bar, changed))
    }

    private var differentFixedSlots: (sources: [StatusWindow], all: [StatusWindow]) {
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

    func testFixedIndicatorInDifferentExactGapsDoesNotBreakManagedProjection() {
        let fixture = differentFixedSlots
        let evidence = fixture.sources.map { icon($0, movable: $0.key.pid != 55) }
        let bar = certify(fixture.all, evidence: evidence)
        assertCertified(bar, fixture.all)
        XCTAssertNil(decline(bar, exchangeRows(fixture.all)))
        let reordered = fixture.all.map { item -> StatusWindow in
            guard item.key.number == 101 else { return item }
            return window(101, x: -260, y: -1440)
        }
        XCTAssertEqual(stale(bar, reordered)[42], "known window order changed")
    }

    func testFixedWidthGhostOutsideManagedGapCannotBecomeMissingReplica() {
        let fixed = window(40, x: 330, width: 30, pid: 55)
        let ghost = window(140, x: 1000, y: -1440, width: 30, pid: 55)
        let all = projected + [fixed, ghost]
        let bar = certify(all, evidence: icons(known) + [icon(fixed, movable: false)])
        XCTAssertFalse(bar.reusable)
        XCTAssertEqual(stale(bar, all), [55: "icon not grouped across rows"])
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
            let bar = certify(all, evidence: evidence)
            XCTAssertFalse(bar.reusable)
            XCTAssertEqual(stale(bar, all)[42], "icon not grouped across rows")
        }
        // A fixed indicator that fits no gap is ungrouped, and so is everything its
        // replica's width was removed for.
        XCTAssertEqual(Set(stale(certify(openGap, evidence: evidence), openGap).keys), [42, 43, 55])
    }

    func testAllStatusMembershipIncludingUnknownsMustRemainUnchanged() {
        let ghost = window(99, x: -9000, y: -7, height: 500, pid: 77)
        let original = projected + [ghost]
        let bar = certify(original)
        assertCertified(bar, original)
        XCTAssertEqual(stale(bar, projected), [77: "status-window membership changed"])
        XCTAssertEqual(stale(bar, original + [window(98, x: 400)]), [42: "status-window membership changed"])
        // A running app's window that appeared after the apps were read is read once it
        // can be an icon; a panel alone gives it nothing to read.
        XCTAssertEqual(stale(certify(projected), original), [:])
        XCTAssertEqual(stale(certify(projected), projected + [window(98, x: 50, pid: 77)]), [77: "not yet read"])
        XCTAssertEqual(stale(certify(projected), projected + [window(98, x: 50, y: -1080, pid: 77)]), [:])
        // Accepted tradeoff: a ghost whose process is not a running app is not evidence.
        let running = apps.filter { $0.pid != 77 }
        XCTAssertNil(decline(certify(original, running: running), projected, running: running))
        XCTAssertNil(decline(certify(projected, running: running), original, running: running))
    }

    func testUntrackedGhostCannotActivateOnEitherAnchoredRow() {
        for y: CGFloat in [0, -1440] {
            let ghost = window(99, x: 50, y: y)
            let original = projected + [ghost]
            let bar = certify(original)
            assertCertified(bar, original)
            let active = projected + [window(99, x: 50, y: y, onScreen: true)]
            XCTAssertEqual(stale(bar, active)[42], "untracked visibility changed")
            let activeBar = certify(active)
            XCTAssertFalse(activeBar.reusable)
            XCTAssertEqual(stale(activeBar, active)[42], "untracked active menu-bar window")
        }
    }

    func testUngroupedGhostGeometryAndRowsStayStrict() {
        let ghost = window(99, x: 50, y: -1440)
        let bar = certify(projected + [ghost])
        for changed in [window(99, x: 51, y: -1440), window(99, x: 50, y: -1440, width: 37),
                        window(99, x: 50, y: -1439.5), window(99, x: 464, y: 0)] {
            XCTAssertNotNil(stale(bar, projected + [changed])[42])
            XCTAssertNotNil(decline(bar, projected + [changed]))
        }
    }

    func testUntrackedExactReplicaPairStillCannotSwapRowsOrReorder() {
        let ghosts = [window(90, x: 50), window(190, x: -364, y: -1440)]
        let bar = certify(projected + ghosts)
        assertCertified(bar, projected + ghosts)
        XCTAssertEqual(stale(bar, projected + exchangeRows(ghosts))[42], "untracked row changed")
        XCTAssertNotNil(stale(bar, projected + [window(90, x: 60), ghosts[1]])[42])
    }

    func testOutsideRowPanelKeepsStrictRowAndVisibilityButCanChangeGeometry() {
        let panel = window(99, x: 100, y: -7, height: 500, onScreen: true)
        let bar = certify(projected + [panel])
        assertCertified(bar, projected + [panel])
        XCTAssertNil(decline(bar, projected + [window(99, x: -9000, y: -7, width: 500, height: 600, onScreen: true)]))
        XCTAssertEqual(stale(bar, projected + [window(99, x: 100, y: 0, height: 500, onScreen: true)])[42], "untracked row changed")
        XCTAssertEqual(stale(bar, projected + [window(99, x: 100, y: -7, height: 500)])[42], "untracked visibility changed")
        // An exempt outside-row panel cannot become a menu-shaped window
        // without the same control-anchor evidence required at creation.
        XCTAssertEqual(decline(bar, projected + [window(99, x: 100, y: -7, height: 24, onScreen: true)]),
                       "menu row has no control anchor")
    }

    func testDormantSamePIDGhostIsNotPromotedByWidthAlone() {
        // A dormant same-process same-width window lies elsewhere than the
        // logical role's anchor-relative X, and must remain untracked.
        let ghost = window(90, x: 50)
        let bar = certify(projected + [ghost])
        assertCertified(bar, projected + [ghost])
        XCTAssertEqual(stale(bar, exchangeRows(projected) + [window(90, x: 50, onScreen: true)])[42], "untracked visibility changed")
        let missingKnown = projected.filter { $0.key.number != 101 } + [window(90, x: -364, y: -1440)]
        XCTAssertEqual(stale(certify(missingKnown), missingKnown), [42: "icon not grouped across rows"])
    }

    func testAmbiguousSamePIDReplicaOverlapRejectsCreationAndReuse() {
        let overlap = window(90, x: -314, y: -1440)
        let ambiguous = projected + [overlap]
        XCTAssertEqual(stale(certify(ambiguous), ambiguous), [42: "icon not grouped across rows"])
        let ghost = window(90, x: 50, y: -1440)
        let bar = certify(projected + [ghost])
        assertCertified(bar, projected + [ghost])
        let changed = replacing(projected, WindowKey(pid: 42, number: 101), with: window(101, x: 50, y: -1440))
        // Move both managed roles; the overlay of CPU with the unchanged dormant
        // ghost makes the match unsafe.
        let keptOrder = replacing(changed, WindowKey(pid: 42, number: 102), with: window(102, x: 100, y: -1440))
        XCTAssertEqual(stale(bar, keptOrder + [ghost])[42], "ambiguous logical role geometry")
    }

    func testAmbiguousOwnControlAnchorsAndMissingOwnedRolesRejectCreation() {
        let duplicateAnchor = projected + [window(90, x: 700, width: 32, pid: 900)]
        XCTAssertEqual(rows(duplicateAnchor).fault, "ambiguous control anchors")
        XCTAssertFalse(certify(duplicateAnchor).reusable)
        // Own items are identified by their titled source windows, not by AX evidence.
        for missingID: UInt32 in [10, 11] {
            let untitled = projected.map { item -> StatusWindow in
                guard item.key == WindowKey(pid: 900, number: missingID) else { return item }
                return StatusWindow(key: item.key, frame: item.frame, onScreen: item.onScreen)
            }
            XCTAssertEqual(rows(untitled).fault, "Tuck's menu bar items not identified")
            XCTAssertFalse(certify(untitled).reusable)
        }
        let missingAnchor = projected.filter { $0.key.number != 111 }
        XCTAssertEqual(rows(missingAnchor).fault, "menu row has no control anchor")
        XCTAssertFalse(certify(missingAnchor).reusable)
    }

    func testDormantOffscreenWindowOnDetachedRowIsUntrackedButMayNotActivate() {
        // A stale replica left at a previous display arrangement's menu row.
        let dormant = window(99, x: -416, y: -1080, width: 38, height: 37)
        let bar = certify(projected + [dormant])
        assertCertified(bar, projected + [dormant])
        XCTAssertEqual(decline(bar, projected + [window(99, x: -416, y: -1080, width: 38, height: 37, onScreen: true)]),
                       "menu row has no control anchor")
        XCTAssertEqual(stale(bar, projected + [window(99, x: -416, y: -1079, width: 38, height: 37)])[42], "untracked row changed")
        let active = projected + [window(99, x: -416, y: -1080, width: 38, height: 37, onScreen: true)]
        XCTAssertFalse(certify(active).reusable)
    }

    func testFixedIndicatorIsDistinguishedFromNearWidthSameProcessDormantWindows() {
        let fixed = window(3, x: 320, width: 34, onScreen: true)
        let replica = window(103, x: 320 - 414, y: -1440, width: 34)
        let dormant = [window(90, x: 50, width: 33), window(190, x: -300, y: -1440, width: 33)]
        let all = projected + [fixed, replica] + dormant
        let evidence = icons(known) + [icon(fixed, movable: false)]
        let bar = certify(all, evidence: evidence)
        assertCertified(bar, all)
        // The dormant windows stay untracked: they may not move or activate.
        let moved = projected + [fixed, replica, window(90, x: 51, width: 33), dormant[1]]
        XCTAssertNotNil(stale(bar, moved)[42])
        // Two near-width windows in the same control-relative slot stay ambiguous.
        let clash = projected + [fixed, replica, window(90, x: 320, width: 33), dormant[1]]
        XCTAssertEqual(stale(certify(clash, evidence: evidence), clash), [42: "icon not grouped across rows"])
    }

    func testSingleRowCertificateStillProtectsOrderAndUnknownGeometry() {
        let ghost = window(99, x: 50)
        let bar = certify(known + [ghost])
        assertCertified(bar, known + [ghost])
        XCTAssertNotNil(stale(bar, known + [window(99, x: 51)])[42])
        // A uniform reorder leaves every app able to vouch for its identities; only
        // the order the last full pass verified tells it apart.
        let reordered = replacing(known, known[0].key, with: window(1, x: 200))
        XCTAssertEqual(stale(bar, reordered + [ghost]), [:])
        XCTAssertEqual(decline(bar, reordered + [ghost]), "known window order changed")
        XCTAssertNotNil(decline(bar, exchangeRows(projected)))
    }

    func testEmptyDuplicateTiedAndInvalidEvidenceIsRejected() throws {
        // No icons read for an app showing windows on the bar.
        XCTAssertEqual(stale(certify(projected, evidence: []), projected)[42], "untracked active menu-bar window")
        // The same icon read twice.
        let twice = certify(projected, evidence: icons([known[0], known[0]]))
        XCTAssertFalse(twice.complete)
        XCTAssertTrue(twice.issues.contains(WorkIssue(recovery: .awaitChange, message: "\(id(42, 1)): ambiguous identity")))
        // Tied geometry: two same-width icons in one slot.
        let tied = replacing(projected, known[0].key, with: window(1, x: 180))
        XCTAssertEqual(stale(certify(tied), tied), [42: "icon not grouped across rows"])
        // Icons bound on two different rows in one reading.
        let mixed = certify(projected, evidence: [icon(replicas(known)[0]), icon(known[1])])
        XCTAssertTrue(mixed.issues.contains(WorkIssue(recovery: .retry, message: "Waiting for a coherent active menu bar")))
        XCTAssertEqual(stale(mixed, projected)[42], "not yet read")
        // Malformed records: the strict list refuses them, the skipping read drops them
        // and says so, and the observe-only hide declines.
        let duplicate = projected + [known[0]]
        let nan = replacing(projected, known[0].key, with: window(1, x: .nan))
        for bad in [duplicate, nan] {
            XCTAssertThrowsError(try WindowList(bad))
            XCTAssertTrue(rows(bad).skippedMalformed)
            XCTAssertEqual(decline(certify(projected), bad), "invalid window snapshot")
        }
    }

    func testMatchingRejectsDuplicateNonfiniteAndEmptySnapshotRecords() {
        let bar = certify(projected)
        XCTAssertEqual(decline(bar, projected + [known[0]]), "invalid window snapshot")
        XCTAssertEqual(decline(bar, replacing(projected, known[0].key, with: window(1, x: .nan))), "invalid window snapshot")
        XCTAssertEqual(decline(bar, replacing(projected, known[0].key, with: window(1, x: 100, width: 0))), "invalid window snapshot")
        XCTAssertEqual(decline(bar, []), "Tuck's menu bar items not identified")
    }

    // MARK: - MenuRows

    func testRowsAreAnchoredByTheControlWithOneSeparatorEach() {
        let rows = rows(projected)
        XCTAssertNil(rows.fault)
        XCTAssertEqual(rows.rows, [-1440, 0])
        XCTAssertEqual(rows.control.map(\.key.number), [111, 11])
        XCTAssertEqual(rows.separator.map(\.key.number), [110, 10])
        XCTAssertEqual(rows.row(of: known[0]), 1)
        XCTAssertNil(rows.row(of: window(99, x: 0, y: -1080)))
    }

    func testDormantRowIsNeitherARowNorAFault() {
        let dormant = window(99, x: -416, y: -1080, pid: 77)
        let quiet = rows(projected + [dormant])
        XCTAssertNil(quiet.fault)
        XCTAssertEqual(quiet.rows, [-1440, 0])
        XCTAssertNil(quiet.row(of: dormant))
        // On screen, or holding one of Tuck's windows, it is a bar without an anchor.
        XCTAssertEqual(rows(projected + [window(99, x: -416, y: -1080, pid: 77, onScreen: true)]).fault,
                       "menu row has no control anchor")
        XCTAssertEqual(rows(projected + [dormant, window(90, x: 0, y: -1080, width: 10, pid: 900)]).fault,
                       "menu row has no control anchor")
        // Not menu-height: outside, never a fault.
        XCTAssertNil(rows(projected + [window(98, x: 0, y: -1080, height: 500, pid: 77, onScreen: true)]).fault)
    }

    func testMenuHeightRowWithoutControlAnchorIsAFault() {
        XCTAssertEqual(rows(projected.filter { $0.key.number != 111 }).fault, "menu row has no control anchor")
        XCTAssertEqual(rows(projected + [window(5, x: 0, y: -2000, onScreen: true)]).fault, "menu row has no control anchor")
        // The separator must sit on the same side of the control on every row.
        let crossed = replacing(projected, WindowKey(pid: 900, number: 110), with: window(110, x: -100, y: -1440, width: 4, pid: 900))
        XCTAssertEqual(rows(crossed).fault, "Tuck's items differ between menu rows")
    }

    func testBoundaryRevealedOnlyWhenEverySeparatorReplicaIsNarrow() {
        XCTAssertTrue(rows(projected).boundaryRevealed)
        let widened = { (numbers: [UInt32]) in self.projected.map { item -> StatusWindow in
            guard item.key.pid == 900, numbers.contains(item.key.number) else { return item }
            return StatusWindow(key: item.key, frame: CGRect(x: item.frame.minX - 9_996, y: item.frame.minY, width: 10_000, height: 24),
                                onScreen: item.onScreen, title: item.title)
        } }
        XCTAssertFalse(rows(widened([10, 110])).boundaryRevealed)
        XCTAssertFalse(rows(widened([110])).boundaryRevealed)
        XCTAssertFalse(rows([]).boundaryRevealed)
    }

    // MARK: - AppReading.bind

    private func element(_ frame: CGRect?, identifier: String? = nil, remembered: String? = nil) -> AXElementReading {
        AXElementReading(frame: frame, identifier: identifier, remembered: remembered, compatibility: nil, description: nil)
    }
    private func bind(_ elements: [AXElementReading], windows: [StatusWindow]? = nil, titles: [WindowKey: String] = [:],
                      hadIcons: Bool = false, final: Bool = false) -> AppReading? {
        AppReading.bind(app: app(42), elements: elements, windows: windows ?? projected.filter { $0.key.pid == 42 },
                        titles: titles, rows: rows(projected), hadIcons: hadIcons, finalAttempt: final)
    }
    private func icons(of reading: AppReading?) -> [AppReading.BoundIcon]? {
        if case .clean(let icons) = reading?.outcome { return icons }
        return nil
    }
    private func issues(of reading: AppReading?) -> [WorkIssue]? {
        switch reading?.outcome {
        case .unclear(_, let issues): return issues
        case .failed(let issue): return [issue]
        default: return nil
        }
    }

    func testBindMatchesExactAndInsetFramesToUniqueWindows() throws {
        let reading = bind([element(known[1].frame, identifier: "battery"),
                            element(known[0].frame.insetBy(dx: 3, dy: 3), identifier: "cpu")])
        let bound = try XCTUnwrap(icons(of: reading))
        XCTAssertEqual(bound.map(\.window.number), [2, 1])
        XCTAssertEqual(bound.map(\.element), [0, 1])
        XCTAssertEqual(bound.map(\.identity.key), ["app42::battery", "app42::cpu"])
        XCTAssertEqual(bound.map(\.label), ["App 42 — battery", "App 42 — cpu"])
        // One icon needs no identifier, and is labelled by its app.
        let single = try XCTUnwrap(icons(of: bind([element(known[0].frame)], windows: [known[0]])))
        XCTAssertEqual(single.map(\.identity.key), ["app42"])
        XCTAssertEqual(single.map(\.label), ["App 42"])
    }

    func testBindIdentityPrefersIdentifierThenDistinctTitlesThenMemory() throws {
        let titles = [known[0].key: "CPU", known[1].key: "Battery"]
        let bound = try XCTUnwrap(icons(of: bind([element(known[0].frame, remembered: "old"), element(known[1].frame, identifier: "id")],
                                                 titles: titles)))
        XCTAssertEqual(bound.map(\.identity.item), ["CPU", "id"])
        // One distinct title identifies nothing; memory does.
        let same = [known[0].key: "Item", known[1].key: "Item"]
        let remembered = try XCTUnwrap(icons(of: bind([element(known[0].frame, remembered: "a"), element(known[1].frame, remembered: "b")],
                                                      titles: same)))
        XCTAssertEqual(remembered.map(\.identity.item), ["a", "b"])
    }

    func testBindReturnsNilOnceThenReportsAmbiguityOnTheFinalAttempt() throws {
        let moved = known[0].frame.offsetBy(dx: 7, dy: 0)
        XCTAssertNil(bind([element(moved, identifier: "cpu")]))
        // The shell's one re-sample: fresh element frames and fresh windows.
        let resampled = [window(1, x: 107, onScreen: true)] + projected.filter { $0.key.pid == 42 && $0.key.number != 1 }
        XCTAssertEqual(try XCTUnwrap(icons(of: bind([element(moved, identifier: "cpu")], windows: resampled, final: true))).map(\.window.number), [1])
        // Still unmatched: unclear, never the nearest window.
        let reading = bind([element(moved, identifier: "cpu"), element(known[1].frame, identifier: "battery")], final: true)
        XCTAssertEqual(issues(of: reading), [WorkIssue(recovery: .retry, message: "App 42: ambiguous window match")])
        if case .unclear(let partial, _) = reading?.outcome { XCTAssertEqual(partial.map(\.window.number), [2]) }
        else { XCTFail("expected unclear") }
    }

    func testBindIsUnclearForUnidentifiedIconsOrMissingGeometry() {
        XCTAssertEqual(issues(of: bind([element(known[0].frame), element(known[1].frame, identifier: "battery")])),
                       [WorkIssue(recovery: .awaitChange, message: "App 42: multiple icons without stable identifiers")])
        XCTAssertEqual(issues(of: bind([element(nil), element(known[1].frame, identifier: "battery")])),
                       [WorkIssue(recovery: .retry, message: "App 42: accessibility geometry unavailable")])
    }

    func testBindFailsForGeometryOffEveryAnchoredRow() {
        let reading = bind([element(CGRect(x: 100, y: 500, width: 36, height: 24), identifier: "cpu")])
        guard case .failed(let issue) = reading?.outcome else { return XCTFail("expected failed") }
        XCTAssertEqual(issue, WorkIssue(recovery: .retry, message: "Accessibility geometry is outside current menu rows"))
    }

    func testBindEmptyExtrasFollowsTheEmptyExtrasRule() {
        let offscreen = [window(263, x: 50)]
        XCTAssertEqual(icons(of: bind([], windows: offscreen)), [])
        let unavailable = [WorkIssue(recovery: .retry, message: "App 42: accessibility inventory unavailable")]
        XCTAssertEqual(issues(of: bind([], windows: offscreen, hadIcons: true)), unavailable)
        XCTAssertEqual(issues(of: bind([], windows: [window(263, x: 50, onScreen: true)])), unavailable)
        XCTAssertEqual(icons(of: bind([], windows: [], hadIcons: true)), [])
    }

    // MARK: - Evidence

    func testRoleFramesMayChangeFreely() {
        let bar = certify(projected)
        let hidden = projected.map { item -> StatusWindow in
            guard item.key.pid == 42 else { return item }
            return window(item.key.number, x: item.frame.minX - 10_000, y: item.frame.minY, width: 38, pid: 42)
        }
        XCTAssertEqual(stale(bar, hidden), [:])
        XCTAssertEqual(bar.frame(of: bar.roles[0], row: 1), known[0].frame)
    }

    func testLooseWindowComingOnScreenIsNewEvidence() {
        let ghost = window(99, x: -9000, y: -7, height: 500, pid: 77)
        let bar = certify(projected + [ghost])
        let woke = window(99, x: -9000, y: -7, height: 500, pid: 77, onScreen: true)
        XCTAssertEqual(stale(bar, projected + [woke]), [77: "untracked visibility changed"])
    }

    func testChangedIncarnationIsStaleUntilReadAgain() {
        let bar = certify(projected)
        let restarted = apps.map { $0.pid == 42 ? app(42, incarnation: "2") : $0 }
        XCTAssertEqual(stale(bar, projected, running: restarted), [42: "process restarted"])
        let unread = MenuBar.observe(rows(projected), running: restarted, readings: [], previous: bar)
        XCTAssertEqual(unread.issues, [WorkIssue(recovery: .retry, message: "App 42: not read (process restarted)")])
        XCTAssertTrue(unread.roles.isEmpty)
        let reread = MenuBar.observe(rows(projected), running: restarted,
                                     readings: readings(icons(known), in: projected, running: restarted), previous: bar)
        XCTAssertTrue(reread.reusable)
    }

    func testFailedOrUnclearReadingKeepsTheBindingButIsNotReusable() {
        let bar = certify(projected)
        let failed = MenuBar.observe(rows(projected), running: apps,
                                     readings: [.failed(app(42), WorkIssue(recovery: .retry, message: "AX timeout"))], previous: bar)
        XCTAssertFalse(failed.complete)
        XCTAssertEqual(failed.issues, [WorkIssue(recovery: .retry, message: "App 42: AX timeout")])
        XCTAssertEqual(failed.roles.map(\.identity.key), bar.roles.map(\.identity.key))
        XCTAssertEqual(failed.staleApps(in: rows(projected), running: apps), [42: "previous read incomplete"])
        let issue = WorkIssue(recovery: .retry, message: "App 42: ambiguous window match")
        let unclear = MenuBar.observe(rows(projected), running: apps,
                                      readings: [AppReading(app: app(42), outcome: .unclear([], [issue]))], previous: bar)
        XCTAssertEqual(unclear.issues, [issue])
        XCTAssertEqual(unclear.roles.count, 2)
        XCTAssertEqual(unclear.staleApps(in: rows(projected), running: apps), [42: "previous read incomplete"])
        // Read cleanly again, the app vouches for itself.
        let clean = MenuBar.observe(rows(projected), running: apps,
                                    readings: readings(icons(known), in: projected, running: apps), previous: unclear)
        XCTAssertTrue(clean.reusable)
    }

    // MARK: - What a pass reads

    private var twoApps: (sources: [StatusWindow], all: [StatusWindow]) {
        let sources = known + [window(3, x: 140, pid: 43, onScreen: true)]
        return (sources, sources + replicas(sources))
    }

    func testANoChangeObservationNamesNoStaleApp() {
        let fixture = twoApps
        let bar = certify(fixture.all, evidence: icons(fixture.sources))
        assertCertified(bar, fixture.all)
        XCTAssertEqual(stale(bar, fixture.all), [:])
        // Hiding moves every hidden icon; frames are not evidence.
        let hidden = fixture.all.map { item -> StatusWindow in
            guard item.key.pid != ownPID else { return item }
            return window(item.key.number, x: item.frame.minX - 10_000, y: item.frame.minY, pid: item.key.pid)
        }
        XCTAssertEqual(stale(bar, hidden), [:])
        let next = MenuBar.observe(rows(hidden), running: apps, readings: [], previous: bar)
        XCTAssertTrue(next.complete)
        XCTAssertTrue(next.reusable)
        XCTAssertEqual(next.order, bar.order)
    }

    func testAfterOneAppsWindowsChangeOnlyThatAppIsStale() {
        let fixture = twoApps
        let bar = certify(fixture.all, evidence: icons(fixture.sources))
        let changed = fixture.all + [window(4, x: 60, pid: 43, onScreen: true)]
        XCTAssertEqual(stale(bar, changed), [43: "status-window membership changed"])
        // Reading that one app makes the bar whole again.
        let reading = AppReading(app: app(43), outcome: .clean([
            AppReading.BoundIcon(identity: IconIdentity(bundle: "app43", item: "3"), label: "App 43", movable: true,
                                 window: WindowKey(pid: 43, number: 3), element: 0),
            AppReading.BoundIcon(identity: IconIdentity(bundle: "app43", item: "4"), label: "App 43", movable: false,
                                 window: WindowKey(pid: 43, number: 4), element: 1)]))
        let next = MenuBar.observe(rows(changed), running: apps, readings: [reading], previous: bar)
        XCTAssertTrue(next.complete, "\(next.issues)")
        XCTAssertEqual(Set(next.roles.map(\.identity.key)), [id(42, 1), id(42, 2), id(43, 3), id(43, 4)])
        XCTAssertTrue(next.reusable)
        XCTAssertEqual(next.staleApps(in: rows(changed), running: apps), [:])
    }

    func testRowsThatDisagreeOnOrderBlockOnlyAnAppNotReadThisPass() {
        let bar = certify(projected)
        // CPU's replica jumps past Tuck's control on the other row.
        let disagreeing = replacing(projected, WindowKey(pid: 42, number: 101), with: window(101, x: -100, y: -1440))
        XCTAssertEqual(stale(bar, disagreeing), [42: "known window order changed"])
        let unread = MenuBar.observe(rows(disagreeing), running: apps, readings: [], previous: bar)
        XCTAssertFalse(unread.complete)
        XCTAssertTrue(unread.issues.contains(WorkIssue(recovery: .retry, message: "known window order changed")))
        // Read on the active row this pass, the app's order there is fresh: the pass
        // proceeds on it, and the bar is not reused.
        let read = MenuBar.observe(rows(disagreeing), running: apps,
                                   readings: readings(icons(known), in: disagreeing, running: apps), previous: bar)
        XCTAssertTrue(read.complete, "\(read.issues)")
        XCTAssertFalse(read.reusable)
        XCTAssertEqual(read.order, [id(42, 1), id(42, 2), OwnItem.separator.id, OwnItem.control.id])
        XCTAssertNotNil(read.staleApps(in: rows(disagreeing), running: apps)[42])
    }

    func testABarWithNoIconsOfOtherAppsIsNotComplete() {
        let empty = MenuBar.observe(rows(projected), running: apps,
                                    readings: [AppReading(app: app(42), outcome: .clean([]))], previous: .none)
        XCTAssertFalse(empty.complete)
        XCTAssertEqual(empty.issues, [WorkIssue(recovery: .retry, message: "Waiting for a coherent active menu bar")])
    }

    func testAppThatQuitIsDropped() {
        let bar = certify(projected)
        let without = projected.filter { $0.key.pid != 42 }
        let running = apps.filter { $0.pid != 42 }
        XCTAssertEqual(stale(bar, without, running: running), [:])
        XCTAssertTrue(MenuBar.observe(rows(without), running: running, readings: [], previous: bar).roles.isEmpty)
    }
}
