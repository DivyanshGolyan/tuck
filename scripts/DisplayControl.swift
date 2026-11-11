// Test-only pointer helper. Never changes Tuck config or presses a button.
import AppKit
import CoreGraphics
let args = CommandLine.arguments
if args.count == 4, args[1] == "--move", let x = Double(args[2]), let y = Double(args[3]) {
    let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    event.setIntegerValueField(.eventSourceUserData, value: 0x5455434B)
    event.post(tap: .cghidEventTap)
} else {
    let screens = NSScreen.screens.compactMap { screen -> [String: Double]? in
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let r = CGDisplayBounds(id.uint32Value)
        return ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
    }
    let point = CGEvent(source: nil)!.location
    let data = try! JSONSerialization.data(withJSONObject: ["screens": screens, "pointer": ["x": point.x, "y": point.y]])
    print(String(decoding: data, as: UTF8.self))
}
