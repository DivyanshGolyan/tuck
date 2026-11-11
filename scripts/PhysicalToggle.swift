import AppKit
import CoreGraphics
let args = CommandLine.arguments
guard args.count == 3, let pid = Int32(args[1]), let row = Double(args[2]) else { exit(2) }
guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
      CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty else { exit(3) }
let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)) }
func frame(_ info: [String: Any]) -> CGRect? {
    guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
}
guard let named = owned.first(where: { $0[kCGWindowName as String] as? String == "TuckControl" }), let original = frame(named) else { exit(4) }
let hits = owned.compactMap(frame).filter { abs($0.minY-row) < 2 && abs($0.width-original.width) < 2 }
guard hits.count == 1 else { exit(5) }
var point = CGPoint(x: hits[0].midX, y: hits[0].midY)
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { exit(6) }
    event.flags = []; event.setIntegerValueField(.eventSourceUserData, value: 0x54494D45)
    event.post(tap: .cghidEventTap)
    if type != .leftMouseUp { Thread.sleep(forTimeInterval: type == .mouseMoved ? 0.08 : 0.025) }
    if type == .mouseMoved {
        let fresh = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let current = fresh.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow))
        }.compactMap(frame).filter { abs($0.minY-row) < 2 && abs($0.width-original.width) < 2 }
        guard current.count == 1 else { exit(7) }
        point = CGPoint(x: current[0].midX, y: current[0].midY)
    }
}
