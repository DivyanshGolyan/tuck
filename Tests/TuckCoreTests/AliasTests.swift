import XCTest
import TuckCore

final class AliasTests: XCTestCase {
    private func icon(_ bundle: String, _ item: String? = nil) -> IconIdentity { IconIdentity(bundle: bundle, item: item) }

    func testUniqueBundleAndItemMatchTakesTheConfigID() {
        let items = ["wifi": ItemMetadata(bundleID: "com.apple.controlcenter", label: "Wi-Fi", item: "WiFi"),
                     "dropbox": ItemMetadata(bundleID: "com.dropbox", label: "Dropbox")]
        let aliases = Aliases([icon("com.apple.controlcenter", "WiFi"), icon("com.dropbox")], items: items)
        XCTAssertEqual(aliases.ids, ["wifi", "dropbox"])
        XCTAssertEqual(aliases.collisions, [])
        XCTAssertNil(aliases.issue)
    }

    func testUnmatchedIconsTakeTheirKeyOrTheNextFreeSuffix() {
        // A different item under the icon's own key, and an earlier suffix, are both in use.
        let items = ["app::cpu": ItemMetadata(bundleID: "app", label: "Old", item: "memory"),
                     "app::cpu#2": ItemMetadata(bundleID: "other", label: "Other")]
        let aliases = Aliases([icon("app", "cpu"), icon("app", "fan"), icon("app", "memory")], items: items)
        XCTAssertEqual(aliases.ids, ["app::cpu#3", "app::fan", "app::cpu"])
        // Suffixes count within one resolution too.
        XCTAssertEqual(Aliases([icon("app"), icon("app", "x")], items: ["app": ItemMetadata(bundleID: "b", label: "B")]).ids,
                       ["app#2", "app::x"])
    }

    func testIconsThatEndOnOneIDAreDroppedAndReported() {
        let items = ["cpu": ItemMetadata(bundleID: "app", label: "CPU", item: "cpu")]
        let aliases = Aliases([icon("app", "cpu"), icon("other"), icon("app", "cpu")], items: items)
        XCTAssertEqual(aliases.ids, [nil, "other", nil])
        XCTAssertEqual(aliases.collisions, ["cpu"])
        XCTAssertEqual(aliases.issue, WorkIssue(recovery: .retry, message: "Ambiguous config alias: cpu"))
    }
}
