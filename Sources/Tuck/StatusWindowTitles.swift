import Foundation
import ApplicationServices
import Darwin

// NSStatusItem does not expose another application's autosave identifier through
// public AppKit. CGWindow metadata can omit its title without Screen Recording.
// This isolated, optional compatibility bridge reads ONLY status-window titles;
// it captures no pixels. If macOS removes these symbols, discovery fails open.
// ABI corroborated by yabai src/window.c / src/misc/extern.h (no code copied).
final class StatusWindowTitles {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyProperty = @convention(c) (Int32, UInt32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let copyProperty: CopyProperty?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        self.handle = handle
        if let handle, let symbol = dlsym(handle, "SLSMainConnectionID") {
            connection = unsafeBitCast(symbol, to: Connection.self)
        } else { connection = nil }
        if let handle, let symbol = dlsym(handle, "SLSCopyWindowProperty") {
            copyProperty = unsafeBitCast(symbol, to: CopyProperty.self)
        } else { copyProperty = nil }
    }

    func title(windowID: CGWindowID) -> String? {
        guard AXIsProcessTrusted(), let connection, let copyProperty else { return nil }
        var result: Unmanaged<CFTypeRef>?
        let status = copyProperty(connection(), windowID, "kCGSWindowTitle" as CFString, &result)
        guard let result else { return nil }
        let value = result.takeRetainedValue()
        guard status == 0, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let title = value as! String
        return title.isEmpty ? nil : title
    }

    deinit { if let handle { dlclose(handle) } }
}
