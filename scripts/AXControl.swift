import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
if CommandLine.arguments.contains("--quit") {
    guard let running = NSRunningApplication(processIdentifier: pid) else { exit(0) }
    let accepted = running.terminate()
    print(accepted)
    exit(accepted ? 0 : 4)
}
let app = AXUIElementCreateApplication(pid)
// Bound slow/transient AX replies; a failed press must not be blindly retried.
guard AXUIElementSetMessagingTimeout(app, 2.0) == .success else {
    fputs("Cannot set AX messaging timeout\n", stderr); exit(6)
}
guard let bar = attribute(app, "AXExtrasMenuBar") else { fputs("No extras bar\n", stderr); exit(3) }
let extrasBar = bar as! AXUIElement
guard AXUIElementSetMessagingTimeout(extrasBar, 2.0) == .success else { exit(6) }
let children = attribute(extrasBar, kAXChildrenAttribute) as? [AXUIElement] ?? []
for item in children {
    guard AXUIElementSetMessagingTimeout(item, 2.0) == .success else { exit(6) }
    if attribute(item, "AXIdentifier") as? String == "TuckControl" {
        if CommandLine.arguments.contains("--label") {
            print(attribute(item, kAXDescriptionAttribute) as? String ?? "")
            exit(0)
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        print(result.rawValue)
        exit(result == .success ? 0 : 4)
    }
}
fputs("No control\n", stderr); exit(5)
