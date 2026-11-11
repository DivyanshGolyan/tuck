import Foundation

/// Narrow compatibility for iStat's English AX titles when AXIdentifier is absent.
/// Unknown/localized titles remain unidentified; numeric readings never become IDs.
public enum StatusItemIdentity {
    private static let bundle = "com.bjango.istatmenus.status"
    private static let prefix = "com.bjango.istatmenus."
    // Percentages are finite, nonnegative decimal values from zero through 100.
    // Disallow signs, exponents, leading zeros, and fractional values above 100.
    private static let percentage = #"(?:100(?:\.0+)?|(?:[0-9]|[1-9][0-9])(?:\.[0-9]+)?)"#
    private static let rate = #"(?:0|[1-9][0-9]*)(?:\.[0-9]+)? (?:B|KB|MB|GB)/s"#
    private static let patterns: [(NSRegularExpression, String)] = {
        let entries = [
            ("Memory Pressure " + percentage + "%", "memory"),
            ("Battery: " + percentage + "%, Charged\\.", "battery"),
            ("CPU " + percentage + "%", "cpu"),
            ("Upload " + rate + ", Download " + rate, "network"),
            ("Fans " + percentage + "%", "sensors")
        ]
        // These are fixed, developer-owned expressions, not user input.
        return entries.map { (try! NSRegularExpression(pattern: "\\A" + $0.0 + "\\z"), $0.1) }
    }()

    public static func compatibilityItem(bundleID: String, accessibilityTitle: String?) -> String? {
        guard bundleID == bundle, let title = accessibilityTitle, !title.isEmpty,
              title.utf8.count <= 512 else { return nil }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for (pattern, suffix) in patterns {
            if pattern.firstMatch(in: title, range: range)?.range == range {
                return prefix + suffix
            }
        }
        return nil
    }
}
