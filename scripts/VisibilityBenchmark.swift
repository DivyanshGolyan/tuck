import AppKit
import ApplicationServices
import Foundation

struct BenchmarkFailure: Error { let message: String }
func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
    var value: CFTypeRef?
    let code = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard code == .success else { throw BenchmarkFailure(message: "AX read \(name) returned \(code.rawValue)") }
    return value
}
func separatorWidth(pid: Int32) -> Double? {
    guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]] else { return nil }
    let matches = windows.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
        ($0[kCGWindowName as String] as? String) == "TuckSeparator" &&
        ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow))
    }
    guard matches.count == 1, let bounds = matches[0][kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
    return rect.width
}
func persisted(_ url: URL) -> Bool? {
    guard let bytes = try? Data(contentsOf: url),
          let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
    return value["showHidden"] as? Bool
}
final class GeometryObservation: @unchecked Sendable {
    let start = DispatchSemaphore(value: 0)
    let done = DispatchGroup()
    var started: UInt64 = 0
    var elapsedMS: Double?
    var width: Double?
}

func run() throws -> [String: Any] {
    let args = CommandLine.arguments
    guard args.count == 4, let pid = Int32(args[1]), ["true", "false"].contains(args[3]) else {
        throw BenchmarkFailure(message: "Usage: visibility-benchmark PID CONFIG true|false")
    }
    let expected = args[3] == "true", url = URL(fileURLWithPath: args[2])
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementSetMessagingTimeout(app, 2) == .success,
          let raw = try attribute(app, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
        throw BenchmarkFailure(message: "No extras bar")
    }
    let bar = raw as! AXUIElement
    guard AXUIElementSetMessagingTimeout(bar, 2) == .success else { throw BenchmarkFailure(message: "Bar timeout setup failed") }
    let children = try attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var matches: [AXUIElement] = []
    for child in children {
        guard AXUIElementSetMessagingTimeout(child, 2) == .success else { throw BenchmarkFailure(message: "Child timeout setup failed") }
        if try attribute(child, "AXIdentifier") as? String == "TuckControl" { matches.append(child) }
    }
    guard matches.count == 1, let widthBefore = separatorWidth(pid: pid),
          persisted(url) == !expected, (widthBefore > 100) == expected else {
        throw BenchmarkFailure(message: "Initial state is not opposite the requested toggle")
    }
    let control = matches[0]
    let observation = GeometryObservation()
    observation.done.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        observation.start.wait()
        let deadline = observation.started + 10_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let width = separatorWidth(pid: pid),
               (expected ? width < 100 : width > 100), persisted(url) == expected {
                observation.elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - observation.started) / 1_000_000
                observation.width = width
                break
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        observation.done.leave()
    }
    // The observer must run concurrently: AXPerformAction acknowledgement can
    // arrive long after the callback has changed actual WindowServer geometry.
    observation.started = DispatchTime.now().uptimeNanoseconds
    observation.start.signal()
    let action = AXUIElementPerformAction(control, kAXPressAction as CFString)
    let actionReturned = DispatchTime.now().uptimeNanoseconds
    guard observation.done.wait(timeout: .now() + 11) == .success,
          let elapsed = observation.elapsedMS, let width = observation.width else {
        throw BenchmarkFailure(message: "Timed out after one AXPress; action code \(action.rawValue). No retry was sent")
    }
    let label = try attribute(control, kAXDescriptionAttribute) as? String ?? ""
    let expectedLabel = expected ? "Hide hidden icons" : "Show hidden icons"
    return ["success": action == .success && label == expectedLabel, "actionCode": action.rawValue,
            "elapsedMS": elapsed, "actionMS": Double(actionReturned-observation.started)/1_000_000,
            "timingEndpoint": "Persisted config and actual separator CG geometry, observed concurrently with AXPress",
            "labelVerifiedAfterAction": true, "widthBefore": widthBefore, "widthAfter": width,
            "showHidden": expected, "persisted": true, "label": label]

}
do {
    let value = try run()
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(value["success"] as? Bool == true ? 0 : 1)
} catch {
    let message = (error as? BenchmarkFailure)?.message ?? String(describing: error)
    let data = try! JSONSerialization.data(withJSONObject: ["success": false, "error": message], options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(1)
}
