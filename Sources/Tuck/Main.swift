import AppKit
import ApplicationServices
import TuckCore

@main
struct TuckMain {
    static func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor static func main() {
        let defaultConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tuck/config.json")
        let configURL = argument("--config").map { URL(fileURLWithPath: $0) } ?? defaultConfig
        if CommandLine.arguments.contains("--help") {
            print("""
            Tuck — click to reveal/hide menu bar icons
            Usage: Tuck [--config PATH] [--no-prompt]
                   Tuck --inventory
                   Tuck --validate PATH
            Default config: ~/.config/tuck/config.json
            Right-click the control to open the config or quit.
            """)
            return
        }
        if let path = argument("--validate") {
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: ConfigStore.maximumBytes + 1) ?? Data()
                guard data.count <= ConfigStore.maximumBytes else { throw ConfigStoreError.tooLarge }
                let config = try JSONDecoder().decode(TuckConfig.self, from: data)
                try config.validate()
                print("Valid: \(config.visible.count) visible, \(config.hidden.count) hidden")
            } catch { fputs("\(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--inventory") {
            let app = NSApplication.shared
            Task { @MainActor in
                do {
                    let snapshot = try await Inventory().scan()
                    let data: [String: Any] = ["accessibility": AXIsProcessTrusted(), "complete": snapshot.complete,
                        "ambiguous": snapshot.ambiguous, "issues": snapshot.issues.map { ["recovery": $0.recovery.rawValue, "message": $0.message] },
                        "icons": snapshot.icons.map { icon in
                            ["id": icon.id, "bundleID": icon.metadata.bundleID, "label": icon.metadata.label,
                             "item": icon.metadata.item as Any? ?? NSNull(), "movable": icon.movable,
                             "windowID": icon.windowID, "x": icon.frame.minX, "width": icon.frame.width] as [String: Any]
                        }]
                    let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
                    FileHandle.standardOutput.write(json); print(""); exit(0)
                } catch { fputs("\(error)\n", stderr); exit(1) }
            }
            app.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(configURL: configURL)
        app.delegate = delegate
        app.run()
    }
}
