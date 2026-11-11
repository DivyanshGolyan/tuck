import XCTest
@testable import TuckCore

final class StatusItemIdentityTests: XCTestCase {
    private let bundle = "com.bjango.istatmenus.status"

    func testObservedTitlesAndChangingValuesUseCanonicalStableIDs() {
        let examples: [(String, [String])] = [
            ("memory", ["Memory Pressure 44%", "Memory Pressure 0%", "Memory Pressure 100%", "Memory Pressure 25.5%"]),
            ("battery", ["Battery: 100%, Charged.", "Battery: 99%, Charged.", "Battery: 100.0%, Charged."]),
            ("cpu", ["CPU 59%", "CPU 0%", "CPU 99.9%", "CPU 100%"]),
            ("network", ["Upload 366 KB/s, Download 101 KB/s", "Upload 0 B/s, Download 1.5 MB/s", "Upload 1 GB/s, Download 999.25 KB/s"]),
            ("sensors", ["Fans 13%", "Fans 0%", "Fans 100%", "Fans 8.5%"])
        ]
        for (suffix, titles) in examples {
            for title in titles {
                XCTAssertEqual(StatusItemIdentity.compatibilityItem(bundleID: bundle, accessibilityTitle: title), "com.bjango.istatmenus." + suffix, title)
            }
        }
    }

    func testOtherAppsUnknownAndLocalizedTitlesNeverMatch() {
        for other in ["com.other.app", "com.bjango.istatmenus", "com.bjango.istatmenus.status.helper", "", bundle.uppercased()] {
            XCTAssertNil(StatusItemIdentity.compatibilityItem(bundleID: other, accessibilityTitle: "CPU 59%"))
        }
        for title in [nil, "", "CPU", "CPU Usage 59%", "Speicherdruck 44%", "Memory Pressure ４４%", "Temperature 45°C", "Fans 1200 RPM", "Battery: 80%, Charging."] as [String?] {
            XCTAssertNil(StatusItemIdentity.compatibilityItem(bundleID: bundle, accessibilityTitle: title))
        }
    }

    func testMalformedTitlesAndUnitsAreRejected() {
        let titles = [
            "CPU -1%", "CPU +1%", "CPU 101%", "CPU 100.1%", "CPU 059%", "CPU NaN%", "CPU inf%", "CPU 1e2%", "CPU .5%", "CPU 5.%",
            " CPU 59%", "CPU 59% ", "CPU 59%\n", "prefix CPU 59%", "CPU 59% suffix", "cpu 59%", "CPU  59%", "CPU 59 %",
            "Memory Pressure -44%", "Memory Pressure 44", "Memory Pressure 44%\nCPU 59%", "Fans 101%",
            "Battery: 100%, Charged", "Battery: 100%, Charged.!", "Battery 100%, Charged.",
            "Upload -1 KB/s, Download 101 KB/s", "Upload 01 KB/s, Download 101 KB/s", "Upload 1e3 KB/s, Download 101 KB/s",
            "Upload 366 Kb/s, Download 101 KB/s", "Upload 366 kb/s, Download 101 KB/s", "Upload 366 KB, Download 101 KB/s",
            "Upload 366 KB/s Download 101 KB/s", "Upload 366 KB/s, Download 101 bananas/s", "Upload 366 KB/s, Download 101 KB/s\n"
        ]
        for title in titles {
            XCTAssertNil(StatusItemIdentity.compatibilityItem(bundleID: bundle, accessibilityTitle: title), title)
        }
        XCTAssertNil(StatusItemIdentity.compatibilityItem(bundleID: bundle, accessibilityTitle: "CPU " + String(repeating: "1", count: 600) + "%"))
    }
}
