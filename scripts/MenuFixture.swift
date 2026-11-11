// Native NSMenu fixture. Only watches its explicitly supplied test command file.
// Atomic commands: open [auto-close-seconds], open-empty [seconds], close,
// stale-open (AX notification without displaying a menu), stale-close, quit.
import AppKit

@MainActor
private final class MenuFixture: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu(title: "Probe menu")
    private let emptyMenu = NSMenu(title: "Empty probe menu")
    private var activeMenu: NSMenu?
    private var timer: Timer?
    private let commandPath: String
    private let output: FileHandle
    private let start = ProcessInfo.processInfo.systemUptime

    init(commandPath: String, output: FileHandle) {
        self.commandPath = commandPath
        self.output = output
    }
    private func log(_ kind: String) {
        let event: [String: Any] = ["kind": kind, "pid": getpid(), "elapsed": ProcessInfo.processInfo.systemUptime - start]
        if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
            output.write(data); output.write(Data([10]))
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        emptyMenu.delegate = self
        let item = NSMenuItem(title: "Diagnostic action", action: #selector(action), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        let sub = NSMenuItem(title: "Diagnostic submenu", action: nil, keyEquivalent: "")
        let subMenu = NSMenu(title: "Diagnostic submenu")
        let child = NSMenuItem(title: "Diagnostic child", action: #selector(action), keyEquivalent: "")
        child.target = self
        subMenu.addItem(child)
        sub.submenu = subMenu
        menu.addItem(sub)
        status = NSStatusBar.system.statusItem(withLength: 30)
        status.button?.title = "MP"
        status.button?.setAccessibilityIdentifier("TuckNativeMenuProbeFixture")
        status.menu = menu
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.consumeCommand() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        log("ready")
    }
    @objc private func action() { log("action") }
    func menuWillOpen(_ menu: NSMenu) { activeMenu = menu; log(menu === emptyMenu ? "empty-will-open" : "will-open") }
    func menuDidClose(_ menu: NSMenu) { log(menu === emptyMenu ? "empty-did-close" : "did-close"); activeMenu = nil }

    private func consumeCommand() {
        guard let data = FileManager.default.contents(atPath: commandPath),
              let text = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: commandPath)
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let command = words.first else { return }
        switch command {
        case "open", "open-empty":
            guard activeMenu == nil else { log("already-open"); return }
            let selected = command == "open-empty" ? emptyMenu : menu
            status.menu = selected
            if words.count > 1, let seconds = Double(words[1]), seconds > 0 {
                // Timer must fire in menu tracking mode, not only the default mode.
                let close = Timer(timeInterval: min(60, seconds), repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.activeMenu?.cancelTracking() }
                }
                RunLoop.main.add(close, forMode: .common)
                RunLoop.main.add(close, forMode: .eventTracking)
            }
            log("command-\(command)")
            status.button?.performClick(nil)
            log("open-returned")
        case "close":
            log("command-close")
            activeMenu?.cancelTracking()
            menu.cancelTracking()
            emptyMenu.cancelTracking()
        case "stale-open":
            guard activeMenu == nil else { log("refused-stale-open-while-open"); return }
            // Real NSMenu object, synthetic notification only; never displays a menu.
            NSAccessibility.post(element: menu, notification: NSAccessibility.Notification(rawValue: "AXMenuOpened"))
            log("posted-stale-open")
        case "stale-close":
            NSAccessibility.post(element: menu, notification: NSAccessibility.Notification(rawValue: "AXMenuClosed"))
            log("posted-stale-close")
        case "quit":
            log("command-quit")
            activeMenu?.cancelTracking()
            NSApp.terminate(nil)
        default: log("unknown-command")
        }
    }
}

@main
struct MenuFixtureMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let command = option("--command"), let log = option("--log") else {
            fputs("Usage: MenuFixture --command PATH --log PATH\n", stderr)
            return
        }
        FileManager.default.createFile(atPath: log, contents: nil)
        guard let output = FileHandle(forWritingAtPath: log) else { return }
        let app = NSApplication.shared
        let delegate = MenuFixture(commandPath: command, output: output)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
